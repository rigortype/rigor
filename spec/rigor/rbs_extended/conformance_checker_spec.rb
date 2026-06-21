# frozen_string_literal: true

require "rigor/rbs_extended"
require "rigor/rbs_extended/conformance_checker"

RSpec.describe Rigor::RbsExtended::ConformanceChecker do
  let(:stub_loader) do
    loader = instance_double(Rigor::Environment::RbsLoader)
    allow(loader).to receive(:each_class_decl_annotation_with_name)
    loader
  end

  describe ".scan" do
    it "returns an empty array when the loader is nil" do
      expect(described_class.scan(nil)).to eq([])
    end

    it "returns an empty array when no annotations are present" do
      expect(described_class.scan(stub_loader)).to eq([])
    end
  end

  describe "private helpers" do
    describe "namespace_prefixes" do
      it "splits qualified names into longest-first prefixes" do
        expect(described_class.send(:namespace_prefixes, "Foo::Bar::Baz")).to eq(
          ["Foo::Bar::Baz", "Foo::Bar", "Foo"]
        )
      end

      it "returns [name] for a top-level name" do
        expect(described_class.send(:namespace_prefixes, "String")).to eq(["String"])
      end
    end

    describe "normalize" do
      it "strips leading ::" do
        expect(described_class.send(:normalize, "::String")).to eq("String")
      end

      it "leaves a bare name unchanged" do
        expect(described_class.send(:normalize, "String")).to eq("String")
      end
    end

    describe "dynamic_top?" do
      it "returns true for untyped (Dynamic)" do
        dyn = Rigor::Type::Combinator.untyped
        expect(described_class.send(:dynamic_top?, dyn)).to be(true)
      end

      it "returns false for Nominal types" do
        nom = Rigor::Type::Combinator.nominal_of("String")
        expect(described_class.send(:dynamic_top?, nom)).to be(false)
      end
    end
  end
end
