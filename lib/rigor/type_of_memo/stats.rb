# frozen_string_literal: true

module Rigor
  module TypeOfMemo
    # The counters and mismatch samples of this process, behind a mutex: process counters like {MemoAudit}'s, never
    # read back into a type (ADR-129 WD5).
    class Stats
      def initialize
        @mutex = Mutex.new
        @counts = Hash.new { |hash, phase| hash[phase] = Hash.new(0) }
        @stale = Hash.new { |hash, phase| hash[phase] = Hash.new(0) }
        @samples = []
      end

      def count(phase, counter) = @mutex.synchronize { @counts[phase][counter] += 1 }

      def stale_miss(phase, names) = @mutex.synchronize { @stale[phase][names] += 1 }

      def sample(limit)
        @mutex.synchronize { @samples << yield if @samples.size < limit }
      end

      def counts = @mutex.synchronize { copy(@counts) }

      def stale = @mutex.synchronize { copy(@stale) }

      def samples = @mutex.synchronize { @samples.dup }

      def reset
        @mutex.synchronize do
          @counts.clear
          @stale.clear
          @samples.clear
        end
        nil
      end

      private

      def copy(by_phase) = by_phase.to_h { |phase, counters| [phase, counters.dup] }
    end
  end
end
