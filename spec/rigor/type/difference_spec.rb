# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::Difference do
  def constant_of(value) = Rigor::Type::Combinator.constant_of(value)
  def nominal_of(name, type_args: []) = Rigor::Type::Combinator.nominal_of(name, type_args: type_args)

  describe "construction and equality" do
    it "carries base and removed inner references" do
      d = described_class.new(nominal_of("String"), constant_of(""))
      expect(d.base).to eq(nominal_of("String"))
      expect(d.removed).to eq(constant_of(""))
    end

    it "is structurally equal to another Difference with the same parts" do
      a = described_class.new(nominal_of("String"), constant_of(""))
      b = described_class.new(nominal_of("String"), constant_of(""))
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "is frozen" do
      expect(described_class.new(nominal_of("String"), constant_of("")).frozen?).to be(true)
    end
  end

  describe "canonical-name display" do
    it "renders non-empty-string for String - \"\"" do
      expect(Rigor::Type::Combinator.non_empty_string.describe).to eq("non-empty-string")
    end

    it "renders non-zero-int for Integer - 0" do
      expect(Rigor::Type::Combinator.non_zero_int.describe).to eq("non-zero-int")
    end

    it "renders non-empty-array[T] preserving the element type" do
      expect(Rigor::Type::Combinator.non_empty_array.describe).to eq("non-empty-array[top]")
      expect(
        Rigor::Type::Combinator.non_empty_array(nominal_of("Integer")).describe
      ).to eq("non-empty-array[Integer]")
    end

    it "renders non-empty-hash[K, V] preserving the key/value types" do
      expect(Rigor::Type::Combinator.non_empty_hash.describe).to eq("non-empty-hash[top, top]")
      expect(
        Rigor::Type::Combinator.non_empty_hash(nominal_of("Symbol"), nominal_of("Integer")).describe
      ).to eq("non-empty-hash[Symbol, Integer]")
    end

    it "falls back to base - removed for unrecognised shapes" do
      d = described_class.new(nominal_of("String"), constant_of("foo"))
      expect(d.describe).to eq('String - "foo"')
    end
  end

  # Subtracting a second value from an existing Difference layers rather than flattening into one multi-removal carrier:
  # the outer Difference keeps the inner one as its base. Display composes — the inner renders by its canonical
  # refinement name, the outer appends the new exclusion.
  describe "repeated subtraction (layering)" do
    it "wraps `(String - \"\") - \"x\"` as a Difference whose base is the inner Difference" do
      inner = Rigor::Type::Combinator.difference(nominal_of("String"), constant_of(""))
      outer = Rigor::Type::Combinator.difference(inner, constant_of("x"))

      expect(outer).to be_a(described_class)
      expect(outer.base).to eq(inner)
      expect(outer.removed).to eq(constant_of("x"))
    end

    it "composes display: inner canonical name minus the outer exclusion" do
      inner = Rigor::Type::Combinator.difference(nominal_of("String"), constant_of(""))
      outer = Rigor::Type::Combinator.difference(inner, constant_of("x"))

      expect(inner.describe).to eq("non-empty-string")
      expect(outer.describe).to eq('non-empty-string - "x"')
    end
  end

  describe "RBS erasure" do
    it "erases to the base nominal" do
      expect(Rigor::Type::Combinator.non_empty_string.erase_to_rbs).to eq("String")
      expect(Rigor::Type::Combinator.non_zero_int.erase_to_rbs).to eq("Integer")
      expect(Rigor::Type::Combinator.non_empty_array.erase_to_rbs).to eq("Array[top]")
    end
  end

  describe "acceptance" do
    let(:nes) { Rigor::Type::Combinator.non_empty_string }

    it "accepts a Constant String not equal to the empty string" do
      expect(nes.accepts(constant_of("hi")).yes?).to be(true)
      expect(nes.accepts(constant_of("a")).yes?).to be(true)
    end

    it "rejects the removed Constant value" do
      expect(nes.accepts(constant_of("")).no?).to be(true)
    end

    it "rejects values of the wrong base type" do
      expect(nes.accepts(constant_of(5)).no?).to be(true)
      expect(nes.accepts(constant_of(:foo)).no?).to be(true)
    end

    it "rejects the universal nominal because it could be the removed value" do
      # `Nominal[String]` includes `""` so the difference cannot accept the wider base.
      expect(nes.accepts(nominal_of("String")).no?).to be(true)
    end
  end

  describe "#dynamic" do
    it "delegates to the base's dynamic verdict (a Trinary)" do
      d = described_class.new(nominal_of("String"), constant_of(""))
      expect(d.dynamic).to be_a(Rigor::Trinary)
    end
  end
end
