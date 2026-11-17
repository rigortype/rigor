# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::UndefinedMethod.diagnostic} on a parsed snippet and its scope index, with no
# runner. `runner_check_rules_spec.rb` pins the rule's exemptions through the whole run.
RSpec.describe Rigor::Analysis::CheckRules::UndefinedMethod do
  def diagnostic_for(source)
    program = Prism.parse(source).value
    scope_index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    call = program.statements.body.last
    facts = Rigor::Analysis::CheckRules::CallFacts.new(call, scope_index)
    described_class.diagnostic("mem.rb", call, facts)
  end

  it "reports a method the receiver's class does not declare" do
    row = diagnostic_for(%("x".no_such_method\n))

    expect(row.rule).to eq(Rigor::Analysis::CheckRules::RULE_UNDEFINED_METHOD)
    expect(row.message).to include("undefined method `no_such_method'")
  end

  it "is silent for a method the class declares" do
    expect(diagnostic_for(%("x".upcase\n))).to be_nil
  end

  # No example pins `return nil if call_node.receiver.nil?`: removing it leaves a receiverless call silent anyway,
  # because the receiver type is nil and the rule declines further down, so the guard is redundant by construction.

  it "reports a method a Tuple receiver's class (Array) does not declare" do
    expect(diagnostic_for("[1, 2].no_such_method\n")&.message).to include("undefined method `no_such_method'")
  end

  it "reports a method a HashShape receiver's class (Hash) does not declare" do
    expect(diagnostic_for("{ a: 1 }.no_such_method\n")&.message).to include("undefined method `no_such_method'")
  end

  describe "a union arm typed as the generic metaclass" do
    let(:scope) { Rigor::Scope.empty }

    def blocks?(class_name)
      member = Rigor::Type::Combinator.nominal_of(class_name)
      described_class.send(:union_arm_blocks_undefined_fire?, member, scope)
    end

    it "blocks the union rule on Class and Module, whose singleton methods cannot be enumerated" do
      expect(blocks?("Class")).to be(true)
      expect(blocks?("Module")).to be(true)
    end

    it "does not block on an ordinary closed class" do
      expect(blocks?("String")).to be(false)
    end
  end

  it "is silent for a safe-navigation call on a receiver that is exactly nil" do
    expect(diagnostic_for("nil&.no_such_method\n")).to be_nil
  end

  it "is silent when the project defines the method on the receiver's class" do
    expect(diagnostic_for("class String; def shout = upcase; end\n\"x\".shout\n")).to be_nil
  end

  it "reports a union whose every arm lacks the method" do
    expect(diagnostic_for(%(v = rand < 0.5 ? "a" : :b\nv.no_such_method\n))&.rule)
      .to eq(Rigor::Analysis::CheckRules::RULE_UNDEFINED_METHOD)
  end
end
