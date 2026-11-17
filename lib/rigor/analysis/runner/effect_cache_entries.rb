# frozen_string_literal: true

require_relative "../run_cache_key"
require_relative "../../effects/effect_table"

module Rigor
  module Analysis
    class Runner
      # The reads and writes of the whole-run effects sidecar's two cache entries (ADR-103 WD13 / #382, #482):
      # each is a function of the cache store it is handed and returns the stored value or what the store
      # answered, reading and writing no `Runner` state. {Runner} keeps the serve and store sequences
      # (`serve_effect_collections`, `served_from_effect_entries?`, `store_effect_collections`), which adopt the
      # result into the run's effect tables and decide when to ask.
      module EffectCacheEntries
        module_function

        # The read half of the serving entry (#482). A miss, a stale dependency, a corrupt entry and a
        # stored value of the wrong shape are one answer — nil, "collect it again" — because none of them
        # can be told apart from the outside and all of them have the same remedy. An entry from before the
        # split simply does not exist under this producer id, so an older cache re-collects once.
        def peek_effect_summary(cache_store, descriptor)
          cached = cache_store.peek_validated(
            producer_id: RunCacheKey::RUN_EFFECTS_TABLE_PRODUCER_ID, key_descriptor: descriptor
          )
          return nil unless cached.is_a?(Array) && cached.length == 3
          return nil unless cached[0].is_a?(Effects::EffectTable) && cached[1].is_a?(Hash) &&
                            cached[2].is_a?(Hash)

          cached
        rescue StandardError
          nil
        end

        # The read half of the collections entry — only ever asked by {Runner#forced_file_effects}, on the paths
        # that need per-file form. The stored shape is `[collections]`; an entry from before the split is
        # `[collections, table]` and its first member is the same Hash, so it still reads.
        def peek_effect_collections(cache_store, descriptor)
          cached = cache_store.peek_validated(
            producer_id: RunCacheKey::RUN_EFFECTS_PRODUCER_ID, key_descriptor: descriptor
          )
          return nil unless cached.is_a?(Array) && cached.first.is_a?(Hash)

          cached.first
        rescue StandardError
          nil
        end

        def write_effect_entry(cache_store, producer_id, descriptor, payload, dependencies)
          cache_store.fetch_or_validate(
            producer_id: producer_id, key_descriptor: descriptor,
            generation_cap: RunCacheKey::EFFECTS_GENERATION_CAP
          ) { [payload, dependencies] }
        end

        # An empty table over non-empty summaries is {Runner#close_effect_graph}'s fail-soft answer, not a
        # result — persisting it would freeze one run's propagation failure into every warm hit until the
        # next invalidation. Storing nil instead makes the warm hit re-run the fixpoint, which is exactly
        # the retry the fail-soft posture wants.
        def storable_effect_table(effect_table, collections)
          table = effect_table
          return nil if table.nil?
          return nil if table.empty? && collections.any? { |_, collection| !collection.summaries.empty? }

          table
        end
      end
    end
  end
end
