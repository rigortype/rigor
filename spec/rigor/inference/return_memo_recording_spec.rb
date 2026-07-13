# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-57 return memo — recording-soundness property + WD0 profile counters.
#
# The deep ADR-46 dependency edge (the files a callee's body reads) is recorded only as a side effect of
# evaluating that body, and a memo hit serves the return without re-evaluating it. Recording soundness
# currently rests on the memo's per-file bucket scope (see the INVARIANT comment at
# `ExpressionTyper#infer_user_method_return`): a hit never crosses a consumer-file boundary, and within one
# consumer the first infer of a signature is a miss whose body eval records the deep edges — a later hit is
# edge-idempotent for that consumer. These examples pin the property through the WD0 counters: the memo stays
# ACTIVE under recording (a bypass-while-recording alternative measured >200x wall on analyzer-shaped files
# and was rejected — PR #79), yet the recorded sources stay complete. If the memo's caching scope ever widens
# past a consumer file without cache-and-replay of the callee's read-set, the deep-edge example here (or
# dependency_recorder_spec's cross-file variant) breaks.
RSpec.describe "ADR-57 return memo recording behaviour" do
  # A single file whose helper `base` is called from three sibling methods — the memo hits after the first
  # compute, under recording and not. `deep.rb` supplies the cross-file symbol `base` reads (the deep edge).
  def write_fixture(dir)
    File.write(File.join(dir, "deep.rb"), "class Deep\n  def leaf\n    1\n  end\nend\n")
    File.write(File.join(dir, "svc.rb"), <<~RUBY)
      class Svc
        def base
          Deep.new.leaf
        end
        def a; base; end
        def b; base; end
        def c; base; end
        def top; a + b + c; end
      end
      Svc.new.top
    RUBY
  end

  def run(dir, record:)
    configuration = Rigor::Configuration.new("paths" => [dir])
    runner = Rigor::Analysis::Runner.new(
      configuration: configuration, cache_store: nil, record_dependencies: record
    )
    runner.run
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

  it "hits the memo on a normal run (the within-file re-walk the memo exists to avoid)" do
    Dir.mktmpdir do |dir|
      write_fixture(dir)
      run(dir, record: false)

      snap = bt.snapshot
      # `base` is inferred once per calling site; after the first compute the rest hit the memo.
      expect(snap[bt::MEMO_HITS]).to be > 0
      expect(snap[bt::MEMO_ENTRIES]).to be > 0
      expect(snap[bt::MEMO_BODY_EVALS]).to be > 0
    end
  end

  it "keeps the memo active under recording — hits occur exactly as on a normal run" do
    Dir.mktmpdir do |dir|
      write_fixture(dir)
      run(dir, record: true)

      # No recording bypass: the memo serves within-consumer repeats. (Bypassing here re-walks deep
      # private-reader DAGs combinatorially — the rejected >200x alternative.)
      expect(bt.snapshot[bt::MEMO_HITS]).to be > 0
    end
  end

  it "records the deep cross-file read even though later same-consumer calls hit the memo" do
    Dir.mktmpdir do |dir|
      write_fixture(dir)
      runner = run(dir, record: true)

      # The within-file half of the invariant: the FIRST infer of `Svc#base` (a miss) evaluated the body and
      # recorded deep.rb for svc.rb; the later hits serve the SAME consumer, so no edge is lost. Asserting
      # hits > 0 in the same run proves the memo actually served — hit-and-still-complete.
      record = runner.file_dependencies[File.join(dir, "svc.rb")]
      expect(record.sources).to include(File.join(dir, "deep.rb"))
      expect(bt.snapshot[bt::MEMO_HITS]).to be > 0
    end
  end

  it "populates the per-signature body-eval distribution" do
    Dir.mktmpdir do |dir|
      write_fixture(dir)
      run(dir, record: false)

      evals = bt.distribution(bt::MEMO_BODY_EVAL_BY_SIGNATURE)
      # Signatures are `"Receiver#method"` labels; the fixture's methods appear as body-eval buckets.
      expect(evals.keys).to include("Svc#base")
      expect(evals["Svc#base"]).to be > 0
    end
  end
end
