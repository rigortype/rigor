# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::AlwaysRaises.diagnostic} on a parsed snippet and its scope index, with no runner.
RSpec.describe Rigor::Analysis::CheckRules::AlwaysRaises do
  def diagnostic_for(source, raise_shield: nil)
    program = Prism.parse(source).value
    scope_index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    call = program.statements.body.last
    facts = Rigor::Analysis::CheckRules::CallFacts.new(call, scope_index)
    described_class.diagnostic("mem.rb", call, facts, nil, raise_shield)
  end

  it "reports an Integer division by a literal zero" do
    row = diagnostic_for("5 / 0\n")

    expect(row.rule).to eq(Rigor::Analysis::CheckRules::RULE_ALWAYS_RAISES)
    expect(row.message).to include("ZeroDivisionError")
  end

  it "reports a modulo by zero on an Integer local" do
    expect(diagnostic_for("x = 1\nx % 0\n")&.message).to include("`%' by zero")
  end

  it "is silent for a non-zero divisor" do
    expect(diagnostic_for("5 / 2\n")).to be_nil
  end

  it "is silent for a Float receiver, whose division by zero returns Infinity" do
    expect(diagnostic_for("1.0 / 0\n")).to be_nil
  end

  it "is silent when the shield says an enclosing rescue catches the raise" do
    shield = instance_double(Rigor::Analysis::CheckRules::AlwaysRaisesShield, rescued?: true)

    expect(diagnostic_for("5 / 0\n", raise_shield: shield)).to be_nil
  end
end
