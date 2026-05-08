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

      expect(index.contribution_for(class_name: "Alpha", method_name: :one)).to eq(:instance)
      expect(index.contribution_for(class_name: "Beta", method_name: :two)).to eq(:singleton)
    end

    def stub_resolved_for(gem_name, method_catalog:)
      gem_dir = "/fake/#{gem_name}"
      resolver = Rigor::Analysis::DependencySourceInference::GemResolver
      walker = Rigor::Analysis::DependencySourceInference::Walker
      allow(resolver).to receive(:resolve).with(have_attributes(gem: gem_name)).and_return(
        resolver::Resolved.new(
          gem_name: gem_name, version: "1.0.0",
          gem_dir: gem_dir, mode: :when_missing, roots: %w[lib]
        )
      )
      allow(walker).to receive(:walk).with(gem_dir: gem_dir, roots: %w[lib]).and_return(method_catalog)
    end
  end
end
