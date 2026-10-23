# frozen_string_literal: true

# Issue #2104 — the callee-chain census is memoised across evaluators, keyed by the def table and the class self-calls
# resolve in (`StatementEvaluator#resolved_census`). A run builds hundreds of thousands of evaluators, and with only a
# per-evaluator memo #2295 recomputed each closure about thirty times over. While a dependency recorder is active the
# memo is bypassed, so a resolution the closure makes still records its ADR-46 read in the file being analysed.

require "spec_helper"
require "rigor/analysis/dependency_recorder"

RSpec.describe "the callee-chain census memo (#2104)" do
  # `run` hands `acc` to `stripes`, which hands it on to `ghost`, which no file defines: the closure over `stripes`
  # resolves `ghost` and finds nothing, which a recorder files as a missing method.
  let(:source) do
    <<~RUBY
      class Mut
        def run(acc)
          stripes(acc)
        end

        def stripes(acc) = ghost(acc)
      end
    RUBY
  end
  let(:program) { Prism.parse(source).value }
  let(:index) { Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty) }
  let(:call) do
    found = nil
    Rigor::Source::NodeWalker.each(program) do |node|
      found ||= node if node.is_a?(Prism::CallNode) && node.name == :stripes
    end
    found
  end

  def floored_arguments
    Rigor::Inference::StatementEvaluator.new(scope: index[call]).content_mutated_arguments(call)
  end

  it "closes a def once for every evaluator that reads it" do
    allow(Rigor::Inference::CalleeMutationChain).to receive(:close).and_call_original

    expect(floored_arguments).to eq([])
    expect(floored_arguments).to eq([])
    expect(Rigor::Inference::CalleeMutationChain).to have_received(:close).once
  end

  it "still records the closure's resolutions in a recording window after the memo was filled outside one" do
    expect(floored_arguments).to eq([])

    record = Rigor::Analysis::DependencyRecorder.record_for("lib/mut.rb") { floored_arguments }

    expect(record.missing).to include("method:Mut#ghost")
  end
end
