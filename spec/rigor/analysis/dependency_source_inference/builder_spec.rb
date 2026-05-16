# frozen_string_literal: true

require "rigor/configuration"
require "rigor/analysis/dependency_source_inference"

RSpec.describe Rigor::Analysis::DependencySourceInference::Builder do
  def dependencies(*entries)
    Rigor::Configuration::Dependencies.from_h("source_inference" => entries)
  end

  describe ".build" do
    it "returns Index::EMPTY when dependencies is empty" do
      empty = Rigor::Configuration::Dependencies.from_h(nil)

      expect(described_class.build(empty)).to equal(
        Rigor::Analysis::DependencySourceInference::Index::EMPTY
      )
    end

    it "partitions entries into resolved and unresolvable buckets" do
      input = dependencies(
        { "gem" => "prism" },
        { "gem" => "definitely-no-such-gem-rigor-12345" }
      )

      index = described_class.build(input)

      expect(index.resolved_gems.length).to eq(1)
      expect(index.resolved_gems.first.gem_name).to eq("prism")
      expect(index.unresolvable.length).to eq(1)
      expect(index.unresolvable.first.gem_name).to eq("definitely-no-such-gem-rigor-12345")
      expect(index.unresolvable.first.reason).to eq(:not_in_bundle)
    end

    it "skips disabled entries without attempting to resolve them" do
      input = dependencies(
        { "gem" => "definitely-no-such-gem-rigor-12345", "mode" => "disabled" }
      )

      index = described_class.build(input)

      expect(index.resolved_gems).to eq([])
      expect(index.unresolvable).to eq([])
    end

    it "aggregates each resolved gem's method catalog into the Index (slice 2b-i)" do
      stub_resolved_for("alpha", method_catalog: { ["Alpha", :one] => :instance })
      stub_resolved_for("beta", method_catalog: { ["Beta", :two] => :singleton })

      index = described_class.build(dependencies({ "gem" => "alpha" }, { "gem" => "beta" }))

      expect(index.contribution_for(class_name: "Alpha", method_name: :one).kind).to eq(:instance)
      expect(index.contribution_for(class_name: "Beta", method_name: :two).kind).to eq(:singleton)
    end

    it "records the class-to-gem reverse index (slice 5b β budget)" do
      stub_resolved_for(
        "alpha", method_catalog: { ["Alpha::A", :one] => :instance, ["Alpha::B", :two] => :instance }
      )
      stub_resolved_for("beta", method_catalog: { ["Beta::Klass", :three] => :singleton })

      index = described_class.build(dependencies({ "gem" => "alpha" }, { "gem" => "beta" }))

      expect(index.gem_for("Alpha::A")).to eq("alpha")
      expect(index.gem_for("Alpha::B")).to eq("alpha")
      expect(index.gem_for("Beta::Klass")).to eq("beta")
      expect(index.gem_for("Unknown")).to be_nil
    end

    it "carries the configured budget_overrun_strategy through to the Index" do
      input = Rigor::Configuration::Dependencies.from_h(
        "source_inference" => [{ "gem" => "alpha" }],
        "budget_overrun_strategy" => "dependency_silence"
      )
      stub_resolved_for("alpha", method_catalog: {})

      index = described_class.build(input)

      expect(index.budget_overrun_strategy).to eq(:dependency_silence)
    end

    it "records budget-exceeded gems on the Index when the Walker truncates (slice 4)" do
      stub_resolved_for("alpha", method_catalog: { ["Alpha", :one] => :instance })
      stub_resolved_for("beta", method_catalog: { ["Beta", :two] => :instance }, truncated: true)

      index = described_class.build(dependencies({ "gem" => "alpha" }, { "gem" => "beta" }))

      expect(index.budget_exceeded).to eq(["beta"])
    end

    it "threads dependencies.budget_per_gem through to Walker.walk (slice 4)" do
      input = Rigor::Configuration::Dependencies.from_h(
        "source_inference" => [{ "gem" => "alpha" }],
        "budget_per_gem" => 7500
      )
      stub_resolved_for("alpha", method_catalog: {})
      walker = Rigor::Analysis::DependencySourceInference::Walker

      described_class.build(input)

      expect(walker).to have_received(:walk).with(
        gem_dir: "/fake/alpha", roots: %w[lib], budget: 7500
      )
    end

    def stub_resolved_for(gem_name, method_catalog:, truncated: false)
      gem_dir = "/fake/#{gem_name}"
      resolver = Rigor::Analysis::DependencySourceInference::GemResolver
      walker = Rigor::Analysis::DependencySourceInference::Walker
      allow(resolver).to receive(:resolve).with(have_attributes(gem: gem_name)).and_return(
        resolver::Resolved.new(
          gem_name: gem_name, version: "1.0.0",
          gem_dir: gem_dir, mode: :when_missing, roots: %w[lib]
        )
      )
      # The Index normalizes legacy bare-Symbol catalog values
      # (`=> :instance`) into `CatalogEntry(kind:)` at
      # construction, so spec stubs may pass either shape. We
      # keep the helper's API on bare Symbols for legibility.
      outcome = walker::Outcome.new(catalog: method_catalog, truncated: truncated)
      allow(walker).to receive(:walk).with(
        gem_dir: gem_dir, roots: %w[lib], budget: anything
      ).and_return(outcome)
    end
  end
end
