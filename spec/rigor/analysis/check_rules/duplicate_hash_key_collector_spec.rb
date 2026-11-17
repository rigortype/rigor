# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::DuplicateHashKeyCollector.diagnostics}, the collector's message builder, on the
# results of a parsed snippet: no runner. `collector_diagnostic_builders_spec.rb` pins the same builder through the
# whole run.
#
# Mutation-proved: each guard line of the builder was blanked in turn and an example here failed. It has none.
RSpec.describe Rigor::Analysis::CheckRules::DuplicateHashKeyCollector do
  def rows(source)
    program = Prism.parse(source).value
    scope_index = Rigor::Inference::ScopeIndexer.index(program, default_scope: Rigor::Scope.empty)
    results = described_class.new(scope_index).collect(program)
    described_class.diagnostics("mem.rb", results)
  end

  it "builds a warning at the LATER key, naming the first key's line" do
    row = rows("h = {a: 1,\n  a: 2}\n").first

    expect([row.rule, row.severity, row.path, row.line, row.column, row.message]).to eq(
      [Rigor::Analysis::CheckRules::RULE_DUPLICATE_HASH_KEY, :warning, "mem.rb", 2, 3,
       "duplicate hash key `:a' in the same literal; this entry overwrites the value first set at line 1"]
    )
  end

  it "names the first occurrence's line for every later repeat" do
    expect(rows("h = {\n  a: 1,\n  a: 2,\n  a: 3\n}\n").map { |r| [r.line, r.message[/line \d+/]] }).to eq(
      [[3, "line 2"], [4, "line 2"]]
    )
  end

  it "labels a string and an integer key by their literal" do
    expect(rows(%(h = {"k" => 1, "k" => 2, 1 => 3, 1 => 4}\n)).map { |r| r.message[/key `[^']*'/] }).to eq(
      ["key `\"k\"'", "key `1'"]
    )
  end

  it "builds nothing from no results" do
    expect(described_class.diagnostics("mem.rb", [])).to eq([])
  end

  it "keeps the per-result builder private" do
    expect(described_class.respond_to?(:build_duplicate_hash_key_diagnostic)).to be(false)
  end
end
