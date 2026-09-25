# frozen_string_literal: true

require "rbs"

require_relative "../configuration"
require_relative "../rbs_extended"

module Rigor
  module SigGen
    # The methods the inline reader declares for each analysed file (ADR-112 WD4): what `# @rbs` / `#:` in a
    # `.rb` file says, member by member, as `rigor sig-gen` needs it to copy that declaration into `sig/`.
    #
    # Read from the RBS the `rigor-rbs-inline` synthesizer contributed (`RbsLoader#virtual_rbs`), not from the
    # built environment. The environment is the wrong witness twice over: once `sig/` declares a member, ADR-32
    # WD13 strips the inline one before the build, so the declaration a stale `sig/` copy should be compared
    # against is no longer there to read; and a member's origin is only recoverable off its location, which the
    # ADR-54 environment cache does not keep. The synthesized text is the loader's input, identical on every
    # run.
    #
    # A member the synthesizer marks `rigor:v1:inferred-signature` is in the text only because rbs-inline
    # declares every `def` of a file it reads: the author annotated nothing on it, so it is present here
    # ({#lookup} finds it, which is what `sig_gen.inline_declared: skip` needs) but not {Member#declared?}.
    class InlineDeclarations
      # One inline-declared method.
      #
      # - `method_types` — the declared overloads (`RBS::MethodType`, names as written, unresolved).
      # - `annotations` — the annotation strings the author wrote on the member (`deprecated` for
      #   `%a{deprecated}`), without the synthesizer's own `rigor:v1:inferred-*` markers.
      # - `return_inferred` — the author declared the parameters and not the return: rbs-inline defaulted it,
      #   and the synthesizer marked it `rigor:v1:inferred-return`.
      # - `signature_inferred` — every type slot defaulted; the author said nothing about this member.
      Member = Data.define(:method_types, :annotations, :return_inferred, :signature_inferred) do
        def declared?
          !signature_inferred
        end

        # The member's annotations as RBS lines, each in a delimiter its content does not close.
        def annotation_lines
          annotations.filter_map { |string| InlineDeclarations.annotation_line(string) }
        end
      end

      # The synthesizer channel this index reads; another plugin's virtual RBS is not an inline declaration.
      SYNTHESIZER_ID = Configuration::AUTOWIRED_RBS_INLINE_ID
      private_constant :SYNTHESIZER_ID

      MARKERS = [RbsExtended::INFERRED_RETURN_DIRECTIVE, RbsExtended::INFERRED_SIGNATURE_DIRECTIVE].freeze
      private_constant :MARKERS

      # rbs lexes `%a` with each of these pairs, up to the first matching closer and with no escape
      # (`rbs/src/lexer.re`), so an annotation is spelled in the first pair its content does not close.
      ANNOTATION_DELIMITERS = Ractor.make_shareable([%w[{ }], %w[( )], %w[[ ]], %w[< >], %w[| |]])
      private_constant :ANNOTATION_DELIMITERS

      def self.annotation_line(string)
        pair = ANNOTATION_DELIMITERS.find { |_open, close| !string.include?(close) }
        pair && "%a#{pair[0]}#{string}#{pair[1]}"
      end

      # Fail-soft: an environment with no loader, or a loader this index cannot read, declares nothing inline,
      # which is the answer for a project without the plugin.
      def self.build(environment)
        loader = environment&.rbs_loader
        new(loader.respond_to?(:virtual_rbs) ? loader.virtual_rbs : [])
      rescue StandardError
        new([])
      end

      def initialize(virtual_rbs)
        @by_path = {}
        @generic_classes = Set.new
        virtual_rbs.each do |name, content|
          prefix, plugin_id, path = name.to_s.split(":", 3)
          next unless prefix == "virtual" && plugin_id == SYNTHESIZER_ID && path

          decls = parse(content.to_s)
          next if decls.nil?

          table = (@by_path[path] ||= {})
          each_member(decls, []) { |class_name, member| record(table, class_name, member) }
        end
        @by_path.freeze
        @generic_classes.freeze
      end

      # The classes and modules an inline declaration gives type parameters (`# @rbs generic T`). sig-gen does not
      # write a class's type parameters, and a `sig/` header without them makes rbs reject the class
      # (`GenericParameterMismatchError`), so the generator writes nothing that would open one of these.
      attr_reader :generic_classes

      # @return the inline declaration of `class_name`'s `method_name` on the `kind` side, declared in the file
      #   at `path` — or nil.
      def lookup(path, class_name, method_name, kind)
        @by_path.dig(path.to_s, [class_name, method_name, kind])
      end

      private

      def parse(content)
        return nil if content.empty? || !content.valid_encoding?

        _buffer, _directives, decls = ::RBS::Parser.parse_signature(content)
        decls
      rescue ::RBS::BaseError
        nil
      end

      def each_member(decls, prefix, &block)
        decls.each do |decl|
          next unless decl.is_a?(::RBS::AST::Declarations::Class) || decl.is_a?(::RBS::AST::Declarations::Module)

          inner = prefix + [decl.name.to_s.delete_prefix("::")]
          @generic_classes << inner.join("::") unless decl.type_params.empty?
          decl.members.each { |member| block.call(inner.join("::"), member) }
          each_member(decl.members, inner, &block)
        end
      end

      def record(table, class_name, member)
        method_entries(member).each do |method_name, kind, method_types|
          table[[class_name, method_name, kind]] ||= build_member(member, method_types)
        end
      end

      # `[method_name, kind, method_types]` per method a member defines, mirroring what the RBS definition
      # builder files it under: an attribute is its reader and / or writer, `def self?.x` is both sides. An
      # `overloading?` member (`def x: ... | ...`) composes with another declaration rather than being one,
      # and an alias declares no signature of its own, so neither is recorded.
      def method_entries(member)
        case member
        when ::RBS::AST::Members::MethodDefinition then definition_entries(member)
        when ::RBS::AST::Members::AttrReader then [reader_entry(member)]
        when ::RBS::AST::Members::AttrWriter then [writer_entry(member)]
        when ::RBS::AST::Members::AttrAccessor then [reader_entry(member), writer_entry(member)]
        else []
        end
      end

      def definition_entries(member)
        return [] if member.overloading?

        types = member.overloads.map(&:method_type)
        kinds = member.kind == :singleton_instance ? %i[instance singleton] : [member.kind]
        kinds.map { |kind| [member.name, kind, types] }
      end

      def reader_entry(member)
        [member.name, member.kind, [::RBS::Parser.parse_method_type("() -> #{member.type}")]]
      end

      def writer_entry(member)
        [:"#{member.name}=", member.kind, [::RBS::Parser.parse_method_type("(#{member.type}) -> #{member.type}")]]
      end

      def build_member(member, method_types)
        strings = member.annotations.map { |annotation| annotation.string.to_s.strip }
        Member.new(
          method_types: method_types.freeze,
          annotations: (strings - MARKERS).freeze,
          return_inferred: strings.include?(RbsExtended::INFERRED_RETURN_DIRECTIVE),
          signature_inferred: strings.include?(RbsExtended::INFERRED_SIGNATURE_DIRECTIVE)
        )
      end
    end
  end
end
