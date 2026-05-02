# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Builtins::ImportedRefinements do
  describe ".lookup" do
    it "resolves the point-removal refinements to their Difference shape" do
      expect(described_class.lookup("non-empty-string"))
        .to eq(Rigor::Type::Combinator.non_empty_string)
      expect(described_class.lookup("non-zero-int"))
        .to eq(Rigor::Type::Combinator.non_zero_int)
      expect(described_class.lookup("non-empty-array"))
        .to eq(Rigor::Type::Combinator.non_empty_array)
      expect(described_class.lookup("non-empty-hash"))
        .to eq(Rigor::Type::Combinator.non_empty_hash)
    end

    it "resolves the IntegerRange-backed refinements" do
      expect(described_class.lookup("positive-int"))
        .to eq(Rigor::Type::Combinator.positive_int)
      expect(described_class.lookup("non-negative-int"))
        .to eq(Rigor::Type::Combinator.non_negative_int)
      expect(described_class.lookup("negative-int"))
        .to eq(Rigor::Type::Combinator.negative_int)
      expect(described_class.lookup("non-positive-int"))
        .to eq(Rigor::Type::Combinator.non_positive_int)
    end

    it "resolves the predicate-subset refinements to their Refined shape" do
      expect(described_class.lookup("lowercase-string"))
        .to eq(Rigor::Type::Combinator.lowercase_string)
      expect(described_class.lookup("uppercase-string"))
        .to eq(Rigor::Type::Combinator.uppercase_string)
      expect(described_class.lookup("numeric-string"))
        .to eq(Rigor::Type::Combinator.numeric_string)
    end

    it "resolves the base-N int-string predicate refinements" do
      expect(described_class.lookup("decimal-int-string"))
        .to eq(Rigor::Type::Combinator.decimal_int_string)
      expect(described_class.lookup("octal-int-string"))
        .to eq(Rigor::Type::Combinator.octal_int_string)
      expect(described_class.lookup("hex-int-string"))
        .to eq(Rigor::Type::Combinator.hex_int_string)
    end

    it "returns nil for an unknown name" do
      expect(described_class.lookup("frobinator-string")).to be_nil
      expect(described_class.lookup("")).to be_nil
    end

    it "accepts symbols as names" do
      expect(described_class.lookup(:"non-empty-string"))
        .to eq(Rigor::Type::Combinator.non_empty_string)
    end
  end

  describe ".known? / .known_names" do
    it "answers .known? truthfully" do
      expect(described_class.known?("non-empty-string")).to be(true)
      expect(described_class.known?("frobinator-string")).to be(false)
    end

    it "lists every catalogued name" do
      expect(described_class.known_names).to include(
        "non-empty-string", "non-zero-int", "non-empty-array",
        "non-empty-hash", "positive-int", "non-negative-int",
        "negative-int", "non-positive-int",
        "lowercase-string", "uppercase-string", "numeric-string",
        "decimal-int-string", "octal-int-string", "hex-int-string"
      )
    end
  end
end
