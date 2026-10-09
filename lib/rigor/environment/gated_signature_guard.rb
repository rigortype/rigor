# frozen_string_literal: true

require "rbs"

module Rigor
  class Environment
    # Issue #1700 — whether a {RequiredFeatures}-gated vendored directory can join an environment without clashing
    # with a declaration the environment already holds from elsewhere. The project's own `sig/`, a
    # `signature_paths:` entry, a bundled gem's `sig/`, an `rbs collection` copy, a plugin's signatures and the
    # RBS synthesized from inline annotations are all loaded beside the vendored files, and a method both sides
    # declare raises `RBS::DuplicatedMethodDefinitionError`. Rigor fails soft there, and the WHOLE class degrades
    # to `Dynamic[top]`: a project `sig/ext.rbs` declaring `Integer#prime?` cost every `Integer` call its type
    # once `require "prime"` loaded the vendored `Integer#prime?` beside it. The other source is the one the
    # project chose, so the vendored directory is the one that stands down.
    #
    # A clash is read off the declarations, not off names alone: a type both sides declare clashes when they
    # disagree on class versus module, both name a superclass and the names differ, or both declare the same
    # member (an instance or singleton method, alias or attribute). A project that merely reopens `Integer`
    # with other methods, or declares its own `Prime` with members the gem does not have, keeps the vendored
    # signatures.
    module GatedSignatureGuard
      module_function

      # @param dir — the vendored directory (Pathname).
      # @param sig_files — the other signature files the environment loads (Pathnames).
      # @param virtual_rbs — `[name, source]` pairs synthesized from inline annotations.
      # @return true when any of them clashes with what `dir` declares.
      def clashes?(dir, sig_files, virtual_rbs)
        vendored = Dir.glob(File.join(dir.to_s, "*.rbs")).each_with_object({}) do |file, surface|
          collect(File.read(file), surface)
        end
        return false if vendored.empty?

        needles = vendored.keys.map { |name| name.split("::").last }.uniq
        other_sources(sig_files, virtual_rbs).any? do |source|
          next false unless needles.any? { |needle| source.include?(needle) }

          clash?(vendored, collect(source, {}))
        end
      end

      def other_sources(sig_files, virtual_rbs)
        files = sig_files.lazy.filter_map do |file|
          File.read(file.to_s)
        rescue SystemCallError, IOError
          nil
        end
        files.chain(Array(virtual_rbs).lazy.map { |_name, source| source.to_s })
      end

      def clash?(vendored, other)
        other.any? do |name, entry|
          mine = vendored[name]
          next false if mine.nil?

          mine[:kind] != entry[:kind] ||
            (!mine[:supers].empty? && !entry[:supers].empty? && mine[:supers] != entry[:supers]) ||
            mine[:members].intersect?(entry[:members])
        end
      end

      # Adds `source`'s declarations to `surface` (type name => `{kind:, supers:, members:}`). A source that does
      # not parse contributes nothing: the loader quarantines such a file on its own.
      def collect(source, surface)
        _, _, decls = RBS::Parser.parse_signature(source)
        walk(decls, nil, surface)
        surface
      rescue RBS::BaseError, StandardError
        surface
      end

      def walk(decls, namespace, surface)
        decls.each do |decl|
          next unless decl.is_a?(RBS::AST::Declarations::Class) || decl.is_a?(RBS::AST::Declarations::Module)

          name = qualify(namespace, decl.name)
          entry = (surface[name] ||= { kind: decl_kind(decl), supers: Set.new, members: Set.new })
          entry[:supers] << decl.super_class.name.to_s.delete_prefix("::") if decl_super(decl)
          members(decl, name, surface, entry)
        end
      end

      def members(decl, name, surface, entry)
        decl.members.each do |member|
          case member
          when RBS::AST::Declarations::Class, RBS::AST::Declarations::Module then walk([member], name, surface)
          when RBS::AST::Members::MethodDefinition then method_keys(member).each { |key| entry[:members] << key }
          when RBS::AST::Members::Alias then entry[:members] << [side(member.kind), member.new_name]
          when RBS::AST::Members::Attribute then attribute_keys(member).each { |key| entry[:members] << key }
          end
        end
      end

      def decl_kind(decl)
        decl.is_a?(RBS::AST::Declarations::Class) ? :class : :module
      end

      def decl_super(decl)
        decl.is_a?(RBS::AST::Declarations::Class) && decl.super_class
      end

      def qualify(namespace, type_name)
        text = type_name.to_s
        return text.delete_prefix("::") if text.start_with?("::") || namespace.nil?

        "#{namespace}::#{text}"
      end

      # `module_function` (`self?.`) declares both sides.
      def method_keys(member)
        case member.kind
        when :singleton_instance then [[:instance, member.name], [:singleton, member.name]]
        else [[side(member.kind), member.name]]
        end
      end

      def attribute_keys(member)
        kind = side(member.kind)
        keys = []
        keys << [kind, member.name] unless member.is_a?(RBS::AST::Members::AttrWriter)
        keys << [kind, :"#{member.name}="] unless member.is_a?(RBS::AST::Members::AttrReader)
        keys
      end

      def side(kind)
        kind == :singleton ? :singleton : :instance
      end
    end
  end
end
