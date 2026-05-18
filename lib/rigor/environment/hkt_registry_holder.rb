# frozen_string_literal: true

module Rigor
  class Environment
    # ADR-20 slice 2e — mutable single-slot memoization
    # container for the per-Environment HKT registry. Held by
    # {Environment} so the otherwise-frozen instance can
    # still cache a computed value on first access.
    #
    # Concurrent {#fetch} calls from multiple threads against
    # one Environment are NOT serialised here — the LSP
    # single-publish-at-a-time discipline and the Ractor
    # pool's per-worker Environment shape already prevent
    # cross-thread races. If a future caller introduces a
    # multi-threaded reader path against a shared
    # Environment, the synchronisation belongs at that
    # caller's seam, not here.
    class HktRegistryHolder
      def initialize
        @loaded = false
        @value = nil
      end

      def fetch
        return @value if @loaded

        @value = yield
        @loaded = true
        @value
      end
    end
  end
end
