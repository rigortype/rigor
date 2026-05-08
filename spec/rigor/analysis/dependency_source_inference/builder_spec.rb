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
  end
end
