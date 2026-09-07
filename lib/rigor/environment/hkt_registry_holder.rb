# frozen_string_literal: true

module Rigor
  class Environment
    # ADR-20 slice 2e — mutable single-slot memoization container for the per-Environment HKT registry. Held
    # by {Environment} so the otherwise-frozen instance can still cache a computed value on first access.
    #
    # Concurrent {#fetch} calls from multiple threads against one Environment are NOT serialised here — the
    # LSP single-publish-at-a-time discipline and the Ractor pool's per-worker Environment shape already
    # prevent cross-thread races. If a future caller introduces a multi-threaded reader path against a
    # shared Environment, the synchronisation belongs at that caller's seam, not here.
    class HktRegistryHolder
      def initialize
        @loaded = false
        @value = nil
        @error = nil
      end

      # Memoizes the failure as well as the value. The build this guards is expensive and shared across
      # every file in the run; without this a `yield` that raises is retried — and re-raised — once per
      # file (issue #776 crashed hundreds of times before its fix). A `StandardError` from the build is
      # a property of this Environment's inputs, so re-running cannot succeed; re-raise the original.
      # Non-`StandardError` (Interrupt, SignalException) propagates without poisoning the slot.
      def fetch
        raise @error if @error
        return @value if @loaded

        begin
          @value = yield
        rescue StandardError => e
          @error = e
          raise
        end
        @loaded = true
        @value
      end
    end
  end
end
