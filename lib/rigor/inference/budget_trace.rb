# frozen_string_literal: true

module Rigor
  module Inference
    # Opt-in counters for the hard-coded inference cutoffs — the
    # "budget" guards that silently return `Dynamic[top]` / `nil` /
    # a fallback bound rather than emitting a diagnostic. These are
    # the *operative* cutoffs in the engine today (the configurable
    # `budgets:` table in docs/type-specification/inference-budgets.md
    # is not yet wired); counting how often each fires on a real
    # project is the only way to see where inference actually stops.
    #
    # Three categories, one per guard site:
    #
    # - {RECURSION_GUARD} — `ExpressionTyper#infer_user_method_return`
    #   detected a `(receiver, method)` cycle and returned
    #   `Dynamic[top]` (the de-facto recursion-depth budget, effective
    #   depth 1).
    # - {ANCESTOR_WALK_LIMIT} — `resolve_user_def_through_ancestors`
    #   hit the 100-node BFS cap and gave up resolving the self-call.
    # - {HKT_FUEL_EXHAUSTED} — `HktReducer` ran out of its reduction
    #   fuel budget and unwound to `app.bound`.
    #
    # Enabled only when `RIGOR_BUDGET_TRACE` is set (to any non-empty
    # value) in the environment, or via {enable!} in tests. When
    # disabled, {hit} is a single boolean check and returns
    # immediately, so normal runs pay nothing.
    #
    # Counters are process-global (Mutex-guarded) so they aggregate
    # across threads, but they do NOT cross `fork` boundaries — run
    # `rigor check --workers 0` to keep all inference in one process
    # when collecting a trace.
    module BudgetTrace
      RECURSION_GUARD = :recursion_guard
      ANCESTOR_WALK_LIMIT = :ancestor_walk_limit
      HKT_FUEL_EXHAUSTED = :hkt_fuel_exhausted

      CATEGORIES = [RECURSION_GUARD, ANCESTOR_WALK_LIMIT, HKT_FUEL_EXHAUSTED].freeze

      @enabled = !ENV["RIGOR_BUDGET_TRACE"].to_s.empty?
      @mutex = Mutex.new
      @counts = Hash.new(0)

      module_function

      def enabled?
        @enabled
      end

      # Test / programmatic toggles. Production enablement is the
      # `RIGOR_BUDGET_TRACE` env var read once at load time.
      def enable!
        @enabled = true
      end

      def disable!
        @enabled = false
      end

      # Records one firing of `category`. No-op (one boolean check)
      # when tracing is disabled.
      def hit(category)
        return unless @enabled

        @mutex.synchronize { @counts[category] += 1 }
      end

      # Frozen snapshot of the current counts, every known category
      # present (zero-filled) so consumers can render a stable table.
      def snapshot
        @mutex.synchronize do
          CATEGORIES.to_h { |category| [category, @counts[category]] }.freeze
        end
      end

      def reset
        @mutex.synchronize { @counts.clear }
      end
    end
  end
end
