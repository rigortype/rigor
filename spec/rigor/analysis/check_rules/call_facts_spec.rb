# frozen_string_literal: true

require "spec_helper"

# Issue #2786 — the per-call-node rules read the call's receiver type, and the signature the call resolves to on
# it, from one {CheckRules::CallFacts} instead of each deriving them again. Output is unchanged by construction (one
# `(scope, node)` pair types structurally equal within a run); what this pins is the count: once per call node.
RSpec.describe Rigor::Analysis::CheckRules::CallFacts do
  def index_for(source)
    program = Prism.parse(source).value
    [program, Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)]
  end

  def rules_for(call_node, scope_index)
    Rigor::Analysis::CheckRules.send(:call_node_diagnostics, "mem.rb", call_node, scope_index).map(&:rule)
  end

  describe "the receiver type" do
    # `x / 0` on an Integer local reaches the receiver in all six rules that type it: `call.undefined-method`,
    # `call.wrong-arity`, `call.argument-type-mismatch`, `call.possible-nil-receiver` (a local-variable receiver),
    # `flow.always-raises` (an Integer `/`) and `def.method-visibility-mismatch` (an explicit, non-`self` receiver).
    let(:indexed) { index_for("x = 1\nx / 0\n") }
    let(:call_node) { indexed.first.statements.body.last }
    let(:scope_index) { indexed.last }

    # `Rigor::Scope` is frozen, so the count is taken one level down, where `Scope#type_of` hands each query to a
    # fresh `ExpressionTyper`.
    def receiver_typings
      count = 0
      receiver = call_node.receiver
      typer = Rigor::Inference::ExpressionTyper
      allow_any_instance_of(typer).to receive(:type_of).and_wrap_original do |original, node| # rubocop:disable RSpec/AnyInstance
        count += 1 if node.equal?(receiver)
        original.call(node)
      end
      rules = rules_for(call_node, scope_index)
      [count, rules]
    end

    it "is typed once for every rule that reads it" do
      scope_index # indexed before counting: the main pass types the receiver too
      count, rules = receiver_typings

      expect(count).to eq(1)
      # A rule that reads the shared type still reports from it.
      expect(rules).to eq(["flow.always-raises"])
    end

    it "is typed under the call's index scope" do
      facts = described_class.new(call_node, scope_index)

      expect(facts.scope).to equal(scope_index[call_node])
      expect(facts.receiver_type).to eq(scope_index[call_node].type_of(call_node.receiver))
    end
  end

  describe "the receiver signature" do
    # `call.wrong-arity` and `call.argument-type-mismatch` both validate a plain positional call on an RBS-known
    # receiver against its trustworthy signature. A method with no signature answers nil, which is remembered too.
    {
      "a declared method" => ["\"ab\".center(1)\n", []],
      "a method no signature declares" => ["\"ab\".no_such(1)\n", ["call.undefined-method"]]
    }.each do |label, (source, expected_rules)|
      it "is resolved once for #{label}" do
        program, scope_index = index_for(source)
        call_node = program.statements.body.first
        allow(Rigor::Analysis::CheckRules).to receive(:trustworthy_signature).and_call_original

        expect(rules_for(call_node, scope_index)).to eq(expected_rules)
        expect(Rigor::Analysis::CheckRules).to have_received(:trustworthy_signature).once
      end
    end
  end
end
