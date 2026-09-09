# frozen_string_literal: true

require "spec_helper"

# Issue #870 / #872 — the regression gate for the exponential interprocedural walk PR #547 exposed.
#
# The fixture is a single class of mutually recursive `visit_*` methods with an optional positional and a
# keyword parameter, the shape of rufo 0.18.2's `formatter.rb`. Inside such a strongly connected component
# every candidate compute's bracket sees a recursion-guard event that references an ANCESTOR frame. Before
# the ADR-84 WD6 top-result exemption the WD3 store gate refused every store on that evidence, so each call
# edge re-walked the whole callee subtree and body evaluations grew exponentially in the method count while
# the method count grew linearly (size 14: 192,414 evaluations, 14.0 s; rufo's `formatter.rb` did not
# finish in 25 minutes). WD6 stores a context-tainted result when it is already `Dynamic[top]`, which is
# every result inside such a component, and the walk collapses to one evaluation per signature per key.
#
# The bound below is on the BUDGET-TRACE COUNTER, not on a wall clock: the growth is in body evaluations
# and a wall-time bound would be a flake source on a loaded CI box. Measurements:
# docs/notes/20260909-issue-870-per-parameter-binder-superlinear.md.
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

  it "memoises the cycle instead of re-walking it, and analyses clean" do
    configuration = Rigor::Configuration.new("paths" => [File.join(fixture_dir, "visitor_6.rb")])
    runner = Rigor::Analysis::Runner.new(configuration: configuration, cache_store: nil)
    result = guarded_run(runner)

    expect(result.diagnostics.select { |diagnostic| diagnostic.severity == :error }).to be_empty

    # Six methods, a bounded number of body evaluations: the walk is linear in the component, not
    # exponential. Pre-fix this read 798; the bound is generous enough to absorb ordinary engine drift and
    # still an order of magnitude below the pre-fix shape.
    evals = bt.snapshot[bt::MEMO_BODY_EVALS]
    expect(evals).to be <= 6 * 10

    # And the mechanism is the store gate, not memo-key granularity — every signature is still memoised
    # under a handful of keys, and no candidate compute in the component is refused a store any more.
    distinct = bt.distribution(bt::MEMO_DISTINCT_KEY_BY_SIGNATURE)
    visitor_keys = distinct.select { |signature, _| signature.start_with?("Visitor#visit_") }
    expect(visitor_keys.values.max).to be <= 4
    expect(bt.snapshot[bt::MEMO_REFUSE_TRANSIENT]).to eq(0)
  end

  it "keeps the checked-in fixture identical to the generator's output" do
    generated = `ruby #{File.join(fixture_dir, "generate.rb").inspect} 6 3`
    committed = File.read(File.join(fixture_dir, "visitor_6.rb"))

    expect(committed).to end_with(generated)
  end
end
