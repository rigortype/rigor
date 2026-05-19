# frozen_string_literal: true

module Rigor
  module Plugin
    class Activerecord < Rigor::Plugin::Base
      # Maps a discovered ActiveRecord model class name to its
      # resolved table name and the column set the schema attaches
      # to that table. Marshal-clean; the cache producer round-
      # trips it through the standard pair.
      #
      # Construction is two-phase by design:
      # 1. {ModelDiscoverer} walks the project source for class
      #    declarations whose superclass matches one of the
      #    configured `model_base_classes`. For each, it yields a
      #    `{ class_name:, table_name_override: }` row.
      # 2. The plugin combines those rows with the parsed
      #    {SchemaTable} to produce this index.
      #
      # `table_name_override` is non-nil when the source contained
      # `self.table_name = "..."`. When nil, the table name
      # derives from {Inflector.tableize}.
      class ModelIndex
        # `associations` is a frozen `Array<Hash>` where each
        # row carries `{ name:, kind:, target: }`:
        #
        # - `name`   — String, the association method name as
        #              the user invokes it (`"posts"`).
        # - `kind`   — `:singular` (`belongs_to` / `has_one`)
        #              or `:collection` (`has_many`).
        # - `target` — String, the target class name resolved
        #              either from an explicit `class_name:`
        #              option or via {Inflector.classify}.
        Entry = Struct.new(:class_name, :table_name, :columns, :associations,
                           :enums, :scopes, :validations, :callbacks,
                           keyword_init: true) do
          def column(name)
            columns.find { |c| c.name == name.to_s }
          end

          def column?(name)
            !column(name).nil?
          end

          def column_names = columns.map(&:name)

          def association(name)
            associations.find { |a| a[:name] == name.to_s }
          end

          def association?(name)
            !association(name).nil?
          end

          def association_names = associations.map { |a| a[:name] }

          # `enums` is `Hash<column_name => Array<value_name>>`.
          def enum?(name) = enums.key?(name.to_s)
          def enum_values(name) = enums.fetch(name.to_s, [])

          # `scopes` is `Array<scope_name>`.
          def scope?(name) = scopes.include?(name.to_s)

          # `validations` is `Array<attribute_name>` covering
          # both `validates :name, ...` and the
          # `validates_*_of :name, ...` shorthand families.
          def validation?(name) = validations.include?(name.to_s)
          def validated_attributes = validations

          # `callbacks` is `Array<{ name:, callback: }>`.
          def callback_targets = callbacks.map { |c| c[:name] }
        end

        attr_reader :entries

        def initialize(entries)
          @entries = entries.freeze
          freeze
        end

        def find(class_name)
          entries[class_name.to_s]
        end

        def model?(class_name) = entries.key?(class_name.to_s)
        def class_names = entries.keys
        def empty? = entries.empty?

        def self.build(model_rows:, schema_table:)
          entries = model_rows.each_with_object({}) do |row, acc|
            class_name = row.fetch(:class_name)
            override = row[:table_name_override]
            table_name = override || Inflector.tableize(strip_leading_namespace(class_name))
            columns = schema_table.columns_for(table_name) || []
            associations = Array(row[:associations]).map(&:freeze).freeze
            enums = (row[:enums] || {}).transform_values { |vs| Array(vs).map(&:freeze).freeze }.freeze
            scopes = Array(row[:scopes]).freeze
            validations = Array(row[:validations]).freeze
            callbacks = Array(row[:callbacks]).map(&:freeze).freeze
            acc[class_name] = Entry.new(
              class_name: class_name,
              table_name: table_name,
              columns: columns.freeze,
              associations: associations,
              enums: enums,
              scopes: scopes,
              validations: validations,
              callbacks: callbacks
            ).freeze
          end
          new(entries.freeze)
        end

        # `::User` → `User`. The discoverer might prefix with
        # `::` for top-level constants depending on how it
        # resolved the path; the table-name derivation uses the
        # short form regardless.
        def self.strip_leading_namespace(name)
          name.start_with?("::") ? name[2..] : name
        end
      end
    end
  end
end
