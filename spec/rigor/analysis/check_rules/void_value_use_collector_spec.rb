# frozen_string_literal: true

require "spec_helper"

# ADR-116 WD1 / C4 — {CheckRules::VoidValueUseCollector.diagnostics}, the collector's message builder, on hand-built
# results: no runner. The collector only records a use whose callee RBS declares `-> void`, which needs a loaded
# signature; `collector_diagnostic_builders_spec.rb` pins the builder through the whole run with one.
#
# Mutation-proved: each guard line of the builder was blanked in turn and an example here failed. It has none.
RSpec.describe Rigor::Analysis::CheckRules::VoidValueUseCollector do
  let(:origin) { Struct.new(:label).new("VoidBox#log") }

  def result_for(source)
    call = Prism.parse(source).value.statements.body.last.value
    described_class::Result.new(void_node: call, origin: origin)
  end

  it "builds a warning at the void call's own location, naming the declaring member" do
    row = described_class.diagnostics("mem.rb", [result_for("l = nil\nassigned = l.log(1)\n")]).first

    expect([row.rule, row.severity, row.path, row.line, row.column, row.message]).to eq(
      [Rigor::Analysis::CheckRules::RULE_VALUE_USE_VOID, :warning, "mem.rb", 2, 12,
       "value use of `void': `VoidBox#log' declares `-> void', so its return recovers to `top' and should " \
       "not be used as a value"]
    )
  end

  it "builds one row per result, in order" do
    results = [result_for("l = nil\na = l.log(1)\n"), result_for("l = nil\n\nb = l.log(2)\n")]

    expect(described_class.diagnostics("mem.rb", results).map(&:line)).to eq([2, 3])
  end

  it "builds nothing from no results" do
    expect(described_class.diagnostics("mem.rb", [])).to eq([])
  end

  it "keeps the per-result builder private" do
    expect(described_class.respond_to?(:build_void_value_use_diagnostic)).to be(false)
  end
end
