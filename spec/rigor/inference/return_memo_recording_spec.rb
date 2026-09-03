# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# ADR-57 / ADR-84 return memo — recording-soundness property + WD0 profile counters.
#
# The deep ADR-46 dependency edge (the files a callee's body reads) is recorded only as a side effect of
# evaluating that body, and a memo hit serves the return without re-evaluating it. Since ADR-84 WD2 the
# bucket is RUN-scoped, so hits cross consumer-file boundaries and recording soundness rests on
# CACHE-AND-REPLAY (see the INVARIANT comment at `ExpressionTyper#infer_user_method_return`): the first
# evaluation of a key captures its body walk's recorder events onto the entry
# (`DependencyRecorder.capture`), and a hit replays them into the current consumer's accumulator
# (`DependencyRecorder.replay`) — a hit is edge-equivalent to a fresh evaluation for EVERY consumer. These
# examples pin the property through the WD0 counters: the memo stays ACTIVE under recording (a
# bypass-while-recording alternative measured >200x wall on analyzer-shaped files and was rejected — PR
# #79), the recorded sources stay complete THROUGH the replay path (the cross-file example evaluates the
# callee exactly once run-wide — the scenario #79 proved impossible under the per-file bucket), and the
# bucket rolls over between runs so a recording run can never hit a read-set-less entry stored by an
# earlier non-recording run in the same process.
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
      # recorded deep.rb for svc.rb; the later hits replay the SAME edges for the same consumer, so no edge
      # is lost. Asserting hits > 0 in the same run proves the memo actually served — hit-and-still-complete.
      record = runner.file_dependencies[File.join(dir, "svc.rb")]
      expect(record.sources).to include(File.join(dir, "deep.rb"))
      expect(bt.snapshot[bt::MEMO_HITS]).to be > 0
    end
  end

  # ADR-84 WD2 — the cross-file half: consumer B memo-hits a callee first evaluated under consumer A, and
  # B's record still carries the file the callee's BODY reads (the deep edge), at symbol granularity —
  # supplied by replaying the entry's captured read-set, since B never walks the body. The per-signature
  # body-eval distribution proves the hit was genuinely cross-file: `Mid#relay` is evaluated exactly once
  # across the whole run while two consumer files depend on it (impossible under the per-file bucket #79
  # pinned, where each consumer re-evaluated it).
  def write_cross_file_fixture(dir)
    File.write(File.join(dir, "deep.rb"), "class Deep\n  def leaf\n    1\n  end\nend\n")
    File.write(File.join(dir, "mid.rb"), <<~RUBY)
      class Mid
        def relay
          Deep.new.leaf
        end
      end
    RUBY
    File.write(File.join(dir, "a_consumer.rb"), "Mid.new.relay\n")
    File.write(File.join(dir, "b_consumer.rb"), "Mid.new.relay\n")
  end

  it "replays the callee's read-set to a second consumer whose infer memo-hits cross-file" do
    Dir.mktmpdir do |dir|
      write_cross_file_fixture(dir)
      runner = run(dir, record: true)

      deep = File.join(dir, "deep.rb")
      %w[a_consumer.rb b_consumer.rb].each do |consumer|
        record = runner.file_dependencies[File.join(dir, consumer)]
        expect(record.sources).to include(deep), "#{consumer} should depend on deep.rb through the replay"
        expect(record.symbol_sources[deep]).to include("Deep#leaf")
      end
      # One body eval run-wide for the shared callee = the second consumer was served by a cross-file hit.
      expect(bt.distribution(bt::MEMO_BODY_EVAL_BY_SIGNATURE)["Mid#relay"]).to eq(1)
    end
  end

  # ADR-84 WD2 — bucket rollover between runs in one process. Entries stored by a non-recording run carry
  # no read-set; a later recording run must never hit them (it could not replay their edges). The
  # run-generation token makes each `Runner#run` a fresh bucket: the recording run below records complete
  # edges and evaluates the callee itself (a miss), stale entries notwithstanding.
  it "rolls the bucket between runs so a recording run never hits a non-recording run's entries" do
    Dir.mktmpdir do |dir|
      write_cross_file_fixture(dir)
      run(dir, record: false)

      bt.reset
      runner = run(dir, record: true)

      deep = File.join(dir, "deep.rb")
      record = runner.file_dependencies[File.join(dir, "b_consumer.rb")]
      expect(record.sources).to include(deep)
      # The recording run computed the callee afresh (misses > 0 and one body eval for the shared callee)
      # instead of hitting the earlier run's read-set-less entries.
      expect(bt.snapshot[bt::MEMO_MISSES]).to be > 0
      expect(bt.distribution(bt::MEMO_BODY_EVAL_BY_SIGNATURE)["Mid#relay"]).to eq(1)
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
