# frozen_string_literal: true

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
      # `t.references "x"` becomes a single `x_id` integer column
      # (foreign-key indices and constraints are ignored — only the
      # column shape matters for type inference). `t.timestamps`
      # adds `created_at` and `updated_at` datetime columns. Any
      # other `t.<method>` call is treated as an unknown column
      # type and falls back to `Object` per
      # `SchemaTable.ruby_type_for`.
      #
      # Designed for the Prism interpretation pattern from
      # rigor-lisp-eval — recursive descent on the AST, no eval.
      class SchemaParser
        TIMESTAMPS_COLUMNS = %w[created_at updated_at].freeze

        # @param source [String] contents of `db/schema.rb`
        # @return [SchemaTable]
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

        def collect_create_table_calls(node, &block)
          return if node.nil?

          if node.is_a?(Prism::CallNode) && node.name == :create_table && node.receiver.nil?
            yield node
          end

          node.compact_child_nodes.each { |child| collect_create_table_calls(child, &block) }
        end

        def parse_create_table(call_node)
          table_name = string_argument(call_node, 0)
          return [nil, nil] if table_name.nil?

          block_node = call_node.block
          columns = { "id" => SchemaTable::Column.new(name: "id", type: :integer, ruby_type: "Integer") }
          columns.delete("id") if id_disabled?(call_node)

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

        def id_disabled?(call_node)
          return false if call_node.arguments.nil?

          call_node.arguments.arguments.each do |arg|
            next unless arg.is_a?(Prism::KeywordHashNode)

            arg.elements.each do |pair|
              next unless pair.is_a?(Prism::AssocNode)

              key = symbol_key(pair.key)
              return true if key == :id && pair.value.is_a?(Prism::FalseNode)
            end
          end
          false
        end

        # Walks the block body collecting `t.<method>(...)` calls.
        # Skips nested blocks (e.g. inside `if`-conditioned columns)
        # only at the top level — for richer schema constructs the
        # parser falls back silently.
        def collect_column_calls(node, &block)
          return if node.nil?

          if node.is_a?(Prism::CallNode) && node.receiver.is_a?(Prism::LocalVariableReadNode)
            yield node
            return
          end

          node.compact_child_nodes.each { |child| collect_column_calls(child, &block) }
        end

        def parse_column(call_node)
          method = call_node.name
          case method
          when :string, :text, :integer, :bigint, :float, :decimal, :boolean,
               :datetime, :timestamp, :date, :time, :binary, :json, :jsonb
            parse_typed_column(method, call_node)
          when :references, :belongs_to
            parse_references_column(call_node)
          when :timestamps
            parse_timestamps
          else
            # Unknown column DSL method — parser stays silent.
            nil
          end
        end

        def parse_typed_column(type, call_node)
          name = string_argument(call_node, 0)
          return nil if name.nil?

          SchemaTable::Column.new(
            name: name,
            type: type,
            ruby_type: SchemaTable.ruby_type_for(type)
          )
        end

        def parse_references_column(call_node)
          name = string_argument(call_node, 0)
          return nil if name.nil?

          column_name = "#{name}_id"
          SchemaTable::Column.new(
            name: column_name,
            type: :integer,
            ruby_type: "Integer"
          )
        end

        def parse_timestamps
          TIMESTAMPS_COLUMNS.map do |name|
            SchemaTable::Column.new(name: name, type: :datetime, ruby_type: "Time")
          end
        end

        def string_argument(call_node, index)
          return nil if call_node.arguments.nil?

          arg = call_node.arguments.arguments[index]
          return nil if arg.nil?

          case arg
          when Prism::StringNode then arg.unescaped
          when Prism::SymbolNode then arg.unescaped
          end
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
