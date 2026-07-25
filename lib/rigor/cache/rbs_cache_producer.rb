# frozen_string_literal: true

require_relative "rbs_descriptor"

module Rigor
  module Cache
    # Base for the RBS-derived cache producers.
    #
    # Every producer (`RbsKnownClassNames`, `RbsConstantTable`, `RbsEnvironment`, the ancestor / type-param /
    # definition tables, …) repeated the identical `fetch` wiring: build the RBS descriptor, then
    # `store.fetch_or_compute` under the producer's id, yielding to the producer's `compute`. Only the
    # `PRODUCER_ID` constant and the `compute(loader)` body actually differ between producers.
    #
    # Subclasses declare `PRODUCER_ID` and a (private) `self.compute`; this base owns `fetch`.
    # `self::PRODUCER_ID` resolves the constant on the concrete subclass, and `compute(loader)` dispatches to
    # its private class method. See the `_CacheProducer` RBS interface for the structural contract.
    class RbsCacheProducer
      # Every RBS producer is whole-project and content-keyed: one entry is live and any older generation is
      # unreachable, so `Cache::Store#evict!` keeps a small number of them (one spare for the still-warm
      # previous signature state — the RBS environment blob alone runs to ~1.8 MB, ADR-54 WD3). Declared on
      # the base, so a producer added by subclassing inherits a cap instead of being silently uncapped; a
      # subclass with different economics overrides this method.
      def self.generation_cap
        2
      end

      def self.fetch(loader:, store:)
        # ADR-54 WD4 — the descriptor is identical for every producer consulting the same loader (same sig
        # files, same libraries), so the loader memoises one build per process instead of re-digesting every
        # .rbs file once per producer.
        descriptor = loader.rbs_cache_descriptor
        store.fetch_or_compute(producer_id: self::PRODUCER_ID, params: {}, descriptor: descriptor,
                               generation_cap: generation_cap) do
          compute(loader)
        end
      end
    end
  end
end
