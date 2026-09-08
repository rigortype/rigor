# frozen_string_literal: true

module Rigor
  class Environment
    # Issue #784 — a mutable, first-write-wins record of one shared-build failure, held by the otherwise
    # frozen {Environment} the way {HktRegistryHolder} holds a memoised value. A lazy build that raises
    # during per-file analysis records here at its seam instead of raising into every file's
    # `analyze_body` rescue; the coordinator snapshots the slot after the file loop (the build is lazy, so
    # a snapshot taken before the loop reads nothing) and the aggregator surfaces it once for the run.
    #
    # First-write-wins: the build is memoised, so a second failure can only be the same one re-observed.
    #
    # Concurrency: single-threaded use only, the same discipline as {HktRegistryHolder}.
    class FailureSlot
      def initialize
        @value = nil
      end

      # @param value a Marshal-clean tuple — the fork pool ships it back from the worker.
      def record(value)
        @value = value.freeze if @value.nil?
      end

      # @return the recorded tuple, or nil when the build never failed.
      attr_reader :value
    end
  end
end
