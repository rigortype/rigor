# frozen_string_literal: true

require "prism"

require "rigor/plugin"

require_relative "dry_types/alias_scanner"

module Rigor
  module Plugin
    # rigor-dry-types — Tier A foundation per
    # [ADR-12](../../../../../docs/adr/12-dry-rb-packaging.md).
    #
    # Recognises the canonical dry-types alias-module declaration:
    #
    #     module Types
    #       include Dry.Types()
    #     end
    #
    # and publishes the resulting `{aliased_name => underlying_class}`
    # table as the `:dry_type_aliases` cross-plugin fact (ADR-9).
    # Other dry-rb adapter plugins consume this fact:
    #
    # - `rigor-dry-struct` reads it so `attribute :city, Types::String`
    #   can promote `address.city` from `Dynamic[T]` to `Nominal[String]`
    #   (gated on the slice-6 precision-promotion work + ADR-13
    #   resolver chain).
    # - `rigor-dry-validation` / `rigor-dry-schema` read it for
    #   per-key type recognition in `schema { … }` / `params { … }`
    #   blocks (separate plugin slice).
    #
    # ## Floor / ceiling (slice 1)
    #
    # Slice 1 ships the **floor**:
    #
    # - Recognises `module X; include Dry.Types(); end` for any
    #   constant module name `X` (commonly `Types`, sometimes
    #   `MyTypes` / `AppTypes`).
    # - Maps the **basic** dry-types constants: `String`, `Integer`,
    #   `Float`, `Decimal`, `Symbol`, `Bool`, `True`, `False`, `Nil`,
    #   `Date`, `DateTime`, `Time`, `Hash`, `Array`, `Any`.
    # - Publishes the table as `{ "<Module>::<Alias>" =>
    #   "<UnderlyingClass>" }` so consumers can match on the
    #   qualified constant name they see in source.
    #
    # The **ceiling** (slice 2+):
    #
    # - Recognises nested namespaces (`Types::Coercible::Integer`,
    #   `Types::Strict::Symbol`, `Types::Params::Bool`,
    #   `Types::JSON::Date`) — each is a separate dry-types
    #   "category" with its own coercion semantics.
    # - Recognises user-authored compositions
    #   (`Types::String.constrained(min_size: 1)`,
    #   `Email = Types::String.constrained(format: …)`) so the
    #   alias surface extends beyond the canonical names.
    # - Emits `dry-types.unknown-alias` / `dry-types.alias-shadow`
    #   diagnostics when downstream code references a name that
    #   wasn't published.
    #
    # ## Why no `diagnostics_for_file` at the floor?
    #
    # The plugin's user-visible value at slice 1 is the published
    # fact — every downstream uplift (precision promotion in
    # `address.city`, schema-key recognition in `rigor-dry-validation`)
    # consumes the fact rather than the plugin itself emitting
    # diagnostics. The diagnostics surface lands when the
    # `dry-types.*` rule family becomes load-bearing for
    # demand-driven cases.
    class DryTypes < Rigor::Plugin::Base
      manifest(
        id: "dry-types",
        version: "0.1.0",
        description: "Recognises `module X; include Dry.Types(); end` and publishes the alias table.",
        produces: [:dry_type_aliases]
      )

      # Walks every project file once during `prepare(services)` to
      # build the alias table, then publishes via the ADR-9 fact
      # store. The walk is bounded by the configured `paths:`
      # surface; each file's parse error degrades to "no
      # contribution" without polluting the user-visible
      # diagnostic stream.
      def prepare(services)
        aliases = AliasScanner.scan(paths: scannable_paths(services))
        return if aliases.empty?

        services.fact_store.publish(
          plugin_id: manifest.id,
          name: :dry_type_aliases,
          value: aliases
        )
      end

      def init(_services)
        @scannable_paths = nil
      end

      private

      # Resolves the project's `paths:` to a flat list of `.rb`
      # files the scanner walks. Mirrors `Analysis::Runner`'s
      # `expand_paths` floor; we don't need the runner's full
      # exclude/sort surface because the alias table is a
      # union — any duplicate scan is a no-op.
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

    Rigor::Plugin.register(DryTypes)
  end
end
