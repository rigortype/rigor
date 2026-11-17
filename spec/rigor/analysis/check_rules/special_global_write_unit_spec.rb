# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::SpecialGlobalWrite.diagnostics} on a parsed snippet and its scope index, with no
# runner. `special_global_write_spec.rb` pins the setter table against the running interpreter, and the
# `alias $x $stdout` and escape-hatch arms (`global_aliased?`, `literal_may_answer?`), which need a project census a
# single parsed snippet does not carry; they are guards here, not pinned by an example in this file.
RSpec.describe Rigor::Analysis::CheckRules::SpecialGlobalWrite do
  def rules_for(source)
    program = Prism.parse(source).value
    scope_index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    Array(described_class.diagnostics("mem.rb", program.statements.body.first, scope_index, nil)).map(&:rule)
  end

  it "reports a literal the setter's contract rejects" do
    expect(rules_for("$stdout = 1\n")).to eq([Rigor::Analysis::CheckRules::RULE_GLOBAL_WRITE_TYPE_MISMATCH])
  end

  it "reports a write to a read-only global" do
    expect(rules_for("$! = 1\n")).to eq([Rigor::Analysis::CheckRules::RULE_GLOBAL_READONLY_WRITE])
  end

  it "reports a read-only global as a multiple-assignment target" do
    expect(rules_for("a, $? = 1, 2\n")).to eq([Rigor::Analysis::CheckRules::RULE_GLOBAL_READONLY_WRITE])
  end

  it "does not type-check the value written to a multiple-assignment target" do
    expect(rules_for("a, $stdout = 1, 2\n")).to be_empty
  end

  it "is silent for a value that is not a literal" do
    expect(rules_for("$stdout = $stderr\n")).to be_empty
  end

  it "is silent for a literal the setter accepts" do
    expect(rules_for(%($0 = "name"\n))).to be_empty
  end

  it "is silent for a literal of a class the setter takes outright" do
    expect(rules_for(%($/ = "x"\n))).to be_empty
  end

  it "is silent for an ordinary global the table does not list" do
    expect(rules_for("$my_flag = 1\n")).to be_empty
  end

  it "is silent when the program can give the literal's object the method the setter asks for" do
    source = "class Integer\n  def write(*) = nil\nend\n$stdout = 1\n"
    program = Prism.parse(source).value
    scope_index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)

    expect(described_class.diagnostics("mem.rb", program.statements.body.last, scope_index, nil)).to be_empty
  end
end
