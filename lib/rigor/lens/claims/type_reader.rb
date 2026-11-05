# frozen_string_literal: true

require "rbs"
require_relative "../../rbs_extended"
require_relative "../../scope/resolution_chain"

module Rigor
  module Lens
    class Claims
      # Normalizes RBS ASTs without erasing unsupported forms or using display text as identity.
      class TypeReader
        Atom = Data.define(:kind, :value, :arguments, :relative) do
          def identity
            [kind, value, arguments.map { |arms| arms.to_set(&:identity) }]
          end

          def display
            return value.inspect if kind == :literal

            suffix = arguments.empty? ? "" : "[#{arguments.map { |arms| arms.map(&:display).join(' | ') }.join(', ')}]"
            "::#{value}#{suffix}"
          end
        end

        attr_reader :reasons

        def self.parse(text)
          [::RBS::Parser.parse_type(text, require_eof: true), nil]
        rescue ::RBS::ParsingError
          extended = RbsExtended.parse_return_type_override("rigor:v1:return: #{text}")
          [nil, extended ? "unsupported_grammar_feature" : "syntax_error"]
        end

        def initialize(scope:, nesting:, singleton_nesting: false)
          @scope = scope
          @loader = scope.environment.rbs_loader
          @resolver = @loader.type_name_resolver
          @nesting = nesting
          @singleton_nesting = singleton_nesting
          @context = Array(nesting).reduce(nil) do |outer, name|
            type_name = ::RBS::TypeName.parse("::#{name}")
            @loader.class_known?(name) ? [outer, type_name] : outer
          end
          @reasons = Set.new
        end

        def read(type, claim: false, aliases: Set.new)
          case type
          when ::RBS::Types::Bases::Any
            @reasons << "dynamic_type"
            []
          when ::RBS::Types::Bases::Bool then [literal(true), literal(false)]
          when ::RBS::Types::Bases::Nil then [literal(nil)]
          when ::RBS::Types::Literal then [literal(type.literal)]
          when ::RBS::Types::Union then type.types.flat_map { |part| read(part, claim: claim, aliases: aliases) }
          when ::RBS::Types::Optional then read(type.type, claim: claim, aliases: aliases) + [literal(nil)]
          when ::RBS::Types::Alias then read_alias(type, claim, aliases)
          when ::RBS::Types::ClassInstance then read_class(type, claim, aliases)
          else
            @reasons << "unsupported_type"
            type.each_type { |part| read(part, claim: claim, aliases: aliases) }
            []
          end
        end

        private

        def literal(value, relative: false)
          Atom.new(kind: :literal, value: value, arguments: [], relative: relative)
        end

        def resolve(name, claim)
          resolved = @resolver&.resolve(name, context: claim ? @context : nil)
          if resolved.nil?
            @reasons << "unresolved_name"
          elsif claim && !name.absolute? && name.class?
            compare_ruby_name(name, resolved)
          end
          resolved
        end

        def compare_ruby_name(name, resolved)
          # An unlocated alias body has no known cref. A singleton class's anonymous cref is not a
          # named namespace either; its constant table and ancestry cannot be read as the owner's.
          if @nesting.nil? || @singleton_nesting
            @reasons << "ambiguous_name"
            return
          end

          ruby = ruby_name(name.to_s)
          @reasons << "ambiguous_name" if ruby && ruby != resolved.to_s.delete_prefix("::")
        end

        def read_class(type, claim, aliases)
          name = resolve(type.name, claim)
          arguments = type.args.map { |arg| read(arg, claim: claim, aliases: aliases) }
          return [] unless name

          key = name.to_s.delete_prefix("::")
          if !@loader.class_known?(key) || arguments.size != @loader.class_type_param_names(key).size
            @reasons << "unsupported_type"
          end
          singles = { "TrueClass" => true, "FalseClass" => false, "NilClass" => nil }
          if arguments.empty? && singles.key?(key)
            return [literal(singles.fetch(key), relative: claim && !type.name.absolute?)]
          end

          [Atom.new(kind: :class, value: key, arguments: arguments, relative: claim && !type.name.absolute?)]
        end

        def read_alias(type, claim, aliases)
          name = resolve(type.name, claim)
          type.args.each { |arg| read(arg, claim: claim, aliases: aliases) }
          return [] unless name

          entry = @loader.type_alias_declaration(name)
          if entry.nil? || !entry.type_params.empty? || !type.args.empty? || aliases.include?(name)
            @reasons << "unsupported_type"
            return []
          end
          # The resolved declaration binds names in the alias's namespace, not the claim's lexical scope.
          read(entry.type, aliases: aliases | [name])
        end

        # Project constants only: a missing entry falls back to RBS, which also knows libraries and gems.
        # Resolve the first segment before the rest, so a Ruby-only namespace cannot fall through to core.
        def ruby_name(written)
          head, *tail = written.split("::")
          found = project_constant_in(@nesting.reverse, head)
          found ||= ancestor_constant(head)
          found = head if found.nil? && (@nesting.empty? || @loader.rbs_module?(@nesting.last)) && project_name?(head)
          found && ([found] + tail).join("::")
        end

        def project_constant_in(bases, name)
          bases.each do |base|
            candidate = base == "Object" ? name : "#{base}::#{name}"
            return candidate if project_name?(candidate)
          end
          nil
        end

        def project_name?(name)
          @scope.declared_class?(name) || @scope.bound_constant_names(name).include?(name)
        end

        def ancestor_constant(name)
          chain = Scope::ResolutionChain.for(@scope, @nesting.last || "Object", :instance, :constants)
          found = chain_constant(chain, name)
          settled = chain.settle(@scope, found) { |retro| chain_constant(retro, name) }
          if chain.truncated? || chain.wildcard_mixin? || settled != :chain
            @reasons << "ambiguous_name"
            return nil
          end
          found
        end

        def chain_constant(chain, name)
          chain.search(@scope) do |entry|
            bases = entry.external? ? external_ancestors(entry) : [entry.name]
            project_constant_in(bases, name)
          end
        end

        def external_ancestors(entry)
          name = entry.candidates.find { |candidate| @loader.class_known?(candidate) }
          name ? @loader.ancestor_names_for(name) : []
        end
      end
    end
  end
end
