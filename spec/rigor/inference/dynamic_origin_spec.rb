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
end
