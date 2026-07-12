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
    # and publishes the resulting `{aliased_name => underlying_class}` table as the `:dry_type_aliases`
    # cross-plugin fact (ADR-9). Other dry-rb adapter plugins consume this fact:
    #
    # - `rigor-dry-struct` reads it so `attribute :city, Types::String` promotes `address.city` from
    #   `Dynamic[Top]` to `Nominal[String]` via ADR-18's `returns_from_arg:` fact lookup.
    # - `rigor-dry-validation` / `rigor-dry-schema` read it for per-key type recognition in `schema { … }`
    #   / `params { … }` blocks (separate plugin slice).
    #
    # ## Floor / ceiling (slice 1)
    #
    # Slice 1 ships the **floor**:
    #
    # - Recognises `module X; include Dry.Types(); end` for any constant module name `X` (commonly
    #   `Types`, sometimes `MyTypes` / `AppTypes`).
    # - Maps the **basic** dry-types constants: `String`, `Integer`, `Float`, `Decimal`, `Symbol`, `Bool`,
    #   `True`, `False`, `Nil`, `Date`, `DateTime`, `Time`, `Hash`, `Array`, `Any`.
    # - Publishes the table as `{ "<Module>::<Alias>" => "<UnderlyingClass>" }` so consumers can match on
    #   the qualified constant name they see in source.
    #
    # Implemented beyond the floor:
    #
    # - Nested-namespace aliases (`Types::Coercible::Integer`, `Types::Strict::Symbol`,
    #   `Types::Params::Bool`, `Types::JSON::Date`) — the four coercion categories each map to the same
    #   underlying class as their canonical shortcut.
    # - User-authored compositions (`Email = Types::String.constrained(...)`, transitive resolution
    #   through composition chains) — the alias surface extends beyond the 15 canonical names.
    #
    # Deferred:
    #
    # - `dry-types.unknown-alias` / `dry-types.alias-shadow` diagnostics when downstream code references
    #   a name that wasn't published.
    #
    # ## Why no `diagnostics_for_file` at the floor?
    #
    # The plugin's user-visible value at slice 1 is the published fact — every downstream uplift
    # (precision promotion in `address.city`, schema-key recognition in `rigor-dry-validation`) consumes
    # the fact rather than the plugin itself emitting diagnostics. The diagnostics surface lands when the
    # `dry-types.*` rule family becomes load-bearing for demand-driven cases.
    class DryTypes < Rigor::Plugin::Base
      manifest(
        id: "dry-types",
        version: "0.1.0",
        description: "Recognises `module X; include Dry.Types(); end` and publishes the alias table.",
        produces: [:dry_type_aliases]
      )

      # Cached alias-table producer (ADR-60 WD3 record-and-validate). The scan Prism-parses every `.rb` file
      # under the project's `paths:` tree to find `include Dry.Types()` declarations — an expensive pass that
      # ran on EVERY invocation (cold and warm) because `#prepare` called {AliasScanner.scan} directly, with
      # no cache. It now rides `cache_for`: a warm run re-globs + re-digests the watched tree (cheap SHA over
      # file bytes, no AST build) and reuses the cached table instead of re-parsing. This is the dominant win
      # even for a project that ships no dry-types module — the parse still has to run to prove that, and now
      # the empty result is cached too.
      #
      # `watch:` covers exactly the files the scan reads: one glob per project `paths:` entry, co-extensive
      # with {#scannable_paths}. A {Cache::Descriptor::GlobEntry} digests every file matching its glob, so a
      # content edit, a file addition, and a file removal anywhere under those paths all move the digest and
      # invalidate the entry. The scan reads no file individually through the `IoBoundary`, so the evaluated
      # `watch:` globs are the entire dependency descriptor — and they fully cover the scan's input.
      producer :dry_type_aliases, watch: -> { alias_watch_globs } do |_params|
        AliasScanner.scan(paths: scannable_paths)
      end

      # Builds the (cached) alias table and publishes it via the ADR-9 fact store. `producer_value` runs the
      # producer through `cache_for` and memoises the result — including a rescued nil — for the run.
      def prepare(services)
        aliases = producer_value(:dry_type_aliases)
        return if aliases.nil? || aliases.empty?

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

      # Resolves the project's `paths:` to a flat list of `.rb` files the scanner walks. Mirrors
      # `Analysis::Runner`'s `expand_paths` floor; we don't need the runner's full exclude/sort surface
      # because the alias table is a union — any duplicate scan is a no-op.
      def scannable_paths
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

      # The `watch:` glob tuples covering the scan's entire input — one `[root, pattern]` per project `paths:`
      # entry. A directory entry watches its whole `**/*.rb` subtree; a single-file `.rb` entry watches
      # exactly that file (`[dir, basename]`). Roots are expanded to absolute paths by
      # `Plugin::Base#watch_glob_entries`, so a relative CLI path (`app/models`) re-validates against the same
      # tree from the project root on the next run. Co-extensive with {#scannable_paths}: every `.rb` the scan
      # would read is watched, so any edit / addition / removal under those paths invalidates the cache.
      def alias_watch_globs
        services.configuration.paths.filter_map do |entry|
          if File.directory?(entry)
            [entry, "**/*.rb"]
          elsif File.file?(entry) && entry.end_with?(".rb")
            [File.dirname(entry), File.basename(entry)]
          end
        end
      end
    end

    Rigor::Plugin.register(DryTypes)
  end
end
