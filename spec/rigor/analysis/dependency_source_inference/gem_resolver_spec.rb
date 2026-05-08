# frozen_string_literal: true

require "rigor/configuration"
require "rigor/analysis/dependency_source_inference"

RSpec.describe Rigor::Analysis::DependencySourceInference::GemResolver do
  let(:resolver) { described_class }

  def entry(gem_name, mode: :when_missing, roots: %w[lib])
    Rigor::Configuration::Dependencies::Entry.new(
      gem: gem_name, mode: mode, roots: roots
    )
  end

  describe ".resolve" do
    it "returns a Resolved value when the gem is in the bundle (prism)" do
      outcome = resolver.resolve(entry("prism"))

      expect(outcome).to be_a(Rigor::Analysis::DependencySourceInference::GemResolver::Resolved)
      expect(outcome.gem_name).to eq("prism")
      expect(outcome.version).to match(/\A\d+\.\d+/)
      expect(outcome.gem_dir).to be_a(String)
      expect(File.directory?(outcome.gem_dir)).to be(true)
      expect(outcome.mode).to eq(:when_missing)
      expect(outcome.roots).to eq(%w[lib])
    end

    it "carries the entry's mode and roots through to the Resolved value" do
      outcome = resolver.resolve(entry("prism", mode: :full, roots: %w[lib ext]))

      expect(outcome.mode).to eq(:full)
      expect(outcome.roots).to eq(%w[lib ext])
    end

    it "returns an Unresolvable value when the gem is not in the bundle" do
      outcome = resolver.resolve(entry("definitely-no-such-gem-rigor-12345"))

      expect(outcome).to be_a(Rigor::Analysis::DependencySourceInference::GemResolver::Unresolvable)
      expect(outcome.gem_name).to eq("definitely-no-such-gem-rigor-12345")
      expect(outcome.reason).to eq(:not_in_bundle)
    end
  end

  describe "Resolved#descriptor_key" do
    it "exposes a (gem_name, version, mode) tuple suitable for cache descriptors" do
      outcome = resolver.resolve(entry("prism", mode: :full))

      expect(outcome.descriptor_key.first).to eq("prism")
      expect(outcome.descriptor_key.length).to eq(3)
      expect(outcome.descriptor_key.last).to eq(:full)
      expect(outcome.descriptor_key).to be_frozen
    end
  end
end
