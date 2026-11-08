# frozen_string_literal: true

require "rigor/source/node_children"

require "prism"

module Rigor
  module Plugin
    class Activerecord < Rigor::Plugin::Base
      # Walks a parsed `db/schema.rb` and produces a {SchemaTable}.
      # Recognises the `create_table` DSL Rails generates:
      #
      #   ActiveRecord::Schema[8.0].define(version: ...) do
      #     create_table "users", force: :cascade do |t|
      #       t.string  "name", null: false
      #       t.integer "age"
      #       t.datetime "created_at"
      #     end
      #
      #     create_table "posts" do |t|
      #       t.text "body"
      #       t.references "user", foreign_key: true   # adds user_id integer
      #     end
      #   end
      #
      # `t.references "x"` becomes an `x_id` integer column (foreign-key indices and constraints are
      # ignored — only the column shape matters for type inference); add a `polymorphic: true` option and
      # an `x_type` string column is emitted too. `t.timestamps` adds `created_at` and `updated_at`
      # datetime columns. `t.column "x", :type` is the generic column form. Any other `t.<method> "name"`
      # call is treated as a column whose type symbol is the method name — unknown types degrade to
      # `Object` per `SchemaTable.ruby_type_for` rather than being dropped. Only the structural calls in
      # {NON_COLUMN_METHODS} (indexes, constraints, foreign keys) are skipped.
      #
      # `create_table "x", primary_key: "name"` adds that column, typed from the `id:` option when the call is
      # read completely and untyped otherwise. The `id` column stays registered; `id: false` or `id: nil` removes
      # it and adds neither.
      #
      # Designed for the Prism interpretation pattern from rigor-lisp-eval — recursive descent on the AST,
      # no eval.
      class SchemaParser
        TIMESTAMPS_COLUMNS = %w[created_at updated_at].freeze
        DEFAULT_PRIMARY_KEY_TYPE = :bigint
        UNKNOWN_PRIMARY_KEY_TYPE = :unknown

        # Structural `t.<method>` calls inside a `create_table` block that declare indexes / constraints
        # rather than columns. Everything NOT in this set that carries a literal column name is treated as
        # a column declaration so a real column is never silently dropped — a dropped column turns every
        # query against it into a false `unknown-column` diagnostic.
        NON_COLUMN_METHODS = %i[
          index check_constraint exclusion_constraint
          unique_constraint foreign_key primary_keys
        ].freeze

        # @param source — contents of `db/schema.rb`
        def self.parse(source)
          tree = Prism.parse(source).value
          new.parse(tree)
        end

        def parse(node)
          tables = {}
          collect_create_table_calls(node) do |call_node|
            table_name, columns = parse_create_table(call_node)
            tables[table_name] = columns if table_name
          end
          SchemaTable.new(tables.freeze)
        end

        private

        def collect_create_table_calls(node, &)
          return if node.nil?

          yield node if node.is_a?(Prism::CallNode) && node.name == :create_table && node.receiver.nil?

          node.rigor_each_child { |child| collect_create_table_calls(child, &) }
        end

        def parse_create_table(call_node)
          table_name = string_argument(call_node, 0)
          return [nil, nil] if table_name.nil?

          block_node = call_node.block
          columns = { "id" => implicit_id_column(call_node) }
          columns.delete("id") if id_disabled?(call_node)
          primary_key = named_primary_key_column(call_node)
          columns[primary_key.name] = primary_key if primary_key

          if block_node.is_a?(Prism::BlockNode) && block_node.body
            collect_column_calls(block_node.body) do |column_call|
              column = parse_column(column_call)
              if column.is_a?(Array)
                column.each { |c| columns[c.name] = c }
              elsif column
                columns[column.name] = column
              end
            end
          end

          [table_name, columns.freeze]
        end

        # A call this parser does not read completely may still say the key is not an integer.
        def implicit_id_column(call_node)
          read = keywords_read?(call_keywords(call_node))
          SchemaTable::Column.new(name: "id", type: read ? :integer : UNKNOWN_PRIMARY_KEY_TYPE, ruby_type: read ? "Integer" : "Object")
        end

        def id_disabled?(call_node)
          id = keyword_value(call_node, :id)
          (id.is_a?(Prism::FalseNode) || id.is_a?(Prism::NilNode)) && keywords_read?(call_keywords(call_node))
        end

        # `create_table "settings", primary_key: "name", id: { type: :string }` creates the column `name`
        # without the block declaring it, so the option is the only place the schema names it.
        def named_primary_key_column(call_node)
          return nil if id_disabled?(call_node)

          name = literal_name(keyword_value(call_node, :primary_key))
          return nil if name.nil?

          id = keyword_value(call_node, :id)
          options = id.is_a?(Prism::HashNode) ? id.elements : []
          type = primary_key_type_stated?(call_node, options) ? primary_key_type(id, options) : UNKNOWN_PRIMARY_KEY_TYPE
          SchemaTable::Column.new(
            name: name,
            type: type,
            ruby_type: primary_key_ruby_type(type),
            array: keyword_in(options, :array).is_a?(Prism::TrueNode)
          )
        end

        # `id: :string` or `id: { type: :string, ... }`. Rails creates a bigint key when neither names a type,
        # and a type this parser cannot read as a literal is left unknown rather than assumed to be bigint.
        def primary_key_type(id, options)
          declared = id.is_a?(Prism::HashNode) ? keyword_in(options, :type) : id
          return DEFAULT_PRIMARY_KEY_TYPE if declared.nil?

          literal_name(declared)&.to_sym || UNKNOWN_PRIMARY_KEY_TYPE
        end

        # The key is typed only from a call this parser reads completely. `as:` is excluded because the query
        # may define the column, and a non-literal `array:` because it decides the reader's shape.
        def primary_key_type_stated?(call_node, options)
          array = keyword_in(options, :array)
          keywords_read?(call_keywords(call_node)) && keywords_read?(options) &&
            keyword_value(call_node, :as).nil? &&
            (array.nil? || array.is_a?(Prism::TrueNode) || array.is_a?(Prism::FalseNode))
        end

        def call_keywords(call_node)
          call_node.arguments.arguments.grep(Prism::KeywordHashNode).flat_map(&:elements)
        end

        # Every element has a static Symbol key and no key repeats, so `keyword_in` sees what Ruby would pass.
        def keywords_read?(elements)
          keys = elements.map { |element| symbol_key(element.key) if element.is_a?(Prism::AssocNode) }
          keys.none?(&:nil?) && keys.uniq.size == keys.size
        end

        # A decimal key reads as Integer at scale 0 (`Type::DecimalWithoutScale`) and BigDecimal otherwise.
        def primary_key_ruby_type(type)
          type == :decimal ? "Object" : SchemaTable.ruby_type_for(type)
        end

        # A `decimal` column's class follows its literal `scale:`. Any other type takes its SchemaTable mapping.
        # A call this parser does not read completely may still hold a different scale, so it reads untyped.
        def column_ruby_type(type, call_node)
          return SchemaTable.ruby_type_for(type) unless type == :decimal
          return "Object" unless keywords_read?(call_keywords(call_node))

          scale = keyword_value(call_node, :scale)
          SchemaTable.decimal_ruby_type(scale.is_a?(Prism::IntegerNode) ? scale.value : nil)
        end

        def literal_name(node)
          case node
          when Prism::StringNode, Prism::SymbolNode then node.unescaped
          end
        end

        def keyword_value(call_node, name)
          return nil if call_node.arguments.nil?

          call_node.arguments.arguments.each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode)

            value = keyword_in(arg.elements, name)
            return value if value
          end
          nil
        end

        def keyword_in(elements, name)
          elements.each do |pair|
            next unless pair.is_a?(Prism::AssocNode)

            return pair.value if symbol_key(pair.key) == name
          end
          nil
        end

        # Walks the block body collecting `t.<method>(...)` calls. It descends through nested constructs
        # (e.g. `if` branches) but does not recurse into a matched call.
        def collect_column_calls(node, &)
          return if node.nil?

          if node.is_a?(Prism::CallNode) && node.receiver.is_a?(Prism::LocalVariableReadNode)
            yield node
            return
          end

          node.rigor_each_child { |child| collect_column_calls(child, &) }
        end

        def parse_column(call_node)
          method = call_node.name
          case method
          when :references, :belongs_to
            parse_references_column(call_node)
          when :timestamps
            parse_timestamps
          when :column
            parse_generic_column(call_node)
          else
            # Structural DSL call (index / constraint / FK) — not a column.
            return nil if NON_COLUMN_METHODS.include?(method)

            # Any other `t.<method> "name"` is a column. The method name is the type symbol; unknown
            # types degrade to `Object` rather than dropping the column.
            parse_typed_column(method, call_node)
          end
        end

        def parse_typed_column(type, call_node)
          name = string_argument(call_node, 0)
          return nil if name.nil?

          SchemaTable::Column.new(
            name: name,
            type: type,
            ruby_type: column_ruby_type(type, call_node),
            array: keyword_true?(call_node, :array)
          )
        end

        # `t.references "x"` adds an `x_id` integer column. `t.references "x", polymorphic: true`
        # additionally adds an `x_type` string column — without it every `where(x_type: ...)` on the
        # polymorphic owner surfaces as a false `unknown-column`.
        def parse_references_column(call_node)
          name = string_argument(call_node, 0)
          return nil if name.nil?

          columns = [
            SchemaTable::Column.new(name: "#{name}_id", type: :integer, ruby_type: "Integer")
          ]
          if references_polymorphic?(call_node)
            columns << SchemaTable::Column.new(name: "#{name}_type", type: :string, ruby_type: "String")
          end
          columns
        end

        def references_polymorphic?(call_node)
          keyword_true?(call_node, :polymorphic)
        end

        # Returns true iff `call_node` has a `name: true` keyword argument. Used to detect schema
        # modifiers like `t.bigint "status_ids", array: true` (Postgres array column) and `t.references
        # "x", polymorphic: true`.
        def keyword_true?(call_node, name)
          keyword_value(call_node, name).is_a?(Prism::TrueNode)
        end

        # `t.column "name", "type"` / `t.column "name", :type` — the explicit generic column form. The
        # type lives in the second argument; an absent type degrades to `:string`.
        def parse_generic_column(call_node)
          name = string_argument(call_node, 0)
          return nil if name.nil?

          type = string_argument(call_node, 1)
          type_sym = type ? type.to_sym : :string
          SchemaTable::Column.new(
            name: name,
            type: type_sym,
            ruby_type: column_ruby_type(type_sym, call_node),
            array: keyword_true?(call_node, :array)
          )
        end

        def parse_timestamps
          TIMESTAMPS_COLUMNS.map do |name|
            SchemaTable::Column.new(name: name, type: :datetime, ruby_type: "Time")
          end
        end

        def string_argument(call_node, index)
          return nil if call_node.arguments.nil?

          literal_name(call_node.arguments.arguments[index])
        end

        def symbol_key(node)
          case node
          when Prism::SymbolNode then node.unescaped.to_sym
          end
        end
      end
    end
  end
end
