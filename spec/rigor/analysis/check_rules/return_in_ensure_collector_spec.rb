# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::ReturnInEnsureCollector.diagnostics}, the collector's message builder, on the
# results of a parsed snippet: no runner. `collector_diagnostic_builders_spec.rb` pins the same builder through the
# whole run.
#
# Mutation-proved: each guard line of the builder was blanked in turn and an example here failed. It has none.
RSpec.describe Rigor::Analysis::CheckRules::ReturnInEnsureCollector do
  def rows(source)
    program = Prism.parse(source).value
    scope_index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    results = described_class.new(scope_index).collect(program)
    described_class.diagnostics("mem.rb", results)
  end

  it "builds a warning at the `return` keyword" do
    row = rows("def t\n  1\nensure\n  puts 1; return 2\nend\n").first

    expect([row.rule, row.severity, row.path, row.line, row.column, row.message]).to eq(
      [Rigor::Analysis::CheckRules::RULE_RETURN_IN_ENSURE, :warning, "mem.rb", 4, 11,
       "`return' inside `ensure' discards the method's in-flight return value and swallows any in-flight exception"]
    )
  end

  it "builds one row per `return`, in source order" do
    expect(rows("def t\n  1\nensure\n  return 1\n  return 2\nend\n").map(&:line)).to eq([4, 5])
  end

  it "builds nothing from no results" do
    expect(described_class.diagnostics("mem.rb", [])).to eq([])
  end

  it "keeps the per-result builder private" do
    expect(described_class.respond_to?(:build_return_in_ensure_diagnostic)).to be(false)
  end
end
