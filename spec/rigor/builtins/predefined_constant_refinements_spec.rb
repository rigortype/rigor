# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Builtins::PredefinedConstantRefinements do
  let(:non_empty_string) { Rigor::Type::Combinator.non_empty_string }
  let(:numeric_string)   { Rigor::Type::Combinator.numeric_string }

  describe ".lookup — tier 1: exact-value whitelist" do
    it "returns Constant[Math::PI] (Float)" do
      type = described_class.lookup("Math::PI")
      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(Math::PI)
    end

    it "returns Constant[Math::E] (Float)" do
      type = described_class.lookup("Math::E")
      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(Math::E)
    end

    it "returns Constant[Float] (not the broader Nominal[Float] from RBS)" do
      type = described_class.lookup("Math::PI")
      expect(type).not_to be_a(Rigor::Type::Nominal)
    end
  end

  describe ".lookup — tier 2: runtime String inspection" do
    it "returns non-empty-string for RUBY_VERSION" do
      expect(described_class.lookup("RUBY_VERSION")).to eq(non_empty_string)
    end

    it "returns non-empty-string for Ruby::VERSION" do
      expect(described_class.lookup("Ruby::VERSION")).to eq(non_empty_string)
    end

    it "returns non-empty-string for RUBY_PLATFORM" do
      expect(described_class.lookup("RUBY_PLATFORM")).to eq(non_empty_string)
    end

    it "returns non-empty-string for Ruby::ENGINE" do
      expect(described_class.lookup("Ruby::ENGINE")).to eq(non_empty_string)
    end

    it "returns non-empty-string for RUBY_REVISION (git SHA — non-empty, non-numeric)" do
      expect(described_class.lookup("RUBY_REVISION")).to eq(non_empty_string)
    end

    it "returns nil for RUBY_PATCHLEVEL (Integer constant — no String refinement)" do
      expect(described_class.lookup("RUBY_PATCHLEVEL")).to be_nil
    end

    it "returns nil for a project-defined constant absent from the analyzer process" do
      # MyProject::FOO is not loaded into the analyzer — const_get raises
      # NameError and we fall through to the RBS tier.
      expect(described_class.lookup("MyProject::UNDEFINED_FOO")).to be_nil
    end

    it "returns nil for an empty string constant" do
      stub_const("RIGOR_SPEC_EMPTY_CONST", "")
      expect(described_class.lookup("RIGOR_SPEC_EMPTY_CONST")).to be_nil
    end

    it "returns numeric-string for a constant whose value is all decimal digits" do
      stub_const("RIGOR_SPEC_NUMERIC_CONST", "42")
      expect(described_class.lookup("RIGOR_SPEC_NUMERIC_CONST")).to eq(numeric_string)
    end

    it "returns non-empty-string for a constant whose value has mixed characters" do
      stub_const("RIGOR_SPEC_MIXED_CONST", "v1.2.3")
      expect(described_class.lookup("RIGOR_SPEC_MIXED_CONST")).to eq(non_empty_string)
    end

    it "returns nil for an unknown constant path" do
      expect(described_class.lookup("Nonexistent::CONSTANT")).to be_nil
    end
  end
end
