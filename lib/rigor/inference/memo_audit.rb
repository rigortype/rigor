# frozen_string_literal: true

module Rigor
  module Inference
    # ADR-127 WD3 — the callee floor's memo audit. A memo hit is correct only when the key holds every input the value
    # was computed from, and a key that misses one answers a caller with another caller's value (#2516, #2524). With the
    # audit on, every hit in the callee floor's memos (`resolved_census`, the unrecorded hand-off memo, the successor
    # store and `def_census`) recomputes the value and raises {Mismatch} when it differs from the stored one, so a key
    # defect fails on the first hit instead of waiting for an order that exposes it.
    #
    # Like {BudgetTrace}, a switch for specs and CI: off by default, a single boolean check when off. A recomputation
    # runs with the audit suspended on its thread, so the memos it reads are answered as stored and the cost stays
    # linear in the hits.
    module MemoAudit
      # A memo hit whose stored value differs from a fresh computation.
      class Mismatch < StandardError; end

      SUSPENDED_KEY = :rigor_memo_audit_suspended

      @enabled = false

      module_function

      def enabled? = @enabled

      def enable! = (@enabled = true)

      def disable! = (@enabled = false)

      # `stored`, after checking it against `yield` when the audit is on. `label` and the key parts (`key`, `key2`) name
      # the memo entry in the failure; they are passed apart so an audit that is off allocates nothing.
      def check(label, stored, key, key2 = nil, &)
        return stored unless @enabled && !Thread.current[SUSPENDED_KEY]

        fresh = suspended(&)
        return stored if fresh == stored

        raise Mismatch, "#{label} memo hit differs from a fresh computation for #{[key, key2].inspect[0, 120]}: " \
                        "stored #{stored.inspect[0, 200]}, fresh #{fresh.inspect[0, 200]}"
      end

      def suspended
        Thread.current[SUSPENDED_KEY] = true
        yield
      ensure
        Thread.current[SUSPENDED_KEY] = nil
      end
    end
  end
end
