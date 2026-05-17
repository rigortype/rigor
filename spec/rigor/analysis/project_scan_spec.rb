# frozen_string_literal: true

require "rigor/analysis/project_scan"
require "rigor/plugin"
require "rigor/analysis/dependency_source_inference"
require "rigor/inference/synthetic_method_index"
require "rigor/inference/project_patched_methods"

RSpec.describe Rigor::Analysis::ProjectScan do
  let(:plugin_registry) { Rigor::Plugin::Registry::EMPTY }
  let(:dependency_source_index) { Rigor::Analysis::DependencySourceInference::Index::EMPTY }
  let(:synthetic_method_index) { Rigor::Inference::SyntheticMethodIndex::EMPTY }
  let(:project_patched_methods) { Rigor::Inference::ProjectPatchedMethods::EMPTY }

  let(:scan) do
    described_class.new(
      plugin_registry: plugin_registry,
      dependency_source_index: dependency_source_index,
      synthetic_method_index: synthetic_method_index,
      project_patched_methods: project_patched_methods,
      plugin_prepare_diagnostics: [],
      pre_eval_diagnostics: []
    )
  end

  it "exposes all six slots as readers" do
    expect(scan.plugin_registry).to eq(plugin_registry)
    expect(scan.dependency_source_index).to eq(dependency_source_index)
    expect(scan.synthetic_method_index).to eq(synthetic_method_index)
    expect(scan.project_patched_methods).to eq(project_patched_methods)
    expect(scan.plugin_prepare_diagnostics).to eq([])
    expect(scan.pre_eval_diagnostics).to eq([])
  end

  it "is value-comparable (Data.define semantics)" do
    other = described_class.new(
      plugin_registry: plugin_registry,
      dependency_source_index: dependency_source_index,
      synthetic_method_index: synthetic_method_index,
      project_patched_methods: project_patched_methods,
      plugin_prepare_diagnostics: [],
      pre_eval_diagnostics: []
    )
    expect(scan).to eq(other)
  end

  it "is immutable — Data.define instances are frozen on construction" do
    expect(scan).to be_frozen
  end
end
