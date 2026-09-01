# frozen_string_literal: true

module Rigor
  module Plugin
    class Activerecord < Rigor::Plugin::Base
      # Maps a discovered ActiveRecord model class name to its resolved table name and the column set the
      # schema attaches to that table. Marshal-clean; the cache producer round-trips it through the
      # standard pair.
      #
      # Construction is two-phase by design:
      # 1. {ModelDiscoverer} walks the project source for model class declarations (direct base-class
      #    children plus transitive STI subclasses) and yields a row per model.
      # 2. The plugin combines those rows with the parsed {SchemaTable} to produce this index.
      #
      # Phase 2's schema is OPTIONAL. A project that ships raw migrations only — the DB-agnostic Rails
      # pattern, where `db/schema.rb` is gitignored (Redmine) — has no schema to combine, and `schema_table:
      # nil` then yields the REDUCED index: every {Entry} carries its resolved table name, associations,
      # enums, scopes, validations, callbacks and aliases, and an EMPTY column set. Only the column-keyed
      # surface stands down; the schema was never an input to any of the rest. {#columns_known?} tells the
      # two modes apart — an empty column set means "the schema is unknown", not "this model has no
      # columns", and consumers that would fire on an unrecognised column must not read the two the same
      # way.
      #
      # `table_name_override` is non-nil when the source contained `self.table_name = "..."`. When nil,
      # the table name derives from {Inflector.tableize}.
      #
      # Single-table-inheritance subclasses (`class Admin < User`) carry an `sti_parent:` pointer; their
      # {Entry} resolves its table from the root model and inherits the chain's declared associations /
      # enums / aliases / scopes / validations / callbacks.
      class ModelIndex
        # `associations` is a frozen `Array<Hash>` where each row carries `{ name:, kind:, target:,
        # nullable: }`:
        #
        # - `name`   — String, the association method name as the user invokes it (`"posts"`).
        # - `kind`   — `:singular` (`belongs_to` / `has_one`) or `:collection` (`has_many`).
        # - `target` — String, the target class name resolved either from an explicit `class_name:`
        #              option or via {Inflector.classify}.
        # - `nullable` — Boolean; whether a `:singular` accessor can return `nil`. `has_one` → `true`;
        #              `belongs_to` → `false` (required by default since Rails 5) unless `optional: true`
        #              / `required: false`. Meaningless for `:collection` rows.
        #
        # `table_name_exact` records whether `table_name` is the name the application actually uses or a
        # derivation nothing corroborates. It is true when the source DECLARED it (`self.table_name =
        # "..."` somewhere in the STI chain) or when the parsed schema has a table by that name; false when
        # the name is a bare {Inflector.tableize} guess the schema could not confirm. Only a true reading
        # licenses pinning the name to a value — see `Activerecord#table_name_return_type`.
        Entry = Struct.new(:class_name, :table_name, :table_name_exact, :columns, :associations,
                           :enums, :scopes, :validations, :callbacks, :aliases,
                           keyword_init: true) do
          def table_name_exact? = table_name_exact == true

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

          # `validations` is `Array<attribute_name>` covering both `validates :name, ...` and the
          # `validates_*_of :name, ...` shorthand families.
          def validation?(name) = validations.include?(name.to_s)
          def validated_attributes = validations

          # `callbacks` is `Array<{ name:, callback: }>`.
          def callback_targets = callbacks.map { |c| c[:name] }

          # `aliases` is `Hash<alias_name => target_attribute>` populated from `alias_attribute`
          # declarations.
          def alias?(name) = aliases.key?(name.to_s)
          def resolve_alias(name) = aliases[name.to_s]
        end

        attr_reader :entries

        def initialize(entries, columns_known: true)
          @entries = entries.freeze
          @columns_known = columns_known
          freeze
        end

        # Whether a schema was parsed into this index. `false` in the reduced mode (no `db/schema.rb` and no
        # `db/structure.sql`), where every entry's column set is empty because the columns are UNKNOWN.
        def columns_known? = @columns_known == true

        def find(class_name)
          entries[class_name.to_s]
        end

        def model?(class_name) = entries.key?(class_name.to_s)
        def class_names = entries.keys
        def empty? = entries.empty?

        # `schema_table` may be nil — see the reduced mode described on the class. Every other input is
        # source-derived, so the entries are identical in both modes apart from `columns`.
        def self.build(model_rows:, schema_table:, type_override_columns: nil)
          rows_by_name = model_rows.to_h { |row| [row.fetch(:class_name), row] }
          overrides = type_override_columns || []

          entries = model_rows.each_with_object({}) do |row, acc|
            class_name = row.fetch(:class_name)
            # The STI ancestry chain, root → self. For a plain (non-STI) model this is just `[row]`.
            chain = sti_chain(row, rows_by_name)
            declared = declared_table_name(chain)
            table_name = declared || inflected_table_name(chain)
            columns = apply_type_overrides(schema_table&.columns_for(table_name) || [], overrides)

            # STI children inherit their ancestors' declared associations / enums / aliases / scopes /
            # validations / callbacks. Without the merge a `where(<parent-association>: ...)` on the
            # child would surface as a false `unknown-column`.
            acc[class_name] = Entry.new(
              class_name: class_name,
              table_name: table_name,
              table_name_exact: table_name_exact?(chain, declared, table_name, schema_table),
              columns: columns.freeze,
              associations: merge_named_rows(chain.flat_map { |r| Array(r[:associations]) }),
              enums: merge_enums(chain),
              scopes: chain.flat_map { |r| Array(r[:scopes]) }.uniq.freeze,
              validations: chain.flat_map { |r| Array(r[:validations]) }.uniq.freeze,
              callbacks: chain.flat_map { |r| Array(r[:callbacks]) }.map(&:freeze).freeze,
              aliases: merge_aliases(chain)
            ).freeze
          end
          new(entries.freeze, columns_known: !schema_table.nil?)
        end

        # Remaps every type-overridden column's `ruby_type` to `"Object"` so instance-side column narrowing
        # declines to narrow it (the `"Object"` case in `ruby_type_to_type`). A `serialize` / `mount_uploader`
        # / custom-`attribute` column reads as a rich object at runtime, not its SQL scalar, so narrowing it
        # to e.g. `String` false-positives on the object's methods (`note.position.diff_refs`). The column
        # stays in the set, so `where(col: ...)` existence validation is unaffected — only its value type.
        def self.apply_type_overrides(columns, overrides)
          return columns if overrides.empty?

          columns.map do |column|
            next column unless overrides.include?(column.name)

            SchemaTable::Column.new(
              name: column.name, type: column.type, ruby_type: "Object", array: column.array
            )
          end
        end

        # The STI ancestry chain for a row, ordered root → self. Walks `sti_parent` pointers, guarding
        # against a cycle.
        def self.sti_chain(row, rows_by_name, seen = [])
          class_name = row.fetch(:class_name)
          parent_name = row[:sti_parent]
          return [row] if parent_name.nil? || seen.include?(class_name)

          parent = rows_by_name[parent_name]
          return [row] if parent.nil?

          sti_chain(parent, rows_by_name, seen + [class_name]) + [row]
        end

        # The effective table name for an STI chain: the nearest explicit `self.table_name =` override
        # walking leaf → root, else the name inflected from the root class.
        def self.sti_table_name(chain)
          declared_table_name(chain) || inflected_table_name(chain)
        end

        # Whether `table_name` is the name the application actually uses, rather than a derivation nothing
        # corroborates — the condition that licenses pinning it to a value.
        #
        # A class anywhere in the STI chain that computes its own name (`def self.table_name`, a non-literal
        # `self.table_name =`) is never exact, EVEN IF the schema happens to have a table matching the
        # inflection: that match would be a coincidence, not a corroboration. Otherwise a literal
        # declaration is exact by construction, and a bare inflection is exact only when the parsed schema
        # confirms a table by that name.
        def self.table_name_exact?(chain, declared, table_name, schema_table)
          return false if chain.any? { |row| row[:table_name_computed] }
          return true unless declared.nil?

          schema_table&.table?(table_name) || false
        end

        # The nearest explicit `self.table_name = "..."` walking leaf → root, or nil when the chain declared
        # none. Split out from {sti_table_name} because "was it declared?" is the question
        # `table_name_exact` answers, and re-deriving it from the resolved name is not possible.
        def self.declared_table_name(chain)
          chain.reverse_each do |row|
            override = row[:table_name_override]
            return override if override
          end
          nil
        end

        # The name inflected from the ROOT class of the chain — an STI child shares its root's table.
        def self.inflected_table_name(chain)
          Rigor::Plugin::Inflector.tableize(strip_leading_namespace(chain.first.fetch(:class_name)))
        end

        # Dedups association-style rows by `:name`, keeping the LAST occurrence so a child redeclaration
        # overrides the inherited ancestor row.
        def self.merge_named_rows(rows)
          seen = {}
          rows.each { |row| seen[row[:name]] = row }
          seen.values.map(&:freeze).freeze
        end

        # `Hash<column => Array<value>>` merged across the STI chain; a child redeclaration of the same
        # enum column overrides the ancestor's value list.
        def self.merge_enums(chain)
          chain.each_with_object({}) do |row, acc|
            (row[:enums] || {}).each { |col, values| acc[col] = Array(values).map(&:freeze).freeze }
          end.freeze
        end

        # `Hash<alias => target>` merged across the STI chain.
        def self.merge_aliases(chain)
          chain.each_with_object({}) do |row, acc|
            (row[:aliases] || {}).each { |name, target| acc[name.to_s] = target.to_s }
          end.freeze
        end

        # `::User` → `User`. The discoverer might prefix with `::` for top-level constants depending on
        # how it resolved the path; the table-name derivation uses the short form regardless.
        def self.strip_leading_namespace(name)
          name.start_with?("::") ? name[2..] : name
        end
      end
    end
  end
end
