# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::RaiseNonException.diagnostic} on a parsed snippet and its scope index, with no
# runner. `raise_non_exception_spec.rb` pins the rule's envelope through the whole run.
RSpec.describe Rigor::Analysis::CheckRules::RaiseNonException do # rubocop:disable RSpec/SpecFilePathFormat
  def diagnostic_for(source)
    program = Prism.parse(source).value
    scope_index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    described_class.diagnostic("mem.rb", program.statements.body.last, scope_index)
  end

  it "reports `raise` of an Integer" do
    row = diagnostic_for("raise 42\n")

    expect(row.rule).to eq(Rigor::Analysis::CheckRules::RULE_RAISE_NON_EXCEPTION)
    expect(row.message).to include("`raise' operand types as 42")
  end

  it "reports `fail` of a Symbol" do
    expect(diagnostic_for("fail :sym\n")&.message).to include("`fail' operand types as :sym")
  end

  it "is silent for an Exception class" do
    expect(diagnostic_for("raise ArgumentError\n")).to be_nil
  end

  it "is silent for a String, which raises RuntimeError" do
    expect(diagnostic_for(%(raise "boom"\n))).to be_nil
  end

  it "is silent for another implicit-self method" do
    expect(diagnostic_for("puts 42\n")).to be_nil
  end

  it "is silent for a `raise` handed a block, which is some other method" do
    expect(diagnostic_for("raise(42) { }\n")).to be_nil
  end

  it "is silent for an explicit-receiver `raise`, which is a user method" do
    expect(diagnostic_for("obj.raise 42\n")).to be_nil
  end

  it "is silent when the project redefines `raise` in scope" do
    expect(diagnostic_for("def raise(*) = nil\nraise 42\n")).to be_nil
  end
end
