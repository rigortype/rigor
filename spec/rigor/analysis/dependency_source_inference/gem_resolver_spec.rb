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

  # Issue #1814 — the rows the run's cache key and the incremental fingerprint take, read without walking any gem.
  describe ".dependency_entries" do
    def dependencies(*entries)
      Rigor::Configuration::Dependencies.from_h("source_inference" => entries)
    end

    it "lifts each resolvable, enabled entry into a (name, version, mode) row, in configuration order" do
      rows = resolver.dependency_entries(
        dependencies({ "gem" => "prism", "mode" => "full" }, { "gem" => "rbs" },
                     { "gem" => "definitely-no-such-gem-rigor-12345" }, { "gem" => "rack", "mode" => "disabled" })
      )

      expect(rows.map { |row| [row.gem_name, row.mode] }).to eq([["prism", :full], ["rbs", :when_missing]])
      expect(rows.map(&:gem_version)).to all(match(/\A\d+\.\d+/))
    end

    it "moves a row with the resolved version" do
      allow(resolver).to receive(:locate_gem_spec).with("prism").and_return(
        instance_double(Gem::Specification, version: Gem::Version.new("1.0.0"), full_gem_path: "/x")
      )
      before = resolver.dependency_entries(dependencies({ "gem" => "prism" }))
      allow(resolver).to receive(:locate_gem_spec).with("prism").and_return(
        instance_double(Gem::Specification, version: Gem::Version.new("1.1.0"), full_gem_path: "/x")
      )
      after = resolver.dependency_entries(dependencies({ "gem" => "prism" }))

      expect(before).not_to eq(after)
      expect(before.map(&:gem_version) + after.map(&:gem_version)).to eq(%w[1.0.0 1.1.0])
    end
  end
end
