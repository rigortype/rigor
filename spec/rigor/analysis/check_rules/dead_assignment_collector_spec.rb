# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::DeadAssignmentCollector.diagnostics}, the collector's message builder, on the
# results of a parsed snippet: no runner. `collector_diagnostic_builders_spec.rb` pins the same builder through the
# whole run.
#
# Mutation-proved: each guard line of the builder was blanked in turn and an example here failed. It has none; the
# one choice it makes, `Diagnostic.from_name_loc` over `from_node`, no input distinguishes (a local write's name span
# and node span start together, so the column is the same).
RSpec.describe Rigor::Analysis::CheckRules::DeadAssignmentCollector do
  def rows(source)
    program = Prism.parse(source).value
    scope_index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    results = described_class.new(scope_index).collect(program)
    described_class.diagnostics("mem.rb", results)
  end

  it "builds one warning per dead write, naming the local and the def, at the write" do
    row = rows("def t\n  x = 1\n  0\nend\n").first

    expect([row.rule, row.severity, row.path, row.line, row.column, row.message]).to eq(
      [Rigor::Analysis::CheckRules::RULE_DEAD_ASSIGNMENT, :warning, "mem.rb", 2, 3,
       "local `x' assigned in `t' but never read"]
    )
  end

  it "builds the rows in source order" do
    expect(rows("def t\n  a = 1\n  b = 2\n  0\nend\n").map(&:message)).to eq(
      ["local `a' assigned in `t' but never read", "local `b' assigned in `t' but never read"]
    )
  end

  it "builds nothing from no results" do
    expect(described_class.diagnostics("mem.rb", [])).to eq([])
  end

  it "keeps the per-result builder private" do
    expect(described_class.respond_to?(:build_dead_assignment_diagnostic)).to be(false)
  end
end
