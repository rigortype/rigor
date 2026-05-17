# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class DrySchema < Rigor::Plugin::Base
      # Walks project source for `Foo = Dry::Schema.{Params,JSON,define}
      # { ... }` shapes and emits a
      # `{schema_const_fqn => {required: {key => underlying_class}, optional: {…}}}`
      # table covering each schema's typed-key surface.
      module SchemaScanner
        # The dry-schema canonical-type symbols accepted as
        # predicate arguments. Maps each to the underlying Ruby
        # class name (the same vocabulary `rigor-dry-types`
        # uses for `CANONICAL_ALIASES`, intersected with what
        # dry-schema's predicate engine accepts).
        CANONICAL_TYPES = {
          string: "String",
          integer: "Integer",
          float: "Float",
          decimal: "BigDecimal",
          symbol: "Symbol",
          bool: "TrueClass",
          date: "Date",
          date_time: "DateTime",
          time: "Time",
          hash: "Hash",
          array: "Array"
        }.tap { |h| h[:nil] = "NilClass" }.freeze

        # The dry-schema predicate verbs that accept a type
        # argument. Each verb has a slightly different runtime
        # semantic (`filled` = present + non-empty; `value` =
        # present; `maybe` = present-or-nil; `each` = collection
        # element type) but for Rigor's purposes they all
        # contribute the same underlying class for the key.
        TYPE_BEARING_PREDICATES = %i[filled value maybe each].to_set.freeze
        private_constant :TYPE_BEARING_PREDICATES

        # The three entry-point method names on `Dry::Schema`.
        SCHEMA_ENTRY_NAMES = %i[Params JSON define].to_set.freeze
        private_constant :SCHEMA_ENTRY_NAMES

        module_function

        # @param paths [Array<String>] absolute paths to `.rb`
        #   files the project's `paths:` resolves to.
        # @param type_aliases [Hash{String => String}] the
        #   ADR-9 `:dry_type_aliases` fact published by
        #   `rigor-dry-types` when loaded. Used to resolve
        #   `value(Types::Email)` references to their
        #   underlying class. Empty when the plugin isn't
        #   loaded.
        # @return [Hash{String => Hash{Symbol => Hash{Symbol => String}}}]
        #   frozen per-schema typed-key table. Empty when no
        #   recognisable schema declaration is found.
        def scan(paths:, type_aliases: {})
          table = {}
          paths.each do |path|
            scan_file(path, type_aliases).each do |schema_const, shape|
              table[schema_const] ||= shape
            end
          end
          table.freeze
        end

        def scan_file(path, type_aliases)
          source = File.read(path)
          parse_result = Prism.parse(source, filepath: path)
          return {} unless parse_result.errors.empty?

          collect_schemas(parse_result.value, [], type_aliases)
        rescue StandardError
          {}
        end
        private_class_method :scan_file

        # Walks the AST collecting `<Const> = Dry::Schema.X { ... }`
        # assignments at any nesting level. Tracks the enclosing
        # constant chain so a class-level `class Foo; SCHEMA =
        # Dry::Schema.Params { ... }; end` registers as
        # `"Foo::SCHEMA"`.
        def collect_schemas(node, qualified_prefix, type_aliases)
          return {} if node.nil?

          case node
          when Prism::ConstantWriteNode
            collect_schema_assignment(node, qualified_prefix, type_aliases)
          when Prism::ClassNode
            inner_name = constant_name_for(node.constant_path)
            return {} if inner_name.nil?

            collect_schemas(node.body, qualified_prefix + [inner_name], type_aliases)
          when Prism::ModuleNode
            inner_name = constant_name_for(node.constant_path)
            return {} if inner_name.nil?

            collect_schemas(node.body, qualified_prefix + [inner_name], type_aliases)
          else
            node.compact_child_nodes.each_with_object({}) do |child, acc|
              collect_schemas(child, qualified_prefix, type_aliases).each do |k, v|
                acc[k] ||= v
              end
            end
          end
        end
        private_class_method :collect_schemas

        def collect_schema_assignment(node, qualified_prefix, type_aliases)
          rhs = node.value
          return {} unless schema_entry_call?(rhs)
          return {} unless rhs.is_a?(Prism::CallNode) && rhs.block

          schema_const = (qualified_prefix + [node.name.to_s]).join("::")
          shape = collect_schema_shape(rhs.block, type_aliases)
          { schema_const => shape }
        end
        private_class_method :collect_schema_assignment

        # Matches `Dry::Schema.Params { ... }` /
        # `Dry::Schema.JSON { ... }` / `Dry::Schema.define { ... }`.
        def schema_entry_call?(node)
          return false unless node.is_a?(Prism::CallNode)
          return false unless SCHEMA_ENTRY_NAMES.include?(node.name)

          receiver = node.receiver
          receiver.is_a?(Prism::ConstantPathNode) &&
            receiver.name == :Schema &&
            receiver.parent.is_a?(Prism::ConstantReadNode) &&
            receiver.parent.name == :Dry
        end
        private_class_method :schema_entry_call?

        def collect_schema_shape(block_node, type_aliases)
          required = {}
          optional = {}
          walk_block_body(block_node) do |kind, key, underlying|
            (kind == :required ? required : optional)[key] = underlying if underlying
          end

          # Re-walk to apply type-alias resolution on the
          # second pass so we don't double-walk the AST in the
          # common branch.
          remap_aliases!(required, type_aliases)
          remap_aliases!(optional, type_aliases)

          { required: required.freeze, optional: optional.freeze }.freeze
        end
        private_class_method :collect_schema_shape

        # Walks every top-level `required(:key).<predicate>(...)` /
        # `optional(:key).<predicate>(...)` chain in the block
        # body. The block's body is either a `Prism::StatementsNode`
        # (multi-statement) or a single expression node.
        def walk_block_body(block_node, &)
          body = block_node.body
          return if body.nil?

          children = body.is_a?(Prism::StatementsNode) ? body.body : [body]
          children.each { |child| visit_chain(child, &) }
        end
        private_class_method :walk_block_body

        # `required(:key).filled(:string)` parses as a CallNode
        # whose receiver is the `required(:key)` call. Walk the
        # chain inward looking for the type-bearing predicate at
        # the head; the key sits on the chain's tail.
        def visit_chain(node, &block)
          return unless node.is_a?(Prism::CallNode)

          key, kind = extract_key_and_kind(node)
          return if key.nil?

          underlying = walk_predicate_chain(node)
          block.call(kind, key, underlying)
        end
        private_class_method :visit_chain

        # `required(:key).filled(:string).value(...)...` — the
        # OUTERMOST call's receiver chain ends in the
        # `required(:key)` / `optional(:key)` call. Recurse on
        # `node.receiver` until we hit the `required` /
        # `optional` call, recording the key + kind.
        def extract_key_and_kind(node)
          current = node
          while current.is_a?(Prism::CallNode)
            if %i[required optional].include?(current.name)
              key_node = current.arguments&.arguments&.first
              return [nil, nil] unless key_node.is_a?(Prism::SymbolNode)

              return [key_node.unescaped.to_sym, current.name]
            end
            current = current.receiver
          end
          [nil, nil]
        end
        private_class_method :extract_key_and_kind

        # Walks the call chain finding the first type-bearing
        # predicate (`filled` / `value` / `maybe` / `each`) and
        # extracts its argument type. Returns the underlying
        # class name (`"String"` etc.) or nil when no recognisable
        # type sits on the chain.
        def walk_predicate_chain(node)
          current = node
          while current.is_a?(Prism::CallNode)
            if TYPE_BEARING_PREDICATES.include?(current.name)
              underlying = extract_type_from_predicate(current)
              return underlying if underlying
            end
            current = current.receiver
          end
          nil
        end
        private_class_method :walk_predicate_chain

        # Reads the first positional argument of a `filled(:string)`
        # / `value(:integer)` / `maybe(Types::Email)` call. Returns
        # either the canonical-type-symbol's underlying class
        # ("String" / "Integer" / …), or the constant's qualified
        # name for downstream type-alias resolution. Returns nil
        # for anything else.
        def extract_type_from_predicate(call_node)
          arg = call_node.arguments&.arguments&.first
          case arg
          when Prism::SymbolNode
            CANONICAL_TYPES[arg.unescaped.to_sym]
          when Prism::ConstantReadNode
            arg.name.to_s
          when Prism::ConstantPathNode
            constant_name_for(arg)
          end
        end
        private_class_method :extract_type_from_predicate

        # In-place: any value in `bucket` that doesn't already
        # match a canonical class (e.g. `"Types::Email"`) gets
        # resolved through the type_aliases fact. Unresolvable
        # values drop from the bucket (no fact contribution
        # rather than misleading data).
        def remap_aliases!(bucket, type_aliases)
          canonical_set = CANONICAL_TYPES.values.to_set
          bucket.each_pair.to_a.each do |key, value|
            next if canonical_set.include?(value)

            resolved = type_aliases[value]
            if resolved
              bucket[key] = resolved
            else
              bucket.delete(key)
            end
          end
        end
        private_class_method :remap_aliases!

        # Constant-path serialiser: `Dry::Schema` -> "Dry::Schema",
        # bare `Foo` -> "Foo". Returns nil for shapes Prism
        # doesn't expose as ConstantRead/PathNode.
        def constant_name_for(node)
          return nil if node.nil?

          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode
            parts = []
            current = node
            while current.is_a?(Prism::ConstantPathNode)
              parts.unshift(current.name.to_s)
              current = current.parent
            end
            case current
            when nil then "::#{parts.join('::')}"
            when Prism::ConstantReadNode then "#{current.name}::#{parts.join('::')}"
            end
          end
        end
        private_class_method :constant_name_for
      end
    end
  end
end
