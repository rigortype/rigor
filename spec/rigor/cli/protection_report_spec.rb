# frozen_string_literal: true

require "spec_helper"
require "rigor/cli/protection_report"

RSpec.describe Rigor::CLI::ProtectionReport do
  def untyped_call(method_name, count: 1, origin: nil)
    Rigor::CLI::UntypedCall.new(
      method_name: method_name, count: count, examples: ["a.rb:1"], dynamic_origin: origin
    )
  end

  def report(calls)
    described_class.new(files: [], untyped_calls: calls, parse_errors: [])
  end

  describe "#to_h add_a_type_here tractability (ADR-73 P6 / ADR-75 WD2)" do
    it "carries the tractability axis alongside a present dynamic_origin" do
      entry = report([untyped_call(:save, origin: :external_gem_without_rbs)]).to_h["add_a_type_here"].first

      expect(entry["dynamic_origin"]).to eq(:external_gem_without_rbs)
      expect(entry["tractability"]).to eq(:add_rbs)
    end

    it "maps a DSL-boundary origin to :enable_plugin" do
      entry = report([untyped_call(:render, origin: :framework_dsl_boundary)]).to_h["add_a_type_here"].first
      expect(entry["tractability"]).to eq(:enable_plugin)
    end

    it "omits both fields when there is no recorded origin" do
      entry = report([untyped_call(:whatever)]).to_h["add_a_type_here"].first
      expect(entry).not_to have_key("dynamic_origin")
      expect(entry).not_to have_key("tractability")
    end
  end
end
