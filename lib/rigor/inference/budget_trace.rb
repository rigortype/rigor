# frozen_string_literal: true

module Rigor
  module Inference
    # Opt-in counters for the hard-coded inference cutoffs — the "budget" guards that silently return
    # `Dynamic[top]` / `nil` / a fallback bound rather than emitting a diagnostic. These are the *operative*
    # cutoffs in the engine today (the configurable `budgets:` table in
    # docs/type-specification/inference-budgets.md is not yet wired); counting how often each fires on a real
    # project is the only way to see where inference actually stops.
    #
    # A second family of counters (the `MEMO_*` categories) profiles the ADR-57 user-method return memo
    # (`ExpressionTyper#infer_user_method_return`) rather than a cutoff — inference entries, memo hits/misses,
    # the split of non-stored results by reason, and body-evaluation (compute) entries — plus two
    # per-signature distributions (body-eval count and distinct-memo-key count). This is the evidence for the
    # next return-memo design slice: a finalization-aware taint gate (recover the `consult-tainted`
    # non-stores) vs memo-key normalization (collapse arg-granularity thrash — a signature whose distinct-key
    # count far exceeds its body-eval savings).
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

      # ADR-57 return-memo profile counters (not cutoffs — see the module doc). All bumped by
      # `ExpressionTyper#infer_user_method_return` / `#compute_user_method_return`.
      # - {MEMO_ENTRIES} — every `infer_user_method_return` entry (a user-method return inference).
      # - {MEMO_HITS} / {MEMO_MISSES} — the memo was consulted (candidate frame, no recording) and the key was
      #   present / absent. Consults = hits + misses.
      # - {MEMO_BODY_EVALS} — every `compute_user_method_return` entry (a body-evaluation compute; some are
      #   in-cycle re-entries that consult an ADR-55 summary rather than walk the body — those coincide with a
      #   `RECURSION_GUARD` hit). Body evals = misses + on-stack refusals + unroll refusals.
      # - {MEMO_REFUSE_ON_STACK} / {MEMO_REFUSE_UNROLL} — the frame was not a memo candidate (bypassed the memo
      #   and computed): its plain `(receiver, method)` signature was already on the recursion guard stack, or
      #   a constant-arg unroll was in flight.
      # - {MEMO_REFUSE_CONSULT_TAINTED} — a candidate frame computed a result but an ADR-55 fixpoint summary
      #   was *consulted* during the compute, so the result is a transient Kleene iterate and was NOT stored.
      MEMO_ENTRIES = :memo_entries
      MEMO_HITS = :memo_hits
      MEMO_MISSES = :memo_misses
      MEMO_BODY_EVALS = :memo_body_evals
      MEMO_REFUSE_ON_STACK = :memo_refuse_on_stack
      MEMO_REFUSE_UNROLL = :memo_refuse_unroll
      MEMO_REFUSE_CONSULT_TAINTED = :memo_refuse_consult_tainted

      CATEGORIES = [
        RECURSION_GUARD, ANCESTOR_WALK_LIMIT, HKT_FUEL_EXHAUSTED, RECURSION_UNROLL_FUEL,
        RECURSION_FIXPOINT_CAP, BLOCK_WRITEBACK_CAP,
        MEMO_ENTRIES, MEMO_HITS, MEMO_MISSES, MEMO_BODY_EVALS,
        MEMO_REFUSE_ON_STACK, MEMO_REFUSE_UNROLL, MEMO_REFUSE_CONSULT_TAINTED
      ].freeze

      # Distribution (histogram) categories — read-only observations of a value's size at a site, used to
      # choose budget defaults from an observed tail rather than a guess (ADR-41 WD3 / Slice 2a). No cap is
      # enforced; these only record. `UNION_ARITY` is the member count of every `Type::Union` that
      # `Combinator.union` produces — the distribution the `union_size` budget default should be set from.
      UNION_ARITY = :union_arity

      # ADR-57 return-memo per-signature distributions — `{signature => count}` maps, NOT integer-size
      # histograms, so `summarize` (percentiles over integer values) does not apply; read them with
      # {distribution}. Both keyed by the `"Receiver#method"` plain signature.
      # - {MEMO_BODY_EVAL_BY_SIGNATURE} — body-eval (compute) count per signature (via {observe}).
      # - {MEMO_DISTINCT_KEY_BY_SIGNATURE} — distinct memo keys per signature (via {observe_distinct}), i.e.
      #   how many `(receiver, arg-type)` variants a signature was memoised under. A count far above the
      #   signature's body-eval savings is arg-granularity thrash — the key-normalization candidate.
      MEMO_BODY_EVAL_BY_SIGNATURE = :memo_body_eval_by_signature
      MEMO_DISTINCT_KEY_BY_SIGNATURE = :memo_distinct_key_by_signature

      DISTRIBUTION_CATEGORIES = [
        UNION_ARITY, MEMO_BODY_EVAL_BY_SIGNATURE, MEMO_DISTINCT_KEY_BY_SIGNATURE
      ].freeze

      @enabled = !ENV["RIGOR_BUDGET_TRACE"].to_s.empty?
      @mutex = Mutex.new
      @counts = Hash.new(0)
      @distributions = Hash.new { |h, k| h[k] = Hash.new(0) }
      # Auxiliary de-duplication state for {observe_distinct}: category → Set of the `[bucket, member]`
      # pairs already counted, so a repeated `(signature, memo-key)` observation is counted once. Only ever
      # written when tracing is enabled; not part of the reported surface.
      @distinct_seen = Hash.new { |h, k| h[k] = Set.new }

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

      # Records one observation of `member` into `category`'s `{bucket => count}` map, but only the FIRST time
      # a given `(bucket, member)` pair is seen — so the resulting count per bucket is the number of DISTINCT
      # members, not the number of observations. Used for the distinct-memo-key-per-signature distribution.
      # No-op (one boolean check) when disabled.
      def observe_distinct(category, bucket, member)
        return unless @enabled

        @mutex.synchronize do
          seen = @distinct_seen[category]
          pair = [bucket, member]
          unless seen.include?(pair)
            seen << pair
            @distributions[category][bucket] += 1
          end
        end
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
          @distinct_seen.clear
        end
      end
    end
  end
end
