# frozen_string_literal: true

require "spec_helper"

# Issue #870 — the characterisation pin for the exponential interprocedural walk PR #547 exposed.
#
# The fixture is a single class of mutually recursive `visit_*` methods with an optional positional and a
# keyword parameter, the shape of rufo 0.18.2's `formatter.rb`. Inside such a strongly connected component
# every candidate compute's bracket sees a recursion-guard event that references an ANCESTOR frame, so the
# ADR-84 WD3 store gate (`ExpressionTyper#context_tainted?`) refuses the store and each call edge re-walks
# the whole subtree: body evaluations grow exponentially in the method count while the method count grows
# linearly. Before PR #547 the binder declined any signature with an optional or keyword parameter, so
# these edges did not exist and the walk stopped at the first hop.
#
# These examples deliberately assert the CURRENT (bad) shape at a size small enough to stay off the
# suite's critical path. Issue #872 owns the fix and will invert the body-eval expectation into an upper
# bound; the fixture and the generator exist so that gate has something to bind to.
# Measurements: docs/notes/20260909-issue-870-per-parameter-binder-superlinear.md.
RSpec.describe "issue #870 mutually recursive optional-parameter walk" do
  let(:fixture_dir) { File.expand_path("../../integration/fixtures/issue_870_mutual_recursion", __dir__) }

  let(:bt) { Rigor::Inference::BudgetTrace }

  around do |example|
    Rigor::Inference::BudgetTrace.enable!
    Rigor::Inference::BudgetTrace.reset
    example.run
  ensure
    Rigor::Inference::BudgetTrace.disable!
    Rigor::Inference::BudgetTrace.reset
  end

  it "re-walks the cycle instead of memoising it, and analyses clean" do
    configuration = Rigor::Configuration.new("paths" => [File.join(fixture_dir, "visitor_6.rb")])
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    result = guarded_run(runner)

    expect(result.diagnostics.select { |diagnostic| diagnostic.severity == :error }).to be_empty

    # Six methods, hundreds of body evaluations: the walk is not bounded by the method count.
    evals = bt.snapshot[bt::MEMO_BODY_EVALS]
    expect(evals).to be > 6 * 10

    # And the reason is the store gate, not memo-key granularity — every signature is memoised under a
    # handful of keys, so widening the key would not help.
    distinct = bt.distribution(bt::MEMO_DISTINCT_KEY_BY_SIGNATURE)
    visitor_keys = distinct.select { |signature, _| signature.start_with?("Visitor#visit_") }
    expect(visitor_keys.values.max).to be <= 4
    expect(bt.snapshot[bt::MEMO_REFUSE_TRANSIENT]).to be > 0
  end

  it "keeps the checked-in fixture identical to the generator's output" do
    generated = `ruby #{File.join(fixture_dir, "generate.rb").inspect} 6 3`
    committed = File.read(File.join(fixture_dir, "visitor_6.rb"))

    expect(committed).to end_with(generated)
  end
end
