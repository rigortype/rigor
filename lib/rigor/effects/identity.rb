# frozen_string_literal: true

require "digest"
require "json"

require_relative "../cache/descriptor"
require_relative "catalog"
require_relative "registry"

module Rigor
  module Effects
    # The **effects cache identity** — the second of ADR-103 WD13's "one cache, two identities, one extra
    # slot" (issue #382; the contract is `docs/internal-spec/effect-summaries.md` § Caching).
    #
    # A run has one identity for its diagnostics and one for its effect summaries. The diagnostics identity
    # is today's and is deliberately untouched by this file: collection is observational, so a diagnostics
    # entry computed with effects on is valid for a run with effects off and vice versa. The effects
    # identity is that identity **plus** the three things that change what a summary means without changing
    # a single analyzed byte:
    #
    # - the **vocabulary version** ({Registry#vocabulary_version}) — a rename or a removal re-reads every
    #   persisted label;
    # - the **catalogue identity** ({Catalog#identity}, schema + a digest of `data/effects/core.yml`) — an
    #   audited row moving from `io` to `io.fs.write` re-colours summaries the analyzed source never moved;
    # - the **`effects:` block digest** — the same value the snapshot header carries, so a `tolerated:` or
    #   `reach:` edit is one visible regeneration event rather than two silently disagreeing digests;
    # - the **plugin fact digest** ({PluginFacts#digest}, #387) — the loaded plugins' labels, attributions,
    #   edges and presets. A plugin upgrade that moves `perform_later` from `io` to `io.db.write` re-colours
    #   summaries the analyzed source never moved, exactly as a re-audited catalogue row does, and the
    #   plugin set is otherwise invisible to a key derived from configuration alone.
    #
    # This module is the ONE place that answers it. {.digest} is the string form (what the ADR-46 snapshot
    # payload carries beside `return_summaries`) and {.descriptor} is the {Cache::Descriptor} form (what the
    # ADR-45 whole-run effects slot is keyed by): the same three inputs, spelled for the two stores.
    #
    # Nothing here is consulted when collection is off — no entry is written, no key is perturbed, and the
    # `effects:` block stays out of `Configuration#to_h` so enabling the feature invalidates no existing
    # project's diagnostics cache.
    module Identity
      # The `configs:` slot the effects identity adds on top of a run's diagnostics key descriptor.
      CONFIG_KEY = "effects.identity"

      module_function

      # The effects identity as a hex digest — the form a store with no descriptor of its own (the ADR-46
      # incremental snapshot) carries alongside its payload, and compares verbatim on restore.
      #
      # @param registry [Registry] the vocabulary whose version participates
      # @param catalog [Catalog] the catalogue whose identity participates
      # @return [String] hex SHA-256
      def digest(configuration:, registry: Registry.default, catalog: Catalog.default, plugin_facts: nil)
        Digest::SHA256.hexdigest(
          [
            "vocabulary:#{registry.vocabulary_version}",
            "catalog:#{catalog.identity}",
            "effects:#{config_digest(configuration)}",
            "plugins:#{plugin_facts&.digest || 'none'}"
          ].join("\x00")
        )
      end

      # The effects identity as a cache KEY descriptor: the run's own diagnostics key descriptor plus one
      # `configs:` entry carrying {.digest}. Composing (rather than rebuilding) is what makes the effects
      # slot inherit every diagnostics-invalidating input — engine version, engine source, RBS libraries,
      # the analyzed-path set — for free, so "the effects identity is the diagnostics identity plus three
      # things" is a property of the code rather than a claim about it.
      #
      # @param base [Cache::Descriptor] the run's diagnostics key descriptor
      def descriptor(base:, configuration:, registry: Registry.default, catalog: Catalog.default,
                     plugin_facts: nil)
        Cache::Descriptor.compose(
          base,
          Cache::Descriptor.new(
            configs: [
              Cache::Descriptor::ConfigEntry.new(
                key: CONFIG_KEY,
                value_hash: digest(configuration: configuration, registry: registry, catalog: catalog,
                                   plugin_facts: plugin_facts)
              )
            ]
          )
        )
      end

      # The `effects:` block of `.rigor.yml`, canonicalised (keys sorted at every depth, rendered as JSON)
      # and hashed. {Snapshot.config_digest} is this method — the snapshot header and the cache identity
      # MUST agree, and the cheapest way to guarantee that is for there to be one implementation.
      def config_digest(configuration)
        Digest::SHA256.hexdigest(JSON.generate(canonicalize(configuration.effects || {})))
      end

      def canonicalize(value)
        case value
        when Hash then value.map { |key, member| [key.to_s, canonicalize(member)] }.sort_by(&:first).to_h
        when Array then value.map { |member| canonicalize(member) }
        when Symbol then value.to_s
        else value
        end
      end
    end
  end
end
