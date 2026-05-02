# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::Refined do
  def constant_of(value) = Rigor::Type::Combinator.constant_of(value)
  def nominal_of(name, type_args: []) = Rigor::Type::Combinator.nominal_of(name, type_args: type_args)

  describe "construction and equality" do
    it "carries base and predicate_id inner references" do
      r = described_class.new(nominal_of("String"), :lowercase)
      expect(r.base).to eq(nominal_of("String"))
      expect(r.predicate_id).to eq(:lowercase)
    end

    it "is structurally equal to another Refined with the same parts" do
      a = described_class.new(nominal_of("String"), :lowercase)
      b = described_class.new(nominal_of("String"), :lowercase)
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "rejects a non-Symbol predicate_id" do
      expect do
        described_class.new(nominal_of("String"), "lowercase")
      end.to raise_error(ArgumentError, /predicate_id/)
    end

    it "is frozen" do
      expect(described_class.new(nominal_of("String"), :lowercase).frozen?).to be(true)
    end
  end

  describe "canonical-name display" do
    it "renders lowercase-string for Refined[String, :lowercase]" do
      expect(Rigor::Type::Combinator.lowercase_string.describe).to eq("lowercase-string")
    end

    it "renders uppercase-string for Refined[String, :uppercase]" do
      expect(Rigor::Type::Combinator.uppercase_string.describe).to eq("uppercase-string")
    end

    it "renders numeric-string for Refined[String, :numeric]" do
      expect(Rigor::Type::Combinator.numeric_string.describe).to eq("numeric-string")
    end

    it "renders the base-N int-string names for the integer-parse predicates" do
      expect(Rigor::Type::Combinator.decimal_int_string.describe).to eq("decimal-int-string")
      expect(Rigor::Type::Combinator.octal_int_string.describe).to eq("octal-int-string")
      expect(Rigor::Type::Combinator.hex_int_string.describe).to eq("hex-int-string")
    end

    it "falls back to base & predicate? for unrecognised shapes" do
      r = described_class.new(nominal_of("String"), :rare_predicate)
      expect(r.describe).to eq("String & rare_predicate?")
    end
  end

  describe "RBS erasure" do
    it "erases to the base nominal" do
      expect(Rigor::Type::Combinator.lowercase_string.erase_to_rbs).to eq("String")
      expect(Rigor::Type::Combinator.uppercase_string.erase_to_rbs).to eq("String")
      expect(Rigor::Type::Combinator.numeric_string.erase_to_rbs).to eq("String")
      expect(Rigor::Type::Combinator.decimal_int_string.erase_to_rbs).to eq("String")
      expect(Rigor::Type::Combinator.octal_int_string.erase_to_rbs).to eq("String")
      expect(Rigor::Type::Combinator.hex_int_string.erase_to_rbs).to eq("String")
    end
  end

  describe "predicate registry" do
    it "recognises lowercase-string Constants the predicate accepts" do
      r = Rigor::Type::Combinator.lowercase_string
      expect(r.matches?("hello")).to be(true)
      expect(r.matches?("Hello")).to be(false)
      expect(r.matches?("")).to be(true)
    end

    it "recognises uppercase-string Constants the predicate accepts" do
      r = Rigor::Type::Combinator.uppercase_string
      expect(r.matches?("HELLO")).to be(true)
      expect(r.matches?("Hello")).to be(false)
    end

    it "recognises numeric-string Constants the predicate accepts" do
      r = Rigor::Type::Combinator.numeric_string
      expect(r.matches?("42")).to be(true)
      expect(r.matches?("-3.14")).to be(true)
      expect(r.matches?("0xff")).to be(false)
      expect(r.matches?("forty-two")).to be(false)
    end

    it "recognises decimal-int-string with optional sign and no fractional tail" do
      r = Rigor::Type::Combinator.decimal_int_string
      expect(r.matches?("0")).to be(true)
      expect(r.matches?("42")).to be(true)
      expect(r.matches?("-7")).to be(true)
      expect(r.matches?("3.14")).to be(false) # numeric-string but not decimal-int-string
      expect(r.matches?("0xff")).to be(false)
      expect(r.matches?("")).to be(false)
    end

    it "recognises octal-int-string only when the conventional prefix is present" do
      r = Rigor::Type::Combinator.octal_int_string
      expect(r.matches?("0o755")).to be(true)
      expect(r.matches?("0O755")).to be(true)
      expect(r.matches?("0755")).to be(true)
      expect(r.matches?("-0o7")).to be(true)
      expect(r.matches?("755")).to be(false) # bare digits are decimal, not octal
      expect(r.matches?("0o9")).to be(false)
      expect(r.matches?("0xff")).to be(false)
    end

    it "recognises hex-int-string only with the 0x / 0X prefix" do
      r = Rigor::Type::Combinator.hex_int_string
      expect(r.matches?("0xff")).to be(true)
      expect(r.matches?("0XFF")).to be(true)
      expect(r.matches?("-0xCAFE")).to be(true)
      expect(r.matches?("ff")).to be(false)
      expect(r.matches?("0o755")).to be(false)
    end

    it "returns false for non-String values regardless of predicate" do
      expect(Rigor::Type::Combinator.lowercase_string.matches?(:hello)).to be(false)
      expect(Rigor::Type::Combinator.numeric_string.matches?(42)).to be(false)
    end

    it "returns nil when the predicate is not in the registry" do
      r = described_class.new(nominal_of("String"), :unregistered_predicate)
      expect(r.matches?("anything")).to be_nil
    end
  end

  describe "acceptance" do
    let(:lc) { Rigor::Type::Combinator.lowercase_string }
    let(:uc) { Rigor::Type::Combinator.uppercase_string }

    it "accepts a Constant String the predicate matches" do
      expect(lc.accepts(constant_of("hi")).yes?).to be(true)
      expect(lc.accepts(constant_of("")).yes?).to be(true)
    end

    it "rejects a Constant String the predicate does not match" do
      expect(lc.accepts(constant_of("Hi")).no?).to be(true)
      expect(lc.accepts(constant_of("HI")).no?).to be(true)
    end

    it "rejects a Constant of the wrong base type" do
      expect(lc.accepts(constant_of(5)).no?).to be(true)
      expect(lc.accepts(constant_of(:hi)).no?).to be(true)
    end

    it "accepts another Refined with the same predicate" do
      expect(lc.accepts(Rigor::Type::Combinator.lowercase_string).yes?).to be(true)
    end

    it "rejects a Refined with a mismatched predicate even though the bases match" do
      expect(lc.accepts(uc).no?).to be(true)
    end

    it "rejects the universal nominal because it could fail the predicate" do
      expect(lc.accepts(nominal_of("String")).no?).to be(true)
    end
  end
end
