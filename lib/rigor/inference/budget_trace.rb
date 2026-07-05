# frozen_string_literal: true

module Rigor
  module Inference
    # Opt-in counters for the hard-coded inference cutoffs — the "budget" guards that silently return
    # `Dynamic[top]` / `nil` / a fallback bound rather than emitting a diagnostic. These are the *operative*
    # cutoffs in the engine today (the configurable `budgets:` table in
    # docs/type-specification/inference-budgets.md is not yet wired); counting how often each fires on a real
    # project is the only way to see where inference actually stops.
    #
    # Three categories, one per guard site:
    #
    # - {RECURSION_GUARD} — `ExpressionTyper#infer_user_method_return` detected a `(receiver, method)` cycle
    #   and returned `Dynamic[top]` (the de-facto recursion-depth budget, effective depth 1).
    # - {ANCESTOR_WALK_LIMIT} — `resolve_user_def_through_ancestors` hit the 100-node BFS cap and gave up
    #   resolving the self-call.
    # - {HKT_FUEL_EXHAUSTED} — `HktReducer` ran out of its reduction fuel budget and unwound to `app.bound`.
    # - {RECURSION_UNROLL_FUEL} — the constant-arg recursion unroll (ADR-55 slice 1) exhausted its per-entry
    #   fuel and fell back to the plain `(receiver, method)` guard (in-cycle call → `Dynamic[top]`).
    # - {RECURSION_FIXPOINT_CAP} — the fixpoint return-summary iteration (ADR-55 slice 2) hit its 3-evaluation
    #   cap without converging and collapsed the summary to `untyped` (today's behaviour).
    #
    # Enabled only when `RIGOR_BUDGET_TRACE` is set (to any non-empty value) in the environment, or via
    # {enable!} in tests. When disabled, {hit} is a single boolean check and returns immediately, so normal
    # runs pay nothing.
    #
    # Counters are process-global (Mutex-guarded) so they aggregate across threads, but they do NOT cross
    # `fork` boundaries — run `rigor check --workers 0` to keep all inference in one process when collecting a
    # trace.
    module BudgetTrace
      RECURSION_GUARD = :recursion_guard
      ANCESTOR_WALK_LIMIT = :ancestor_walk_limit
      HKT_FUEL_EXHAUSTED = :hkt_fuel_exhausted
      # `ExpressionTyper#infer_user_method_return` exhausted its constant-arg unroll fuel (ADR-55 slice 1) and
      # fell back to the plain `(receiver, method)` recursion guard — i.e. the in-cycle call widened to
      # `Dynamic[top]` exactly as it does without the unroll.
      RECURSION_UNROLL_FUEL = :recursion_unroll_fuel
      # `ExpressionTyper#infer_user_method_return` ran the fixpoint return-summary iteration (ADR-55 slice 2)
      # to its 3-evaluation cap without reaching convergence and collapsed the summary to `untyped` — the
      # in-cycle result widens to `Dynamic[top]` exactly as it does without the fixpoint.
      RECURSION_FIXPOINT_CAP = :recursion_fixpoint_cap
      # `BodyFixpoint#converge` (ADR-56 slice A — non-escaping block captured-local write-back) ran its
      # 3-evaluation cap without the written local's join converging and collapsed that local to
      # `Dynamic[top]` (the escaping-block floor). Shared by slice B's loop-body fixpoint.
      BLOCK_WRITEBACK_CAP = :block_writeback_cap

      CATEGORIES = [
        RECURSION_GUARD, ANCESTOR_WALK_LIMIT, HKT_FUEL_EXHAUSTED, RECURSION_UNROLL_FUEL,
        RECURSION_FIXPOINT_CAP, BLOCK_WRITEBACK_CAP
      ].freeze

      # Distribution (histogram) categories — read-only observations of a value's size at a site, used to
      # choose budget defaults from an observed tail rather than a guess (ADR-41 WD3 / Slice 2a). No cap is
      # enforced; these only record. `UNION_ARITY` is the member count of every `Type::Union` that
      # `Combinator.union` produces — the distribution the `union_size` budget default should be set from.
      UNION_ARITY = :union_arity

      DISTRIBUTION_CATEGORIES = [UNION_ARITY].freeze

      @enabled = !ENV["RIGOR_BUDGET_TRACE"].to_s.empty?
      @mutex = Mutex.new
      @counts = Hash.new(0)
      @distributions = Hash.new { |h, k| h[k] = Hash.new(0) }

      module_function

      def enabled?
        @enabled
      end

      # Test / programmatic toggles. Production enablement is the `RIGOR_BUDGET_TRACE` env var read once at
      # load time.
      def enable!
        @enabled = true
      end

      def disable!
        @enabled = false
      end

      # Records one firing of `category`. No-op (one boolean check) when tracing is disabled.
      def hit(category)
        return unless @enabled

        @mutex.synchronize { @counts[category] += 1 }
      end

      # Frozen snapshot of the current counts, every known category present (zero-filled) so consumers can
      # render a stable table.
      def snapshot
        @mutex.synchronize do
          CATEGORIES.to_h { |category| [category, @counts[category]] }.freeze
        end
      end

      # Records one observation of `value` (an Integer size) into `category`'s histogram. No-op (one boolean
      # check) when disabled.
      def observe(category, value)
        return unless @enabled

        @mutex.synchronize { @distributions[category][value] += 1 }
      end

      # Frozen `{value => count}` histogram for a distribution category.
      def distribution(category)
        @mutex.synchronize { @distributions[category].dup.freeze }
      end

      # Summary of a distribution category: total observation count, max observed value, selected percentiles,
      # and how many observations met or exceeded each threshold in `over`. Percentiles use the nearest-rank
      # method over the expanded sample.
      def summarize(category, over: [])
        hist = distribution(category)
        total = hist.values.sum
        return { count: 0, max: 0, percentiles: {}, over: over.to_h { |t| [t, 0] } } if total.zero?

        sorted = hist.keys.sort
        { count: total,
          max: sorted.last,
          percentiles: { p50: percentile(hist, total, 0.50), p90: percentile(hist, total, 0.90),
                         p99: percentile(hist, total, 0.99) },
          over: over.to_h { |t| [t, hist.sum { |value, n| value >= t ? n : 0 }] } }
      end

      # Nearest-rank percentile over a `{value => count}` histogram without materialising the full sample.
      def percentile(hist, total, fraction)
        rank = (fraction * total).ceil
        cumulative = 0
        hist.keys.sort.each do |value|
          cumulative += hist[value]
          return value if cumulative >= rank
        end
        hist.keys.max
      end

      def reset
        @mutex.synchronize do
          @counts.clear
          @distributions.clear
        end
      end
    end
  end
end
