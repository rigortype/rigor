# frozen_string_literal: true

require "digest"
require_relative "runner"
require_relative "../cache/value_digest"

module Rigor
  module Analysis
    # ADR-88 WD1 — a stable fingerprint of the plugin FACT SURFACE for an incremental run: the plugin-computed
    # values a cached per-file diagnostic can depend on but that the snapshot's global fingerprint (config /
    # gems / RBS env / `signature_paths:`) does NOT capture.
    #
    # The gap: a plugin like `rigor-sorbet` reads `.rb` / `.rbi` sig files under its own `paths:` / `rbi_paths:`
    # (outside `signature_paths:`), builds a catalog, and contributes `dynamic_return` types at call sites in
    # OTHER files. An edit to such a sig file changes the types those call sites resolve WITHOUT moving any
    # analyzed file's content — so `IncrementalSnapshot.fingerprint` stays fresh, the recheck sees an empty
    # changed set, and it serves the stale cached diagnostics. Nothing in the ADR-46 dependency graph records
    # the cross-file plugin read (the catalog is plugin-internal, not a `Scope` table).
    #
    # This class digests three fact-surface channels after plugin `#prepare`:
    #   (a) every ADR-9 fact-store publication `(plugin_id, name) -> value` (a producer/consumer fact such as
    #       `activerecord :model_index`, `dry-types :dry_type_aliases`),
    #   (b) every declared ADR-60 producer's computed value (`sorbet :catalog`, `actionpack :controller_index`),
    #   (c) each plugin's optional {Plugin::Base#incremental_state_fingerprint} — a hook for internal catalog
    #       state that lives in neither (a) nor (b).
    #
    # The digest rides the {Cache::IncrementalSnapshot} (schema 9); a warm recheck compares it and, on a
    # mismatch, invalidates the snapshot and runs a full analysis (the conservative, sound direction).
    #
    # OPAQUE plugins: a plugin that CONTRIBUTES per-call types (`dynamic_return` / `narrowing_facts`) but
    # declares NONE of (a)/(b)/(c) has stale-able state the fingerprint cannot see. Rather than silently risk a
    # stale reuse, such a plugin makes the snapshot un-reusable (a full analysis every run) and is named in a
    # one-line note. The bundled contributing plugins all declare a surface (producers, facts, or the hook), so
    # the bundled set stays incremental-capable; a third-party plugin that contributes types must do the same.
    #
    # The probe is ALWAYS sequential and independent of the analysis's pool mode, so the invalidation decision
    # is identical whether the recheck ran pooled or sequential (the pooled-vs-sequential parity requirement).
    class PluginFactFingerprint
      # `digest` is nil when no plugins are loaded — the fast path (nothing to fingerprint), which reuses
      # freely. `opaque_plugin_ids` names contributing-but-surfaceless plugins (see the class doc); when
      # non-empty the snapshot is never reused.
      Result = Data.define(:digest, :opaque_plugin_ids) do
        def opaque?
          !opaque_plugin_ids.empty?
        end

        # A warm recheck may reuse the snapshot only when this run is not opaque and its fact-surface digest
        # matches the one the snapshot stored. A nil `stored` (a pre-schema-9 snapshot, or a snapshot written
        # before any plugin existed) never matches a computed digest — the conservative full-run direction —
        # while a nil==nil (plugin-free project both times) reuses.
        def reusable_against?(stored)
          !opaque? && digest == stored
        end
      end

      # The SEQUENTIAL probe: load the plugins and run `#prepare` fresh, then fingerprint. Pool-independent
      # (its prepare pass is always sequential), so it is the pooled-mode path and the reference the parity
      # spec asserts against.
      def self.compute(configuration:, cache_store:, plugin_requirer: nil)
        new.digest_registry(
          prepared_registry(configuration: configuration, cache_store: cache_store, plugin_requirer: plugin_requirer)
        )
      end

      # ADR-88 WD1 — the CHEAP post-hoc path: fingerprint a registry the analysis runner ALREADY prepared
      # (sequential runs run `#prepare` and consult the producers during analysis, so producer values are
      # memoised and their cache entries current). Avoids a second `#prepare` pass and a second producer
      # validation. Used only when the runner's main-process registry is prepared (sequential); the pooled path
      # (whose main process skips `#prepare`) falls back to {.compute}. Both compute the identical digest for a
      # given fact surface, so the reuse decision is pool-independent.
      def self.from_registry(registry)
        new.digest_registry(registry)
      end

      # The fact surface reduced to the one String a cache KEY can carry, or nil when the surface cannot be
      # seen at all (an opaque plugin — one that contributes call-site types while declaring none of the three
      # fingerprint channels). A nil obliges the caller to decline caching entirely, which is the same
      # conservative direction {Result#reusable_against?} takes for the incremental snapshot: a key that
      # silently omitted an invisible input would serve a stale value rather than miss.
      #
      # Keeping the opaque decision here, rather than at each cache's call site, means a new consumer cannot
      # key on `digest` while forgetting that an opaque surface makes it meaningless.
      def self.key_digest(registry)
        result = from_registry(registry)
        result.opaque? ? nil : result.digest.to_s
      end

      # Loads the plugins and runs every `#prepare` hook sequentially, returning the prepared registry (nil on
      # any failure → the caller treats it as "no fact surface").
      def self.prepared_registry(configuration:, cache_store:, plugin_requirer:)
        Runner::ProjectPrePasses.new(
          configuration: configuration, cache_store: cache_store, buffer: nil,
          plugin_requirer: plugin_requirer, pool_mode: -> { false }
        ).prepared_registry
      rescue StandardError
        nil
      end

      def digest_registry(registry)
        return Result.new(digest: nil, opaque_plugin_ids: [].freeze) if registry.nil? || registry.empty?

        opaque = []
        facts_by_plugin = facts_by_plugin(registry, opaque)
        parts = fact_parts(facts_by_plugin)
        registry.plugins.each { |plugin| collect_plugin_parts(plugin, facts_by_plugin, parts, opaque) }
        # Sort the parts so the digest is independent of plugin registration / iteration order.
        Result.new(
          digest: Digest::SHA256.hexdigest(parts.sort.join("\x00")),
          opaque_plugin_ids: opaque.uniq.freeze
        )
      end

      private

      # Channel (a) parts: one `fact\x1f<plugin>\x1f<name=digest,...>` string per publishing plugin.
      def fact_parts(facts_by_plugin)
        facts_by_plugin.map { |plugin_id, entries| "fact\x1f#{plugin_id}\x1f#{entries.sort.join("\x1e")}" }
      end

      # Appends one plugin's producer / hook parts to `parts` and marks it opaque when it contributes a type
      # (`dynamic_return` / `narrowing_facts`) yet declares NONE of (a)/(b)/(c).
      def collect_plugin_parts(plugin, facts_by_plugin, parts, opaque)
        id = safe_id(plugin)
        has_facts = facts_by_plugin.key?(id)
        has_producers = collect_producer_parts(plugin, id, parts, opaque)
        has_hook = collect_hook_part(plugin, id, parts, opaque)
        surface = has_facts || has_producers || has_hook
        opaque << id if !surface && contributes_types?(plugin)
      end

      # `{ plugin_id => ["name=digest", ...] }` for every ADR-9 published fact (channel a). A plugin that
      # published nothing does not appear.
      #
      # A fact the fingerprint cannot digest is an input it cannot see, so its publisher is opaque, whether or
      # not the publisher contributes a type itself: other plugins read its facts. A fact store that cannot be
      # read at all makes every plugin opaque. Both force the full run; dropping the facts instead would let a
      # plugin with another surface reuse a snapshot its facts no longer match.
      def facts_by_plugin(registry, opaque)
        result = Hash.new { |hash, key| hash[key] = [] }
        fact_store = registry.plugins.first&.services&.fact_store
        fact_store&.each_fact do |fact|
          plugin_id = fact.plugin_id.to_s
          begin
            result[plugin_id] << "#{fact.name}=#{digest_value(fact.value)}"
          rescue StandardError
            opaque << plugin_id
          end
        end
        result
      rescue StandardError
        registry.plugins.each { |plugin| opaque << safe_id(plugin) }
        Hash.new { |hash, key| hash[key] = [] }
      end

      # Channel (b): a stable signature of every declared producer's VALUE — a digest of the producer's own
      # value, NOT its cache entry blob. The distinction is load-bearing: the blob also carries the dependency
      # descriptor (the input files' digests), so it changes on ANY input edit — including a value-PRESERVING
      # one (editing a controller's body without adding an action leaves `controller_index` identical but
      # rewrites its blob). Digesting the value invalidates the snapshot only when a producer's contributed
      # value actually moves (a new action, a changed sig), which is what a cached diagnostic can depend on;
      # a value-preserving edit keeps the recheck incremental. Returns true when the plugin declared at least
      # one producer (a surface); a producer whose value cannot be digested marks the plugin opaque.
      # rubocop:disable-next Naming/PredicateMethod -- reports has-surface AND appends parts (a side-effecting builder)
      def collect_producer_parts(plugin, id, parts, opaque)
        producer_ids = plugin.class.producers.keys
        return false if producer_ids.empty?

        producer_ids.sort.each do |producer_id|
          parts << "prod\x1f#{id}\x1f#{producer_id}\x1f#{digest_value(plugin.producer_value(producer_id))}"
        rescue StandardError
          opaque << id
        end
        true
      end

      # Channel (c): the optional {Plugin::Base#incremental_state_fingerprint} hook. Returns true when the
      # plugin defines it (it has a surface).
      def collect_hook_part(plugin, id, parts, opaque)
        return false unless plugin.respond_to?(:incremental_state_fingerprint)

        parts << "hook\x1f#{id}\x1f#{digest_value(plugin.incremental_state_fingerprint)}"
        true
      rescue StandardError
        opaque << id
        true
      end

      # A digest of a fact / producer / hook value that depends on the value alone (issue #1574). A producer's
      # value is computed on one run and served from its ADR-45 cache entry on the next; the two are equal but
      # do not share the same objects, so a digest of their `Marshal.dump` bytes differed and invalidated the
      # snapshot on every such switch. {Cache::ValueDigest} reads no identity. A value it cannot digest raises
      # to the caller, which marks the plugin opaque (never a silent wrong-value digest).
      def digest_value(value)
        Cache::ValueDigest.hexdigest(value)
      end

      def contributes_types?(plugin)
        klass = plugin.class
        klass.dynamic_returns.any? || klass.narrowing_facts_rules.any?
      rescue StandardError
        false
      end

      def safe_id(plugin)
        plugin.manifest.id.to_s
      rescue StandardError
        plugin.class.name.to_s
      end
    end
  end
end
