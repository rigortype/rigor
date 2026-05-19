# frozen_string_literal: true

require "prism"

require "rigor/plugin"

require_relative "dry_schema/schema_scanner"

module Rigor
  module Plugin
    # rigor-dry-schema — Tier A per
    # [ADR-12](../../../../../docs/adr/12-dry-rb-packaging.md) and the
    # slicing plan in [docs/design/20260517-dry-validation-slicing.md](../../../../../docs/design/20260517-dry-validation-slicing.md).
    #
    # Recognises the canonical dry-schema declaration shapes:
    #
    #     NewUserSchema = Dry::Schema.Params do
    #       required(:email).filled(:string)
    #       required(:age).value(:integer)
    #       optional(:nickname).maybe(:string)
    #     end
    #
    #     ProductJSON = Dry::Schema.JSON do
    #       required(:sku).filled(:string)
    #     end
    #
    #     RawSchema = Dry::Schema.define do
    #       required(:foo).value(:string)
    #     end
    #
    # and publishes the resulting
    # `{schema_const_fqn => {required: {key => underlying_class}, optional: {…}}}`
    # table as the `:dry_schema_table` cross-plugin fact (ADR-9).
    # Downstream `rigor-dry-validation` consumes the fact for
    # per-Contract typed-payload synthesis.
    #
    # ## Predicate type recognition
    #
    # Each `required(:key).<predicate>(<arg>)` row maps the predicate
    # argument to an underlying Ruby class via the dry-schema
    # canonical-type vocabulary:
    #
    # - `:string` / `:integer` / `:float` / `:decimal` / `:symbol` /
    #   `:bool` / `:nil` / `:date` / `:date_time` / `:time` / `:hash`
    #   / `:array` map to their underlying class.
    # - The four predicate verbs `filled` / `value` / `maybe` /
    #   `each` are accepted on the same row; their semantic
    #   difference (whether the value is nullable or coerced) does
    #   not change the underlying class for Rigor's purposes.
    # - References to dry-types aliases (`value(Types::Email)`,
    #   `filled(Types::String)`) resolve through the
    #   `:dry_type_aliases` ADR-9 fact published by `rigor-dry-types`
    #   when that plugin is loaded; without it the row degrades to
    #   "no type contribution from this key".
    #
    # ## Floor / ceiling (slice 1)
    #
    # Slice 1 ships the **floor**:
    #
    # - Top-level `Foo = Dry::Schema.{Params,JSON,define} { ... }`
    #   assignments. Class-level constants (`class Bar; SCHEMA =
    #   Dry::Schema.Params { ... }; end`) work too — the walker
    #   prefixes the enclosing constant chain.
    # - `required(:key).<predicate>(:type_symbol_or_constant)` rows
    #   for the canonical-type vocabulary above.
    # - Publishes the table; no user-facing diagnostics yet.
    #
    # The **ceiling** (slice 2+):
    #
    # - Synthesise typed `result.to_h` returns from each schema
    #   via ADR-16 Tier C heredoc-template substrate.
    # - Nested schemas (`schema(do ... end)` inside another row).
    # - `predicates(:size?)` / `each { ... }` recursion.
    # - Per-row `dry-schema.unknown-predicate` /
    #   `dry-schema.unknown-type` `:info` diagnostics when a
    #   row's predicate or type symbol isn't recognised.
    class DrySchema < Rigor::Plugin::Base
      manifest(
        id: "dry-schema",
        version: "0.1.0",
        description: "Recognises `Dry::Schema.{Params,JSON,define} { ... }` declarations " \
                     "and publishes the per-schema typed-key table.",
        produces: [:dry_schema_table],
        consumes: [{ plugin_id: "dry-types", name: :dry_type_aliases, optional: true }]
      )

      # Walks every project file once during `prepare(services)` to
      # build the schema table, then publishes via the ADR-9 fact
      # store. Mirrors the rigor-dry-types `#prepare` shape — the
      # walk is bounded by `paths:`, parse errors degrade silently.
      def prepare(services)
        type_aliases = services.fact_store.read(plugin_id: "dry-types", name: :dry_type_aliases) || {}
        table = SchemaScanner.scan(paths: scannable_paths(services), type_aliases: type_aliases)
        return if table.empty?

        services.fact_store.publish(
          plugin_id: manifest.id,
          name: :dry_schema_table,
          value: table
        )
      end

      def init(_services)
        @scannable_paths = nil
      end

      private

      def scannable_paths(services)
        @scannable_paths ||= services.configuration.paths.flat_map do |entry|
          if File.directory?(entry)
            Dir.glob(File.join(entry, "**", "*.rb"), sort: true)
          elsif File.file?(entry) && entry.end_with?(".rb")
            [entry]
          else
            []
          end
        end.uniq.freeze
      end
    end

    Rigor::Plugin.register(DrySchema)
  end
end
