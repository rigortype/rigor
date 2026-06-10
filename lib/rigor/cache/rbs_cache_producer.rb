# frozen_string_literal: true

require_relative "rbs_descriptor"

module Rigor
  module Cache
    # Base for the RBS-derived cache producers.
    #
    # Every producer (`RbsKnownClassNames`, `RbsConstantTable`,
    # `RbsEnvironment`, the ancestor / type-param / definition tables, …)
    # repeated the identical `fetch` wiring: build the RBS descriptor,
    # then `store.fetch_or_compute` under the producer's id, yielding to
    # the producer's `compute`. Only the `PRODUCER_ID` constant and the
    # `compute(loader)` body actually differ between producers.
    #
    # Subclasses declare `PRODUCER_ID` and a (private) `self.compute`;
    # this base owns `fetch`. `self::PRODUCER_ID` resolves the constant on
    # the concrete subclass, and `compute(loader)` dispatches to its
    # private class method. See the `_CacheProducer` RBS interface for the
    # structural contract.
    class RbsCacheProducer
      def self.fetch(loader:, store:)
        # ADR-54 WD4 — the descriptor is identical for every producer
        # consulting the same loader (same sig files, same libraries),
        # so the loader memoises one build per process instead of
        # re-digesting every .rbs file once per producer.
        descriptor = loader.rbs_cache_descriptor
        store.fetch_or_compute(producer_id: self::PRODUCER_ID, params: {}, descriptor: descriptor) do
          compute(loader)
        end
      end
    end
  end
end
