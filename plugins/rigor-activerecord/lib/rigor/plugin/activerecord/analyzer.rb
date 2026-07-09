# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class Activerecord < Rigor::Plugin::Base
      # Per-file AST walker. For each `Model.find(...)` / `Model.find_by(...)` / `Model.where(...)` call
      # where `Model` is a name in the {ModelIndex}, emits diagnostics:
      #
      # | Method | Recognised arg shape | Validation |
      # | --- | --- | --- |
      # | `Model.find(id)` | any positional | arity check (1+ args) |
      # | `Model.find_by(col: v, ...)` | keyword args | each key must be a column |
      # | `Model.where(col: v, ...)` | keyword args | each key must be a column |
      # | `Model.where(string)` | String literal | parser-side; not validated |
      #
      # Successful matches surface as `:info` diagnostics naming the resolved table; unknown columns
      # surface as `:error`. Calls whose receiver is not a model in the index, and calls with
      # non-keyword arguments to `where` / `find_by`, stay silent.
      class Analyzer
        # Methods that take a column → value Hash and need each key validated against the receiver's
        # column set. The bang variants (`find_by!` raises instead of returning nil; `find_or_create_by!`
        # raises on a validation failure) and `create_or_find_by` / `create_or_find_by!` take the
        # identical column-hash argument shape.
        COLUMN_HASH_METHODS = %i[
          where
          find_by find_by!
          find_or_create_by find_or_create_by!
          find_or_initialize_by
          create_or_find_by create_or_find_by!
        ].freeze

        attr_reader :diagnostics

        def initialize(path:, model_index:)
          @path = path
          @model_index = model_index
          @diagnostics = []
        end

        def analyze(root)
          walk(root) { |node| visit_call(node) if node.is_a?(Prism::CallNode) }
          self
        end

        private

        def walk(node, &)
          return if node.nil?

          yield node
          node.compact_child_nodes.each { |child| walk(child, &) }
        end

        def visit_call(node)
          model_name = constant_receiver_name(node.receiver)
          return if model_name.nil?

          entry = @model_index.find(model_name) ||
                  @model_index.find("::#{model_name}")
          return if entry.nil?

          case node.name
          when :find then validate_find(node, entry)
          when *COLUMN_HASH_METHODS then validate_column_hash_call(node, entry)
          end
        end

        def validate_find(node, entry)
          arity = call_argument_count(node)
          if arity.zero?
            push_error(node, "wrong-arity",
                       "`#{entry.class_name}.find` expects at least 1 argument, got 0")
            return
          end

          push_info(node, "model-call",
                    "`#{entry.class_name}.find` returns #{entry.class_name} (table: `#{entry.table_name}`)")
        end

        def validate_column_hash_call(node, entry)
          keyword_pairs = keyword_argument_pairs(node)
          return push_recognised(node, entry) if keyword_pairs.empty?

          # Models with no schema-side columns are virtual — backed by a database VIEW (Mastodon's
          # `Instance` model wraps a SQL view that isn't in `db/schema.rb`), seeded from an external
          # source, or otherwise opaque to our schema parser. Without a column set we cannot meaningfully
          # check query keys; surface the call as recognised and skip column validation entirely rather
          # than firing a false `unknown-column` against every key.
          return push_recognised(node, entry, keyword_pairs.map { |p| p[:key] }) if entry.column_names.empty?

          unknown = keyword_pairs.reject { |pair| nested_condition?(pair[:value]) || valid_query_key?(entry, pair[:key]) }
          if unknown.empty?
            keyword_pairs.each { |pair| validate_enum_value(node, entry, pair) }
            push_recognised(node, entry, keyword_pairs.map { |p| p[:key] })
          else
            unknown.each do |pair|
              key = pair[:key]
              suggestion = Rigor::Plugin::Base.suggest(key, entry.column_names)
              hint = suggestion ? " (did you mean `:#{suggestion}`?)" : ""
              push_error(node, "unknown-column",
                         "`#{entry.class_name}.#{node.name}(#{key}: ...)` references " \
                         "unknown column `#{key}` on table `#{entry.table_name}`#{hint}")
            end
          end
        end

        # ActiveRecord's `where` / `find_by` / `find_or_initialize_by` accept either a column name *or* a
        # singular association name (belongs_to / has_one). The latter resolves to the association's FK
        # column behind the scenes:
        #
        #   AccountPin.find_by(account: x)
        #   # → SELECT … WHERE account_id = x.id
        #
        # Without this allowance, every `find_by(<assoc>:)` call surfaces as an `unknown-column` false
        # positive — Mastodon saw ~100 such hits across the API controllers, all of which were the
        # canonical Rails idiom rather than typos.
        #
        # `alias_attribute` names resolve to their target before the column / association check —
        # querying by an aliased attribute is a valid Rails idiom and must not surface as an
        # `unknown-column`.
        def valid_query_key?(entry, key)
          key = entry.resolve_alias(key) if entry.alias?(key)

          return true if entry.column?(key)

          assoc = entry.association(key)
          assoc && assoc[:kind] == :singular
        end

        # A keyword pair with a Hash value is a nested / joined-table condition (`Approval.where(approvals:
        # { user_id: 1 })`, `where(users: { name: 'x' })`), where the key names an association or a joined
        # table, not a column on the receiver. Rails resolves it through the join, so it must not be checked
        # against the receiver's own columns. (An Array value — `where(status: [:a, :b])` — is an IN query on
        # a real column, not nested, so only a Hash is skipped.)
        def nested_condition?(value_node)
          value_node.is_a?(Prism::HashNode) || value_node.is_a?(Prism::KeywordHashNode)
        end

        # When the column is an enum-bearing column AND the passed value is a Symbol literal, the value
        # MUST be one of the declared enum values. Non-Symbol values (variables, expressions) decline so
        # dynamic call sites stay silent. Sequences (`status: [:active, :archived]`) are intentionally NOT
        # walked here — the relation-shape check belongs in a future track.
        def validate_enum_value(node, entry, pair)
          return unless entry.enum?(pair[:key])
          return unless pair[:value].is_a?(Prism::SymbolNode)

          value = pair[:value].unescaped
          values = entry.enum_values(pair[:key])
          return if values.include?(value)

          suggestion = Rigor::Plugin::Base.suggest(value, values)
          hint = suggestion ? " (did you mean `:#{suggestion}`?)" : ""
          push_error(node, "unknown-enum-value",
                     "`#{entry.class_name}.#{node.name}(#{pair[:key]}: :#{value})` references " \
                     "unknown enum value `:#{value}` (declared: #{values.map { |v| ":#{v}" }.join(', ')})#{hint}")
        end

        def push_recognised(node, entry, keys = nil)
          msg = "`#{entry.class_name}.#{node.name}`"
          msg += " (#{keys.map { |k| ":#{k}" }.join(', ')})" if keys && !keys.empty?
          msg += " on table `#{entry.table_name}`"
          push_info(node, "model-call", msg)
        end

        def constant_receiver_name(node)
          case node
          when Prism::ConstantReadNode
            node.name.to_s
          when Prism::ConstantPathNode
            constant_path_name(node)
          end
        end

        def constant_path_name(node)
          parts = []
          current = node
          while current.is_a?(Prism::ConstantPathNode)
            parts.unshift(current.name.to_s)
            current = current.parent
          end
          case current
          when nil
            "::#{parts.join('::')}"
          when Prism::ConstantReadNode
            "#{current.name}::#{parts.join('::')}"
          end
        end

        def call_argument_count(node)
          return 0 if node.arguments.nil?

          node.arguments.arguments.size
        end

        # Returns the symbol-keyed pairs of any KeywordHashNode argument as `{ key:, value: }` rows. Plain
        # hash-literal arguments (`Model.where({a: 1})`) are NOT walked — Rails accepts both, but the
        # keyword form is the idiomatic one. The `value` Prism node is preserved so the enum check
        # downstream can recognise Symbol literals without re-walking the call.
        def keyword_argument_pairs(node)
          return [] if node.arguments.nil?

          pairs = []
          node.arguments.arguments.each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode)

            arg.elements.each do |pair|
              next unless pair.is_a?(Prism::AssocNode) && pair.key.is_a?(Prism::SymbolNode)

              pairs << { key: pair.key.unescaped, value: pair.value }
            end
          end
          pairs
        end

        def push_info(node, rule, message)
          push_diagnostic(node, severity: :info, rule: rule, message: message)
        end

        def push_error(node, rule, message)
          push_diagnostic(node, severity: :error, rule: rule, message: message)
        end

        def push_diagnostic(node, severity:, rule:, message:)
          @diagnostics << Rigor::Analysis::Diagnostic.from_node(
            node, path: @path, message: message, severity: severity, rule: rule
          )
        end
      end
    end
  end
end
