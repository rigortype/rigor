# frozen_string_literal: true

require "rigor/language_server"
require "rigor/configuration"

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

    it "keeps the cache_store across invalidations (content-addressed)" do
      store_before = context.cache_store
      context.invalidate!

      expect(context.cache_store).to equal(store_before)
    end
  end
end
