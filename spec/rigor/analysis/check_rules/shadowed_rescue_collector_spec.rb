# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::ShadowedRescueCollector.diagnostics}, the collector's message builder, on the
# results of a parsed snippet and on hand-built results: no runner. `collector_diagnostic_builders_spec.rb` pins the
# same builder through the whole run.
#
# Mutation-proved: each guard line of the builder was blanked in turn and an example here failed. It has none; the
# plural arm of the message (`'s' if earlier.size > 1`) is pinned from a hand-built result, as no one snippet tried
# yields a clause shadowed by two earlier clauses at once.
RSpec.describe Rigor::Analysis::CheckRules::ShadowedRescueCollector do
  def rows(source)
    program = Prism.parse(source).value
    scope_index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    results = described_class.new(scope_index).collect(program)
    described_class.diagnostics("mem.rb", results)
  end

  it "builds a warning at the shadowed clause, naming the earlier clause and its line" do
    row = rows("begin\n  1\nrescue StandardError\n  2\nrescue ArgumentError\n  3\nend\n").first

    expect([row.rule, row.severity, row.path, row.line, row.column, row.message]).to eq(
      [Rigor::Analysis::CheckRules::RULE_SHADOWED_RESCUE_CLAUSE, :warning, "mem.rb", 5, 1,
       "shadowed `rescue ArgumentError': every exception class it names is already caught by the earlier " \
       "`rescue StandardError' (line 3) clause, so this clause can never run"]
    )
  end

  it "joins several earlier clauses and pluralises `clause`" do
    clause = Prism.parse("begin\nrescue A\nrescue B\nrescue A, B\nend\n").value.statements.body.first.rescue_clause
    result = described_class::Result.new(
      clause: clause, clause_source: "rescue A, B", earlier_sources: ["rescue A", "rescue B"], earlier_lines: [2, 3]
    )

    expect(described_class.diagnostics("mem.rb", [result]).map(&:message)).to eq(
      ["shadowed `rescue A, B': every exception class it names is already caught by the earlier " \
       "`rescue A' (line 2) and `rescue B' (line 3) clauses, so this clause can never run"]
    )
  end

  it "builds nothing from no results" do
    expect(described_class.diagnostics("mem.rb", [])).to eq([])
  end

  it "keeps the per-result builders private" do
    names = %i[build_shadowed_rescue_diagnostic shadowed_rescue_message]

    expect(names.select { |m| described_class.respond_to?(m) }).to eq([])
  end
end
