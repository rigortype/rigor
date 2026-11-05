# frozen_string_literal: true

require "rbs"
require_relative "../../rbs_extended"

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

        def initialize(scope:, nesting:)
          @scope = scope
          @loader = scope.environment.rbs_loader
          @resolver = @loader.type_name_resolver
          @nesting = nesting
          @context = nesting.reduce(nil) do |outer, name|
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
          resolved = @resolver.resolve(name, context: claim ? @context : nil)
          if resolved.nil?
            @reasons << "unresolved_name"
          elsif claim && !name.absolute? && name.class?
            ruby = ruby_name(name.to_s)
            @reasons << "ambiguous_name" if ruby && ruby != resolved.to_s.delete_prefix("::")
          end
          resolved
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
          bases = @nesting.reverse + ruby_ancestors(@nesting.last || "Object", Set.new)
          bases << "Object" if @nesting.empty? || @loader.rbs_module?(@nesting.last)
          found = bases.uniq.filter_map do |base|
            candidate = base == "Object" ? head : "#{base}::#{head}"
            candidate if project_name?(candidate)
          end.first
          found && ([found] + tail).join("::")
        end

        def project_name?(name)
          @scope.discovered_classes.key?(name) || @scope.in_source_constants.key?(name) ||
            @scope.constant_sources.key?(name) || @scope.bound_constant_names(name).include?(name)
        end

        def ruby_ancestors(name, seen)
          return [] if seen.include?(name)

          seen |= [name]
          includes = @scope.discovered_includes.fetch(name, [])
          superclass = @scope.discovered_superclasses[name]
          inherited = if superclass
                        ruby_ancestors(superclass.delete_prefix("::"), seen)
                      else
                        @loader.ancestor_names_for(name)
                      end
          [name] + includes.flat_map { |mod| ruby_ancestors(mod.delete_prefix("::"), seen) } + inherited
        end
      end
    end
  end
end
