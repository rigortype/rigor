# frozen_string_literal: true

require "spec_helper"
require "rigor/inference/dynamic_origin"

RSpec.describe Rigor::Inference::DynamicOrigin do
  it "exports the five v1 cause symbols" do
    expect(described_class::EXTERNAL_GEM_WITHOUT_RBS).to eq(:external_gem_without_rbs)
    expect(described_class::FRAMEWORK_DSL_BOUNDARY).to eq(:framework_dsl_boundary)
    expect(described_class::ANALYZER_BUDGET_CUTOFF).to eq(:analyzer_budget_cutoff)
    expect(described_class::EXPLICIT_UNTYPED).to eq(:explicit_untyped)
    expect(described_class::UNSUPPORTED_SYNTAX).to eq(:unsupported_syntax)
  end

  it "lists all causes in CAUSES" do
    expect(described_class::CAUSES).to contain_exactly(
      :external_gem_without_rbs,
      :framework_dsl_boundary,
      :analyzer_budget_cutoff,
      :explicit_untyped,
      :unsupported_syntax
    )
  end

  it "freezes the CAUSES array" do
    expect(described_class::CAUSES).to be_frozen
  end

  describe ".tractability (ADR-73 P6 / ADR-75 WD2)" do
    it "maps a missing-gem / authored-untyped cause to :add_rbs" do
      expect(described_class.tractability(:external_gem_without_rbs)).to eq(:add_rbs)
      expect(described_class.tractability(:explicit_untyped)).to eq(:add_rbs)
    end

    it "maps a DSL boundary to :enable_plugin" do
      expect(described_class.tractability(:framework_dsl_boundary)).to eq(:enable_plugin)
    end

    it "maps a budget cutoff / unsupported syntax to :engine_gap" do
      expect(described_class.tractability(:analyzer_budget_cutoff)).to eq(:engine_gap)
      expect(described_class.tractability(:unsupported_syntax)).to eq(:engine_gap)
    end

    it "classifies every cause" do
      described_class::CAUSES.each do |cause|
        expect(described_class.tractability(cause)).not_to be_nil, "no tractability for #{cause}"
      end
    end

    it "returns nil for an unknown / absent cause" do
      expect(described_class.tractability(nil)).to be_nil
      expect(described_class.tractability(:made_up)).to be_nil
    end
  end
end
