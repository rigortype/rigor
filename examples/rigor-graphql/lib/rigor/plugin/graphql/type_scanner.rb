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
        SCHEMA_ENUM_TAIL = "Enum"
        SCHEMA_INPUT_OBJECT_TAIL = "InputObject"
        SCHEMA_MUTATION_TAIL = "Mutation"
        # Common path-segment for `Schema::Object` / `Schema::Enum`
        # / `Schema::InputObject` / `Schema::Mutation`; the
        # second-to-last segment must be `Schema` (either
        # fully-qualified `GraphQL::Schema::X` or lexically nested
        # `Schema::X` inside `module GraphQL`).
        SCHEMA_PARENT_SEGMENTS = %w[Schema GraphQL].freeze
        private_constant :SCHEMA_OBJECT_TAIL, :SCHEMA_ENUM_TAIL,
                         :SCHEMA_INPUT_OBJECT_TAIL, :SCHEMA_MUTATION_TAIL,
                         :SCHEMA_PARENT_SEGMENTS

        module_function

        # @param paths [Array<String>] absolute paths to `.rb` files
        #   the project's `paths:` resolves to.
        # @return [Hash{Symbol => Hash}] frozen 3-key result with
        #   `:types` (per-`Schema::Object` field table),
        #   `:enums` (per-`Schema::Enum` value list), and
        #   `:input_objects` (per-`Schema::InputObject` argument
        #   table). Any subset may be empty when no recognisable
        #   declaration of that kind is found.
        def scan(paths:)
          acc = empty_accumulator
          paths.each do |path|
            merge_accumulator(acc, scan_file(path))
          end
          freeze_accumulator(acc)
        end

        def empty_accumulator
          { types: {}, enums: {}, input_objects: {}, mutations: {} }
        end
        private_class_method :empty_accumulator

        def merge_accumulator(target, source)
          source.each do |kind, table|
            table.each { |k, v| target[kind][k] ||= v }
          end
          target
        end
        private_class_method :merge_accumulator

        def freeze_accumulator(acc)
          { types: acc[:types].freeze,
            enums: acc[:enums].freeze,
            input_objects: acc[:input_objects].freeze,
            mutations: acc[:mutations].freeze }.freeze
        end
        private_class_method :freeze_accumulator

        def scan_file(path)
          source = File.read(path)
          parse_result = Prism.parse(source, filepath: path)
          return empty_accumulator unless parse_result.errors.empty?

          collect_definitions(parse_result.value, [])
        rescue StandardError
          empty_accumulator
        end
        private_class_method :scan_file

        # Walks the AST collecting `class X < GraphQL::Schema::Object`,
        # `class X < GraphQL::Schema::Enum`, and
        # `class X < GraphQL::Schema::InputObject` decls at any
        # nesting level. Returns a 3-key hash so the caller can
        # publish multiple cross-plugin facts from one walk.
        def collect_definitions(node, qualified_prefix)
          return empty_accumulator if node.nil?

          case node
          when Prism::ClassNode then collect_class_node(node, qualified_prefix)
          when Prism::ModuleNode then collect_module_node(node, qualified_prefix)
          else
            node.compact_child_nodes.each_with_object(empty_accumulator) do |child, acc|
              merge_accumulator(acc, collect_definitions(child, qualified_prefix))
            end
          end
        end
        private_class_method :collect_definitions

        def collect_class_node(node, qualified_prefix)
          inner_name = constant_name_for(node.constant_path)
          return empty_accumulator if inner_name.nil?

          new_prefix = qualified_prefix + [inner_name]
          inner = collect_definitions(node.body, new_prefix)
          register_subclass!(node, new_prefix, inner)
          inner
        end
        private_class_method :collect_class_node

        def register_subclass!(class_node, prefix, acc)
          fqn = prefix.join("::")
          if schema_subclass?(class_node, SCHEMA_OBJECT_TAIL)
            fields = collect_fields(class_node.body)
            acc[:types][fqn] ||= fields unless fields.empty?
          elsif schema_subclass?(class_node, SCHEMA_ENUM_TAIL)
            values = collect_values(class_node.body)
            acc[:enums][fqn] ||= values unless values.empty?
          elsif schema_subclass?(class_node, SCHEMA_INPUT_OBJECT_TAIL)
            arguments = collect_arguments(class_node.body)
            acc[:input_objects][fqn] ||= arguments unless arguments.empty?
          elsif schema_subclass?(class_node, SCHEMA_MUTATION_TAIL)
            arguments = collect_arguments(class_node.body)
            fields = collect_fields(class_node.body)
            shape = { arguments: arguments, fields: fields }
            acc[:mutations][fqn] ||= shape unless arguments.empty? && fields.empty?
          end
        end
        private_class_method :register_subclass!

        def collect_module_node(node, qualified_prefix)
          inner_name = constant_name_for(node.constant_path)
          return empty_accumulator if inner_name.nil?

          collect_definitions(node.body, qualified_prefix + [inner_name])
        end
        private_class_method :collect_module_node

        # `class X < GraphQL::Schema::<Tail>` matches when the
        # superclass's last two path segments are `Schema::<Tail>`.
        # Matches both `< GraphQL::Schema::<Tail>` (fully qualified)
        # and `< Schema::<Tail>` (lexically inside `module GraphQL`).
        def schema_subclass?(class_node, tail)
          superclass = class_node.superclass
          return false if superclass.nil?

          path = constant_path_segments(superclass)
          return false if path.empty?
          return false unless path.last == tail

          SCHEMA_PARENT_SEGMENTS.include?(path[-2])
        end
        private_class_method :schema_subclass?

        def collect_fields(body)
          return {} if body.nil?

          fields = {}
          statement_nodes(body).each do |node|
            next unless node.is_a?(Prism::CallNode) && node.name == :field

            field = parse_field_call(node)
            next if field.nil?

            fields[field[:name]] = {
              type: field[:type], nullable: field[:nullable], list: field[:list]
            }
          end
          fields
        end
        private_class_method :collect_fields

        def statement_nodes(body)
          body.is_a?(Prism::StatementsNode) ? body.body : [body]
        end
        private_class_method :statement_nodes

        # Walks every top-level `value "..."` call inside an
        # enum subclass body and returns the value names as an
        # Array<String>. Both shapes graphql-ruby accepts work:
        #
        #     value "ACTIVE"
        #     value "DISABLED", value: :off, description: "..."
        #
        # The first positional must be a String literal — the
        # graphql-ruby `value` API also accepts a Symbol form
        # (`value :ACTIVE`) but the documented idiom is String.
        # Slice 2b only stores the GraphQL-side value name; the
        # optional `value:` kwarg (Ruby-side override) and
        # `description:` stay out of the published table for
        # the floor.
        def collect_values(body)
          return [] if body.nil?

          values = []
          statement_nodes(body).each do |node|
            next unless node.is_a?(Prism::CallNode) && node.name == :value

            arg = node.arguments&.arguments&.first
            values << arg.unescaped if arg.is_a?(Prism::StringNode)
          end
          values
        end
        private_class_method :collect_values

        # Walks every top-level `argument :name, Type, required: ...`
        # call inside an InputObject (or Mutation) subclass body and
        # returns the per-argument shape table. Argument syntax
        # mirrors `field` except the nullability axis is named
        # `required:` (default `false` — per graphql-ruby's
        # `argument` default; the OPPOSITE polarity of `field`'s
        # `null:`).
        #
        #     argument :name, String, required: true
        #     argument :tags, [String], required: false
        #     argument :status, Types::Status, required: true
        def collect_arguments(body)
          return {} if body.nil?

          arguments = {}
          statement_nodes(body).each do |node|
            next unless node.is_a?(Prism::CallNode) && node.name == :argument

            argument = parse_argument_call(node)
            next if argument.nil?

            arguments[argument[:name]] = {
              type: argument[:type], required: argument[:required], list: argument[:list]
            }
          end
          arguments
        end
        private_class_method :collect_arguments

        def parse_argument_call(node)
          args = node.arguments&.arguments
          return nil if args.nil? || args.size < 2

          name_node = args[0]
          type_node = args[1]
          return nil unless name_node.is_a?(Prism::SymbolNode)

          type_info = resolve_field_type(type_node)
          return nil if type_info.nil?

          {
            name: name_node.unescaped,
            type: type_info[:type],
            list: type_info[:list],
            required: extract_required_flag(args)
          }
        end
        private_class_method :parse_argument_call

        # Mirror of `extract_nullability` but reads the `required:`
        # kwarg, defaulting to `false` (graphql-ruby's argument
        # default — the OPPOSITE polarity of `field`'s `null:` /
        # nullability default).
        # rubocop:disable Naming/PredicateMethod  -- extractor returns the literal required value
        def extract_required_flag(args)
          kwargs = args.last
          return false unless kwargs.is_a?(Prism::KeywordHashNode)

          pair = kwargs.elements.find do |el|
            el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode) && el.key.unescaped == "required"
          end
          return false if pair.nil?

          case pair.value
          when Prism::TrueNode then true
          when Prism::FalseNode then false
          else false
          end
        end
        # rubocop:enable Naming/PredicateMethod
        private_class_method :extract_required_flag

        # `field :name, Type, null: false` shape. The first
        # positional is a Symbol (field name); the second is a
        # constant reference (GraphQL type) OR a single-element
        # ArrayNode (`[Type]`) for GraphQL list types; `null:` is
        # the nullability keyword (defaults to TRUE per
        # graphql-ruby's field defaults so we mirror that).
        def parse_field_call(node)
          args = node.arguments&.arguments
          return nil if args.nil? || args.size < 2

          name_node = args[0]
          type_node = args[1]
          return nil unless name_node.is_a?(Prism::SymbolNode)

          type_info = resolve_field_type(type_node)
          return nil if type_info.nil?

          {
            name: name_node.unescaped,
            type: type_info[:type],
            list: type_info[:list],
            nullable: extract_nullability(args)
          }
        end
        private_class_method :parse_field_call

        # Resolves the `Type` positional argument to a
        # `{type: "ClassName", list: bool}` tuple. ArrayNode
        # forms (`[String]` / `[Types::User]`) unwrap the single
        # element and mark `list: true`. Bare constant refs are
        # not lists. Returns nil for unrecognised shapes (string
        # types `"User"`, Proc lazy types, etc.) so callers drop
        # the field.
        def resolve_field_type(node)
          if node.is_a?(Prism::ArrayNode)
            element = node.elements.first
            return nil if node.elements.size != 1 || element.nil?

            inner = resolve_constant_type(element)
            return nil if inner.nil?

            { type: inner, list: true }
          else
            name = resolve_constant_type(node)
            return nil if name.nil?

            { type: name, list: false }
          end
        end
        private_class_method :resolve_field_type

        def resolve_constant_type(node)
          name = constant_name_for(node)
          return nil if name.nil?

          tail = name.split("::").last
          CANONICAL_TYPES[tail] || name
        end
        private_class_method :resolve_constant_type

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
