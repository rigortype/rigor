# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-84 WD3 — the event-taint store gate. Candidacy is reduced to "plain signature not on the recursion
# guard stack"; whether a candidate's computed result may be STORED is decided post-hoc by bracketing the
# compute with the transient-machinery event counter (recursion-guard hit / unroll-fuel exhaustion /
# ADR-55 WD1 clamp / fixpoint-cap collapse, all routed through `ExpressionTyper#note_transient_fallback`).
# These examples pin the two behavioural halves (a clean nested compute under an in-flight unroll is now
# stored and later hit; a genuinely recursive compute is never stored) and the audit-table discipline (no
# recursion-machinery `BudgetTrace.hit` outside the counting helper, so a future fallback cannot silently
# join untainted).
RSpec.describe "ADR-84 return memo event-taint store gate" do
  def run_check(dir)
    configuration = Rigor::Configuration.new("paths" => [dir])
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    guarded_run(runner)
    runner
  end

  around do |example|
    Rigor::Inference::BudgetTrace.enable!
    Rigor::Inference::BudgetTrace.reset
    example.run
  ensure
    Rigor::Inference::BudgetTrace.disable!
    Rigor::Inference::BudgetTrace.reset
  end

  let(:bt) { Rigor::Inference::BudgetTrace }

  it "stores a clean non-recursive callee evaluated while a constant-arg unroll is in flight (the unlock)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "u.rb"), <<~RUBY)
        class U
          def leaf(n)
            n + 1
          end

          def walker(n)
            return leaf(1) if n.zero?

            walker(n - 1)
          end
        end
        U.new.walker(3)
        U.new.leaf(1)
      RUBY

      run_check(dir)

      # `leaf(1)` is first inferred at walker's unroll base case — pre-ADR-84 the blanket unroll-in-flight
      # exclusion refused it; now its bracket is event-free, so it stores, and the later top-level
      # `U.new.leaf(1)` hits instead of re-evaluating.
      expect(bt.distribution(bt::MEMO_BODY_EVAL_BY_SIGNATURE)["U#leaf"]).to eq(1)
      expect(bt.snapshot[bt::MEMO_HITS]).to be > 0
      # The blanket refusal is structurally gone.
      expect(bt.snapshot[bt::MEMO_REFUSE_UNROLL]).to eq(0)
    end
  end

  it "stores a recursive method's own converged fixpoint computed at top of stack (standalone by construction)" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "r.rb"), <<~RUBY)
        class R
          def dig(n)
            return 0 if n.zero?

            dig(n - 1)
          end

          def a(x) = dig(x)
          def b(x) = dig(x)
        end
      RUBY

      run_check(dir)

      # `dig`'s fixpoint fires guard events, but a top-of-stack compute reseeds fuel and starts with fresh
      # summary tables, so its converged result is a deterministic pure function of the key — it stores,
      # and BOTH sibling call sites hit instead of re-running the fixpoint (the refinement that keeps
      # recursion-heavy code from losing the memo wholesale). The eval count is the owner compute plus its
      # own in-cycle re-entries (each a compute entry) — crucially NOT multiplied by the two call sites.
      expect(bt.distribution(bt::MEMO_BODY_EVAL_BY_SIGNATURE)["R#dig"]).to be <= 3
      expect(bt.snapshot[bt::MEMO_HITS]).to be >= 2
    end
  end

  it "refuses to store a nested compute whose bracket saw a transient event (the shared-fuel hazard)" do
    Dir.mktmpdir do |dir|
      # `burn(30)`'s constant-arg unroll consumes 31 of the 32 shared fuel units before its base case
      # first infers `dig(0 + 6)` — that nested compute exhausts the remaining fuel mid-unroll and
      # degrades, a result the full-fuel standalone `dig(6)` below would NOT reproduce (it folds to
      # `Constant[0]`). The bracketed fuel-exhaustion event refuses the store, so the later top-level
      # `dig(6)` computes fresh instead of hitting the degraded value. (`dig(n + 6)` keeps the pinned
      # `[6]` key from arising anywhere outside the unroll: the main walk's `n` is unpinned there.)
      File.write(File.join(dir, "r.rb"), <<~RUBY)
        class R
          def dig(n)
            return 0 if n.zero?

            dig(n - 1)
          end

          def burn(n)
            return dig(n + 6) if n.zero?

            burn(n - 1)
          end
        end
        R.new.burn(30)
        R.new.dig(6)
      RUBY

      run_check(dir)

      expect(bt.snapshot[bt::MEMO_REFUSE_TRANSIENT]).to be > 0
      # The refused nested compute plus the fresh top-level compute — the tainted value was never served.
      expect(bt.distribution(bt::MEMO_BODY_EVAL_BY_SIGNATURE)["R#dig"]).to be >= 2
    end
  end

  # The depth log the store gate brackets with MUST be maintained on a plain (untraced) run — reusing
  # BudgetTrace's env-gated path would silently disable the gate on every normal run — and the taint
  # verdict is "an event referenced a frame below the bracket's entry depth".
  it "logs transient events with RIGOR_BUDGET_TRACE disabled and taints only below-entry references" do
    Rigor::Inference::BudgetTrace.disable!
    typer = Rigor::Inference::ExpressionTyper.new(scope: nil)
    key = :__rigor_user_method_transient_event_depths__
    Thread.current[key] = nil

    typer.send(:note_transient_fallback, Rigor::Inference::BudgetTrace::RECURSION_GUARD, 2)
    expect(Thread.current[key]).to eq([2]) # logged despite tracing being disabled

    aggregate_failures do
      # Event at position 2: taints a bracket entered at depth 3 (ancestor state), not one at depth 2 or 1
      # (own / subtree machinery), and marks bracket-relatively (an event before the mark is invisible).
      expect(typer.send(:context_tainted?, 0, 3)).to be(true)
      expect(typer.send(:context_tainted?, 0, 2)).to be(false)
      expect(typer.send(:context_tainted?, 1, 3)).to be(false)
      # Top-of-stack bracket (entry depth 0) can never be tainted — standalone by construction.
      typer.send(:note_transient_fallback, Rigor::Inference::BudgetTrace::RECURSION_UNROLL_FUEL, 0)
      expect(typer.send(:context_tainted?, 0, 0)).to be(false)
    end
  ensure
    Thread.current[key] = nil
  end

  # The audit-table pin (see TRANSIENT_EVENT_DEPTHS_KEY in expression_typer.rb): every recursion-machinery
  # fallback must route through `note_transient_fallback`, never a raw `BudgetTrace.hit`, so adding a
  # fallback without tainting the bracket fails here rather than silently poisoning the memo.
  describe "audit-table discipline" do
    let(:source) do
      File.read(File.expand_path("../../../lib/rigor/inference/expression_typer.rb", __dir__))
    end

    it "has no raw BudgetTrace.hit on the recursion-machinery categories" do
      raw_hits = source.scan(/BudgetTrace\.hit\(BudgetTrace::RECURSION_\w+\)/)
      expect(raw_hits).to be_empty,
                          "recursion-machinery fallbacks must route through note_transient_fallback: #{raw_hits}"
    end

    it "routes exactly the audited fallback sites through note_transient_fallback" do
      categories = source.scan(/note_transient_fallback\(BudgetTrace::(\w+),/).flatten.sort
      # The five audited sites: in-cycle guard hit, entangled-fixpoint degrade, ADR-55 WD1 clamp (all
      # RECURSION_GUARD), fixpoint-cap collapse, and unroll-fuel exhaustion. A new site extends this list
      # deliberately, alongside its audit-table row and referenced-frame position.
      expect(categories).to eq(
        %w[RECURSION_FIXPOINT_CAP RECURSION_GUARD RECURSION_GUARD RECURSION_GUARD RECURSION_UNROLL_FUEL]
      )
    end
  end
end
