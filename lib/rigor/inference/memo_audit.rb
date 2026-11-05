# frozen_string_literal: true

require_relative "../typing_state"

module Rigor
  module Inference
    # ADR-127 WD3 — the callee floor's memo audit. A memo hit is correct only when the key holds every input the value
    # was computed from, and a key that misses one answers a caller with another caller's value (#2516, #2524). With the
    # audit on, every hit in the callee floor's memos (`resolved_census`, the unrecorded hand-off memo, the successor
    # store and `def_census`) recomputes the value and raises {Mismatch} when it differs from the stored one, so a key
    # defect fails on the first hit instead of waiting for an order that exposes it.
    #
    # Like {BudgetTrace}, a switch for specs and CI (`RIGOR_MEMO_AUDIT=1` in the environment, read once at load, or
    # {enable!}): off by default, a single boolean check when off. A recomputation
    # runs with the audit suspended on its thread and the memos bypassed ({suspended?}), so it reads nothing stored.
    #
    # A mismatch raises, and is also kept on this thread's list until {drain} takes it (ADR-129 WD5, #2785): the
    # typing path rescues `StandardError` in many places, and a raise one of them swallows would turn the defect into
    # an ordinary fallback answer. The runner drains the list after each file and reports what it holds the way it
    # reports a mismatch no rescue caught, and {raise_undrained!} fails the run on what a file never drained.
    module MemoAudit
      # A memo hit whose stored value differs from a fresh computation.
      class Mismatch < StandardError; end

      # ADR-129 WD1 — a Frame, installed around a recomputation. `@enabled` is a process switch, outside the typing
      # state (WD5).
      SUSPENDED = TypingState.frame(
        :memo_audit_suspended, reason: "set around an audit recomputation, which bypasses every memo"
      )
      private_constant :SUSPENDED

      # ADR-129 WD1 — a Resource: the mismatches raised on this thread and not drained yet. Typing never reads it; an
      # append refuses every open capture, which only an audited run reaches.
      MISMATCHES = TypingState.resource(
        :memo_audit_mismatches,
        run_scoped: true,
        reason: "the audit's mismatches on this thread, appended where raised, drained per file, never read by typing"
      )
      private_constant :MISMATCHES

      EMPTY = [].freeze
      private_constant :EMPTY

      @enabled = %w[1 true].include?(ENV["RIGOR_MEMO_AUDIT"].to_s.downcase)

      module_function

      def enabled? = @enabled

      # True while an audit recomputation runs on this thread. The callee floor's memos are then bypassed (read and
      # write), so the recomputation reads no stored entry of another memo: a defect shared across a table (a stale
      # `resolved_census(:edges)` entry) would otherwise make the recomputed value match the stored one.
      def suspended? = TypingState.current[SUSPENDED]

      def enable! = (@enabled = true)

      def disable! = (@enabled = false)

      # `stored`, after checking it against `yield` when the audit is on. `label` and the key parts (`key`, `key2`) name
      # the memo entry in the failure; they are passed apart so an audit that is off allocates nothing.
      def check(label, stored, key, key2 = nil, &)
        return stored unless @enabled && !TypingState.current[SUSPENDED]

        fresh = suspended(&)
        return stored if fresh == stored

        mismatch = Mismatch.new(
          "#{label} memo hit differs from a fresh computation for #{[key, key2].inspect[0, 120]}: " \
          "stored #{stored.inspect[0, 200]}, fresh #{fresh.inspect[0, 200]}"
        )
        state = TypingState.current
        state.append(MISMATCHES, mismatch)
        raise mismatch
      end

      # The mismatches raised on this thread since the last drain, oldest first, and an empty list for the next file.
      # Each has been raised, so it carries the backtrace a crash row is built from.
      def drain
        state = TypingState.current
        mismatches = state.read(MISMATCHES)
        return EMPTY if mismatches.nil? || mismatches.empty?

        state.write(MISMATCHES, nil)
        mismatches
      end

      # Raises the first mismatch no file drained (one raised outside every file's analysis), so a run that ends with
      # one fails instead of releasing it with the run's other slots.
      def raise_undrained!
        return unless @enabled

        mismatches = drain
        raise mismatches.first unless mismatches.empty?
      end

      def suspended(&)
        TypingState.current.with(SUSPENDED, true, &)
      end
    end
  end
end
