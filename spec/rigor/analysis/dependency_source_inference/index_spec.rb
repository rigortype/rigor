# frozen_string_literal: true

require "rigor/analysis/dependency_source_inference"

RSpec.describe Rigor::Analysis::DependencySourceInference::Index do
  describe "EMPTY" do
    it "is frozen with no resolved gems and no unresolvable entries" do
      expect(described_class::EMPTY).to be_frozen
      expect(described_class::EMPTY.resolved_gems).to eq([])
      expect(described_class::EMPTY.unresolvable).to eq([])
      expect(described_class::EMPTY).to be_empty
    end
  end

  describe "#contribution_for" do
    it "returns nil for any (class_name, method_name) — slice 2a stub" do
      index = described_class.new

      expect(index.contribution_for(class_name: "Foo", method_name: :bar)).to be_nil
    end
  end

  describe "#empty?" do
    it "is true when no resolved gems are present" do
      expect(described_class.new).to be_empty
    end

    it "is false once a resolved gem is registered, even with no method facts yet" do
      resolver = Rigor::Analysis::DependencySourceInference::GemResolver
      resolved = resolver::Resolved.new(
        gem_name: "rack", version: "1.0.0", gem_dir: "/tmp/rack", mode: :when_missing, roots: %w[lib]
      )
      index = described_class.new(resolved_gems: [resolved])

      expect(index).not_to be_empty
      expect(index.resolved_gems).to eq([resolved])
    end
  end
end
