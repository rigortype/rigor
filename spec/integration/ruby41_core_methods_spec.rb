# frozen_string_literal: true

# Issues #1691 and #1718 — Ruby 4.1's new core methods resolve through `data/core_overlay/`.
#
# No rbs release through 4.2 declares them, so correct 4.1 code reported `call.undefined-method`. The fixture calls
# every one, and its `assert_type` lines pin a representative subset of the declared returns. The controls below keep
# the silence honest: a misspelt name and a wrong arity on the same receivers still report, so the fixture is not
# quiet because a class degraded to `Dynamic[top]`.

require "spec_helper"
require_relative "support/fixture_harness"

RSpec.describe "Ruby 4.1 core methods (#1691, #1718)" do
  let(:harness) { Rigor::IntegrationSupport::FixtureHarness.new("ruby41_core_methods") }

  # The harness has no `pre_eval:`, so the toplevel `assert_type` helper itself reads as unresolved; that row is the
  # harness's, not the fixture's. A toplevel `autoload_relative` that failed to resolve would report under the same
  # rule, which is why the filter names the helper rather than the rule.
  it "reports nothing on a fixture that calls every new method" do
    reported = harness.diagnostics.reject do |d|
      d.qualified_rule == "call.unresolved-toplevel" && d.message.include?("`assert_type`")
    end
    expect(reported.map { |d| "#{d.line}: #{d.qualified_rule}: #{d.message}" }).to eq([])
  end

  # The bit operations rewrite the receiver in place, so a String literal must not outlive them: `s == "\xAA"` after
  # `s.bit_set(0)` would otherwise fold always-truthy on correct code. Each mutator is paired with a non-mutating call
  # in the same position that keeps the literal, so a seam that stopped folding altogether cannot pass. The calls are
  # not run under Ruby here: the suite's interpreter (4.0) does not define them.
  describe "the in-place bit operations", type: :runner do
    def dumped_types(source)
      analyze(%(require "rigor/testing"\ninclude Rigor::Testing\n#{source})).diagnostics.filter_map do |d|
        d.message.delete_prefix("dump_type: ") if d.message.start_with?("dump_type")
      end
    end

    {
      "bit_set(0)" => "bit_get(0)",
      "bit_clear(0, 4)" => "bit_set?(0)",
      "bit_flip(0..3)" => "bit_count",
      "bitwise_not!" => "bitwise_not",
      'bitwise_and!("\\x0F")' => 'bitwise_and("\\x0F")',
      'bitwise_or!("\\x0F")' => 'bitwise_or("\\x0F")',
      'bitwise_xor!("\\x0F")' => 'bitwise_xor("\\x0F")'
    }.each do |mutator, sibling|
      it "widens a literal under `#{mutator}`, and keeps it under `#{sibling}`" do
        expect(dumped_types(<<~RUBY)).to eq(["String", '"ab"'])
          s = +"ab"
          s.#{mutator}
          dump_type(s)
          t = +"ab"
          t.#{sibling}
          dump_type(t)
        RUBY
      end
    end
  end

  describe "controls", type: :runner do
    def error_rules(source)
      analyze(source).diagnostics.select(&:error?).map { |d| [d.line, d.qualified_rule] }
    end

    it "still reports a misspelt or mis-called method on the same receivers" do
      expect(error_rules(<<~RUBY)).to eq(
        5.bit_counts
        "x".bitwise_and
        (1..2).clampp(1, 2)
        Comparable.descendantz
        ENV.fetch_valuez("A")
        IO::Buffer.new(8).bit_countz
        IO::Buffer.new(8).bit_count(0, 4, 1)
        GC.start(1)
        ObjectSpace.garbage_collect(1)
      RUBY
        [[1, "call.undefined-method"], [2, "call.wrong-arity"], [3, "call.undefined-method"],
         [4, "call.undefined-method"], [5, "call.undefined-method"], [6, "call.undefined-method"],
         [7, "call.wrong-arity"], [8, "call.wrong-arity"], [9, "call.wrong-arity"]]
      )
    end
  end
end
