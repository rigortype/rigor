# frozen_string_literal: true

# Issue #1691 — Ruby 4.1's new core methods resolve through `data/core_overlay/`.
#
# No rbs release through 4.2 declares them, so correct 4.1 code reported `call.undefined-method`. The fixture calls
# every one, and its `assert_type` lines pin a representative subset of the declared returns. The controls below keep
# the silence honest: a misspelt name and a wrong arity on the same receivers still report, so the fixture is not
# quiet because a class degraded to `Dynamic[top]`.

require "spec_helper"
require_relative "support/fixture_harness"

RSpec.describe "Ruby 4.1 core methods (#1691)" do
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
      RUBY
        [[1, "call.undefined-method"], [2, "call.wrong-arity"], [3, "call.undefined-method"],
         [4, "call.undefined-method"], [5, "call.undefined-method"]]
      )
    end
  end
end
