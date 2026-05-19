# frozen_string_literal: true

module Rigor
  module Plugin
    class Activerecord < Rigor::Plugin::Base
      # Parsed `db/schema.rb`. Maps each table name to its column
      # set; each column carries its declared type. Marshal-clean
      # by construction so the cache producer can round-trip it
      # without a custom serialize / deserialize pair.
      #
      # The mapping from Rails column types to Ruby class names is
      # deliberately conservative — `:string`/`:text` → `String`,
      # `:integer`/`:bigint` → `Integer`, `:boolean` → `bool`,
      # `:datetime`/`:timestamp` → `Time`, `:date` → `Date`,
      # `:decimal`/`:float` → `Float`. Exotic types (json, jsonb,
      # ltree, hstore, custom) fall back to `Object` so the
      # plugin stays silent rather than guessing.
      class SchemaTable
        Column = Struct.new(:name, :type, :ruby_type, keyword_init: true) do
          def to_h = { name: name, type: type, ruby_type: ruby_type }
        end

        # Map ActiveRecord column types → Ruby class names.
        RUBY_TYPE_MAPPING = {
          string: "String",
          text: "String",
          integer: "Integer",
          bigint: "Integer",
          float: "Float",
          decimal: "Float",
          boolean: "bool",
          datetime: "Time",
          timestamp: "Time",
          date: "Date",
          time: "Time",
          binary: "String",
          json: "Object",
          jsonb: "Object"
        }.freeze

        # Implicit columns that every Rails table has unless the
        # schema explicitly opts out. The plugin assumes these
        # exist; users who run `create_table id: false` get no
        # implicit `id` column from the parser, but most apps
        # never disable it.
        IMPLICIT_COLUMNS = [
          Column.new(name: "id", type: :integer, ruby_type: "Integer").freeze
        ].freeze

        attr_reader :tables

        def initialize(tables)
          @tables = tables.freeze
          freeze
        end

        def column(table_name, column_name)
          table = tables[table_name.to_s]
          return nil if table.nil?

          table[column_name.to_s]
        end

        def columns_for(table_name)
          table = tables[table_name.to_s]
          return nil if table.nil?

          table.values
        end

        def table?(table_name)
          tables.key?(table_name.to_s)
        end

        def table_names = tables.keys

        # Maps a Rails column type symbol to its Ruby class name.
        # Returns "Object" for unknown types — the analyzer treats
        # that as "do not narrow" (silent on unknowns).
        def self.ruby_type_for(column_type)
          RUBY_TYPE_MAPPING.fetch(column_type.to_sym, "Object")
        end
      end
    end
  end
end
