# frozen_string_literal: true

require "rigor/language_server"
require "rigor/configuration"
require "rigor/analysis/project_scan"
require "rigor/analysis/dependency_source_inference"
require "rigor/inference/synthetic_method_index"

RSpec.describe Rigor::LanguageServer::ProjectContext do
  let(:configuration) { Rigor::Configuration.new("paths" => []) }
  let(:context) { described_class.new(configuration: configuration) }

  describe "#environment" do
    it "lazy-builds the Environment and memoises it across calls" do
      env_a = context.environment
      env_b = context.environment

      expect(env_b).to equal(env_a)
    end
  end

  describe "#cache_store" do
    it "returns a read-only Cache::Store rooted at configuration.cache_path" do
      store = context.cache_store

      expect(store).to be_a(Rigor::Cache::Store)
      expect(store.read_only?).to be(true)
      expect(store.root).to eq(configuration.cache_path)
    end

    it "memoises across calls" do
      expect(context.cache_store).to equal(context.cache_store)
    end
  end

  describe "#project_scan" do
    it "lazy-builds the Analysis::ProjectScan and memoises it across calls" do
      scan_a = context.project_scan
      scan_b = context.project_scan

      expect(scan_a).to be_a(Rigor::Analysis::ProjectScan)
      expect(scan_b).to equal(scan_a)
    end

    it "exposes the empty pre-pass state for a project with no plugins / deps / pre_eval" do
      scan = context.project_scan

      expect(scan.plugin_registry).to be_empty
      expect(scan.dependency_source_index).to eq(Rigor::Analysis::DependencySourceInference::Index::EMPTY)
      expect(scan.synthetic_method_index).to eq(Rigor::Inference::SyntheticMethodIndex::EMPTY)
      expect(scan.plugin_prepare_diagnostics).to eq([])
      expect(scan.pre_eval_diagnostics).to eq([])
    end
  end

  describe "#invalidate!" do
    it "bumps the generation counter" do
      expect { context.invalidate! }.to change(context, :generation).by(1)
    end

    it "drops the cached Environment so the next read rebuilds" do
      env_before = context.environment
      context.invalidate!
      env_after = context.environment

      expect(env_after).not_to equal(env_before)
    end

    it "drops the cached ProjectScan so the next read rebuilds" do
      scan_before = context.project_scan
      context.invalidate!
      scan_after = context.project_scan

      expect(scan_after).not_to equal(scan_before)
    end

    it "keeps the cache_store across invalidations (content-addressed)" do
      store_before = context.cache_store
      context.invalidate!

      expect(context.cache_store).to equal(store_before)
    end
  end
end
