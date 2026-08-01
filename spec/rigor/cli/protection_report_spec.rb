# frozen_string_literal: true

require "spec_helper"
require "rigor/cli/protection_report"

RSpec.describe Rigor::CLI::ProtectionReport do
  def untyped_call(method_name, count: 1, origin: nil)
    Rigor::CLI::UntypedCall.new(
      method_name: method_name, count: count, examples: ["a.rb:1"], dynamic_origin: origin
    )
  end

  def report(calls, cause_site_counts: nil)
    # Default the per-site cause tally to one site per call at its dominant origin, matching the shape the
    # accumulator produces for these single-origin fixtures; tractability tests override it explicitly.
    cause_site_counts ||= calls.each_with_object(Hash.new(0)) { |c, acc| acc[c.dynamic_origin] += c.count }
    described_class.new(files: [], untyped_calls: calls, parse_errors: [],
                        cause_site_counts: cause_site_counts)
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

  describe "#tractability_summary (ADR-73 P6)" do
    it "sums dispatch-site counts per axis across classified holes" do
      r = report([
                   untyped_call(:save, count: 7, origin: :external_gem_without_rbs),
                   untyped_call(:cast, count: 2, origin: :explicit_untyped),
                   untyped_call(:render, count: 4, origin: :framework_dsl_boundary),
                   untyped_call(:whatever, count: 9) # unclassified — excluded
                 ])

      expect(r.tractability_summary).to eq(add_rbs: 9, enable_plugin: 4)
      expect(r.to_h["tractability_summary"]).to eq("add_rbs" => 9, "enable_plugin" => 4)
    end

    it "is empty when no hole has a recorded origin" do
      r = report([untyped_call(:whatever, count: 3)])
      expect(r.tractability_summary).to eq({})
      expect(r.to_h["tractability_summary"]).to eq({})
    end
  end

  describe "#to_h lower_bound_typed (ADR-67 WD6b / issue #263)" do
    def file_protection(lower_bound_typed:, protected_count: 3, unprotected_count: 0, ratio: 1.0, path: "a.rb")
      Rigor::CLI::FileProtection.new(path: path, protected_count: protected_count,
                                     unprotected_count: unprotected_count, ratio: ratio,
                                     lower_bound_typed: lower_bound_typed)
    end

    it "sums per-file lower_bound_typed into the report total and carries it in both places in JSON" do
      files = [file_protection(lower_bound_typed: 2), file_protection(lower_bound_typed: 0, path: "b.rb")]
      r = described_class.new(files: files, untyped_calls: [], parse_errors: [], cause_site_counts: {})

      expect(r.total_lower_bound_typed).to eq(2)
      expect(r.to_h["lower_bound_typed"]).to eq(2)
      expect(r.to_h["files"].map { |f| f["lower_bound_typed"] }).to eq([2, 0])
    end

    it "carries lower_bound_typed as 0 (present, not omitted) when no site is lower-bound-typed" do
      r = described_class.new(files: [file_protection(lower_bound_typed: 0)], untyped_calls: [],
                              parse_errors: [], cause_site_counts: {})

      expect(r.to_h).to have_key("lower_bound_typed")
      expect(r.to_h["lower_bound_typed"]).to eq(0)
    end

    it "does not affect total_protected / ratio (headline invariance)" do
      files = [file_protection(lower_bound_typed: 2, protected_count: 3, unprotected_count: 1, ratio: 0.75)]
      r = described_class.new(files: files, untyped_calls: [], parse_errors: [], cause_site_counts: {})

      expect(r.total_protected).to eq(3)
      expect(r.ratio).to eq(0.75)
    end
  end

  describe "#cause_site_totals (ADR-82)" do
    it "reports an exact per-site cause tally including the causeless sites" do
      # A method group's dominant origin is lossy for a mixed group; the per-site tally is exact and is what
      # tractability_summary is now computed from.
      r = report(
        [untyped_call(:foo, count: 10)],
        cause_site_counts: { :inferred_return_untyped => 6, :unsupported_syntax => 3, nil => 1 }
      )
      expect(r.to_h["cause_site_counts"]).to eq(
        "inferred_return_untyped" => 6, "unsupported_syntax" => 3, "none" => 1
      )
      # tractability derives per-site: 6 + 3 engine_gap, the causeless site excluded.
      expect(r.tractability_summary).to eq(engine_gap: 9)
    end
  end
end
