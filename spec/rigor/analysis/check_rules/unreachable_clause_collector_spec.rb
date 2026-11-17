# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::UnreachableClauseCollector.diagnostics}, the collector's message builder, on the
# results of a parsed snippet: no runner. `collector_diagnostic_builders_spec.rb` pins the same builder through the
# whole run.
#
# Mutation-proved: each guard line of the builder was blanked in turn and an example here failed. It has none; the
# message's three `case` arms are each pinned below.
RSpec.describe Rigor::Analysis::CheckRules::UnreachableClauseCollector do
  def rows(source)
    program = Prism.parse(source).value
    scope_index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    results = described_class.new(scope_index).collect(program)
    described_class.diagnostics("mem.rb", results)
  end

  it "builds a warning at the dead clause's BODY, for a clause an earlier one already covers" do
    row = rows("x = 1\ncase x\nwhen Integer\n  1\nwhen String\n  2\nend\n").first

    expect([row.rule, row.severity, row.path, row.line, row.column, row.message]).to eq(
      [Rigor::Analysis::CheckRules::RULE_UNREACHABLE_CLAUSE, :warning, "mem.rb", 6, 3,
       "unreachable `when String': `x' is already covered by an earlier `when' clause"]
    )
  end

  it "words a clause the subject is disjoint from" do
    expect(rows("x = 1\ncase x\nwhen String\n  2\nend\n").map(&:message)).to eq(
      ["unreachable `when String': `x' can never be String here (the flow proves the subject disjoint)"]
    )
  end

  it "words an else the clauses already exhaust" do
    expect(rows("y = :s\ncase y\nwhen Symbol\n  1\nelse\n  2\nend\n").map(&:message)).to eq(
      ["unreachable `else': the `when' clauses already cover every value `y' can take here"]
    )
  end

  it "carries the `in` keyword of a pattern match" do
    expect(rows("x = 1\ncase x\nin Integer\n  1\nin String\n  2\nend\n").map(&:message)).to eq(
      ["unreachable `in String': `x' is already covered by an earlier `in' clause"]
    )
  end

  it "builds nothing from no results" do
    expect(described_class.diagnostics("mem.rb", [])).to eq([])
  end

  it "keeps the per-result builders private" do
    names = %i[build_unreachable_clause_diagnostic unreachable_clause_message]

    expect(names.select { |m| described_class.respond_to?(m) }).to eq([])
  end
end
