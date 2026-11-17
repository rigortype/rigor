# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::AlwaysTruthyConditionCollector.diagnostics}, the collector's message builder, on the
# results of a parsed snippet: no runner. `collector_diagnostic_builders_spec.rb` pins the same builder through the
# whole run.
#
# Mutation-proved: each guard line of the builder was blanked in turn and an example here failed. It has none.
RSpec.describe Rigor::Analysis::CheckRules::AlwaysTruthyConditionCollector do
  def rows(source)
    program = Prism.parse(source).value
    scope_index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    results = described_class.new(scope_index).collect(program)
    described_class.diagnostics("mem.rb", results)
  end

  it "builds a warning at the predicate, with the truthy polarity" do
    row = rows("x = 1\nif x\n  1\nend\n").first

    expect([row.rule, row.severity, row.path, row.line, row.column, row.message]).to eq(
      [Rigor::Analysis::CheckRules::RULE_ALWAYS_TRUTHY_CONDITION, :warning, "mem.rb", 2, 4,
       "condition is always truthy (the surrounding flow proves it folds to a constant)"]
    )
  end

  it "threads the falsey polarity into the message" do
    expect(rows("x = nil\nunless x\n  1\nend\n").map(&:message)).to eq(
      ["condition is always falsey (the surrounding flow proves it folds to a constant)"]
    )
  end

  it "builds nothing from no results" do
    expect(described_class.diagnostics("mem.rb", [])).to eq([])
  end

  it "keeps the per-result builder private" do
    expect(described_class.respond_to?(:build_always_truthy_condition_diagnostic)).to be(false)
  end
end
