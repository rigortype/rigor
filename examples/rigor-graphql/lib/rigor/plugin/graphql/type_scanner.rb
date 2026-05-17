# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class Graphql < Rigor::Plugin::Base
      # Walks project source for `class T < GraphQL::Schema::Object`
      # subclasses and emits a `{type_class_fqn => {field_name => {type:, nullable:}}}`
      # table covering every `field :name, Type, null: ...` declaration
      # inside the class body.
      module TypeScanner
        # The canonical GraphQL scalar type names accepted as
        # `field`'s second positional argument. The plugin maps
        # each to the underlying Ruby class name so downstream
        # consumers can cross-reference against Ruby types
        # without re-implementing the GraphQL→Ruby coercion
        # table.
        CANONICAL_TYPES = {
          "String" => "String",
          "Integer" => "Integer",
          "Int" => "Integer",
          "Boolean" => "TrueClass",
          "Float" => "Float",
          "ID" => "String"
        }.freeze

        # The base class name a Schema::Object subclass MUST
        # inherit from to be recognised. Match is on the
        # rightmost segment of the superclass constant chain so
        # both `GraphQL::Schema::Object` and the locally-aliased
        # `BaseObject = GraphQL::Schema::Object` shape work when
        # the alias's RHS is the canonical path.
        SCHEMA_OBJECT_TAIL = "Object"
        SCHEMA_OBJECT_PARENTS = %w[Schema GraphQL].freeze
        private_constant :SCHEMA_OBJECT_TAIL, :SCHEMA_OBJECT_PARENTS

        module_function

        # @param paths [Array<String>] absolute paths to `.rb` files
        #   the project's `paths:` resolves to.
        # @return [Hash{String => Hash{String => Hash{Symbol => Object}}}]
        #   frozen per-type field table. Empty when no recognisable
        #   `Schema::Object` subclass is found.
        def scan(paths:)
          table = {}
          paths.each do |path|
            scan_file(path).each do |type_class, fields|
              table[type_class] ||= fields
            end
          end
          table.freeze
        end

        def scan_file(path)
          source = File.read(path)
          parse_result = Prism.parse(source, filepath: path)
          return {} unless parse_result.errors.empty?

          collect_types(parse_result.value, [])
        rescue StandardError
          {}
        end
        private_class_method :scan_file

        # Walks the AST collecting `class X < GraphQL::Schema::Object`
        # decls at any nesting level. Tracks the enclosing module
        # chain so a `module Types; class User < ...; end; end` shape
        # registers as `"Types::User"`.
        def collect_types(node, qualified_prefix)
          return {} if node.nil?

          case node
          when Prism::ClassNode then collect_class_node(node, qualified_prefix)
          when Prism::ModuleNode then collect_module_node(node, qualified_prefix)
          else
            node.compact_child_nodes.each_with_object({}) do |child, acc|
              collect_types(child, qualified_prefix).each { |k, v| acc[k] ||= v }
            end
          end
        end
        private_class_method :collect_types

        def collect_class_node(node, qualified_prefix)
          inner_name = constant_name_for(node.constant_path)
          return {} if inner_name.nil?

          new_prefix = qualified_prefix + [inner_name]
          inner = collect_types(node.body, new_prefix)
          if schema_object_subclass?(node)
            type_class = new_prefix.join("::")
            fields = collect_fields(node.body)
            inner[type_class] ||= fields unless fields.empty?
          end
          inner
        end
        private_class_method :collect_class_node

        def collect_module_node(node, qualified_prefix)
          inner_name = constant_name_for(node.constant_path)
          return {} if inner_name.nil?

          collect_types(node.body, qualified_prefix + [inner_name])
        end
        private_class_method :collect_module_node

        # `class X < GraphQL::Schema::Object` matches when the
        # superclass's last two path segments are
        # `Schema::Object` (or a single-segment `Object` whose
        # parent is `Schema`, etc.). Matches both
        # `< GraphQL::Schema::Object` (fully qualified) and
        # `< Schema::Object` (lexically inside `module GraphQL`).
        def schema_object_subclass?(class_node)
          superclass = class_node.superclass
          return false if superclass.nil?

          path = constant_path_segments(superclass)
          return false if path.empty?
          return false unless path.last == SCHEMA_OBJECT_TAIL

          # Accept any chain whose tail two are
          # `<...>::Schema::Object` (caters to `GraphQL::Schema::Object`
          # explicit and `Schema::Object` lexical-nested).
          SCHEMA_OBJECT_PARENTS.include?(path[-2])
        end
        private_class_method :schema_object_subclass?

        def collect_fields(body)
          return {} if body.nil?

          fields = {}
          statement_nodes(body).each do |node|
            next unless node.is_a?(Prism::CallNode) && node.name == :field

            field = parse_field_call(node)
            next if field.nil?

            fields[field[:name]] = { type: field[:type], nullable: field[:nullable] }
          end
          fields
        end
        private_class_method :collect_fields

        def statement_nodes(body)
          body.is_a?(Prism::StatementsNode) ? body.body : [body]
        end
        private_class_method :statement_nodes

        # `field :name, Type, null: false` shape. The first
        # positional is a Symbol (field name); the second is a
        # constant reference (GraphQL type); `null:` is the
        # nullability keyword (defaults to TRUE per graphql-ruby's
        # field defaults so we mirror that).
        def parse_field_call(node)
          args = node.arguments&.arguments
          return nil if args.nil? || args.size < 2

          name_node = args[0]
          type_node = args[1]
          return nil unless name_node.is_a?(Prism::SymbolNode)

          underlying = resolve_field_type(type_node)
          return nil if underlying.nil?

          { name: name_node.unescaped, type: underlying, nullable: extract_nullability(args) }
        end
        private_class_method :parse_field_call

        def resolve_field_type(node)
          name = constant_name_for(node)
          return nil if name.nil?

          tail = name.split("::").last
          CANONICAL_TYPES[tail] || name
        end
        private_class_method :resolve_field_type

        # Defaults to `true` (matches graphql-ruby's `field`
        # default nullability). Looks for an explicit `null:`
        # keyword and reads its boolean literal.
        # rubocop:disable Naming/PredicateMethod  -- extractor returns the literal nullability value
        def extract_nullability(args)
          kwargs = args.last
          return true unless kwargs.is_a?(Prism::KeywordHashNode)

          null_pair = kwargs.elements.find do |el|
            el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode) && el.key.unescaped == "null"
          end
          return true if null_pair.nil?

          case null_pair.value
          when Prism::TrueNode then true
          when Prism::FalseNode then false
          else true
          end
        end
        # rubocop:enable Naming/PredicateMethod
        private_class_method :extract_nullability

        # Returns the constant chain as an Array of String
        # segments (`["GraphQL", "Schema", "Object"]`). Empty
        # array for unrecognised node kinds.
        def constant_path_segments(node)
          case node
          when Prism::ConstantReadNode then [node.name.to_s]
          when Prism::ConstantPathNode
            segments = []
            current = node
            while current.is_a?(Prism::ConstantPathNode)
              segments.unshift(current.name.to_s)
              current = current.parent
            end
            segments.unshift(current.name.to_s) if current.is_a?(Prism::ConstantReadNode)
            segments
          else
            []
          end
        end
        private_class_method :constant_path_segments

        # Joined `::`-form of {.constant_path_segments}. Returns
        # nil for unrecognised node kinds (so callers can short-
        # circuit).
        def constant_name_for(node)
          segments = constant_path_segments(node)
          segments.empty? ? nil : segments.join("::")
        end
        private_class_method :constant_name_for
      end
    end
  end
end
