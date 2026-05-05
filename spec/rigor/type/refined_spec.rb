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

  describe "#complement_predicate_id (v0.0.10 paired-complement registry)" do
    it "returns the registered complement for :lowercase" do
      lc = Rigor::Type::Combinator.lowercase_string
      expect(lc.complement_predicate_id).to eq(:not_lowercase)
    end

    it "is bidirectional — :not_lowercase maps back to :lowercase" do
      not_lc = Rigor::Type::Combinator.non_lowercase_string
      expect(not_lc.complement_predicate_id).to eq(:lowercase)
    end

    it "returns the registered complement for :uppercase" do
      uc = Rigor::Type::Combinator.uppercase_string
      expect(uc.complement_predicate_id).to eq(:not_uppercase)
    end

    it "returns the registered complement for :numeric" do
      ns = Rigor::Type::Combinator.numeric_string
      expect(ns.complement_predicate_id).to eq(:not_numeric)
    end

    it "is bidirectional for the additional pairs" do
      not_uc = Rigor::Type::Combinator.non_uppercase_string
      expect(not_uc.complement_predicate_id).to eq(:uppercase)
      not_num = Rigor::Type::Combinator.non_numeric_string
      expect(not_num.complement_predicate_id).to eq(:numeric)
    end

    it "returns nil for predicates without a registered complement" do
      di = Rigor::Type::Combinator.decimal_int_string
      expect(di.complement_predicate_id).to be_nil
    end
  end

  describe ":literal_string predicate (v0.0.10 F)" do
    let(:lit) { Rigor::Type::Combinator.literal_string }

    it "describes as `literal-string`" do
      expect(lit.describe).to eq("literal-string")
    end

    it "accepts every Constant<String> (constants are implicitly literal)" do
      expect(lit.accepts(constant_of("hello")).yes?).to be(true)
      expect(lit.accepts(constant_of("")).yes?).to be(true)
    end

    it "rejects non-String constants" do
      expect(lit.accepts(constant_of(5)).no?).to be(true)
      expect(lit.accepts(constant_of(:hi)).no?).to be(true)
    end

    it "accepts itself" do
      expect(lit.accepts(Rigor::Type::Combinator.literal_string).yes?).to be(true)
    end

    it "has no registered complement (flow-tracked, no clean inverse)" do
      expect(lit.complement_predicate_id).to be_nil
    end
  end

  describe ":not_lowercase predicate semantics" do
    let(:not_lc) { Rigor::Type::Combinator.non_lowercase_string }

    it "matches strings with at least one non-lowercase character" do
      expect(not_lc.accepts(constant_of("Hi")).yes?).to be(true)
      expect(not_lc.accepts(constant_of("ABC")).yes?).to be(true)
    end

    it "rejects all-lowercase strings (the existing :lowercase set)" do
      expect(not_lc.accepts(constant_of("hi")).no?).to be(true)
      expect(not_lc.accepts(constant_of("")).no?).to be(true)
      expect(not_lc.accepts(constant_of("123")).no?).to be(true)
    end

    it "describes as `non-lowercase-string`" do
      expect(not_lc.describe).to eq("non-lowercase-string")
    end
  end

  describe ":not_uppercase predicate semantics" do
    let(:not_uc) { Rigor::Type::Combinator.non_uppercase_string }

    it "matches strings with at least one non-uppercase character" do
      expect(not_uc.accepts(constant_of("Hi")).yes?).to be(true)
      expect(not_uc.accepts(constant_of("hello")).yes?).to be(true)
    end

    it "rejects all-uppercase strings (the existing :uppercase set)" do
      expect(not_uc.accepts(constant_of("ABC")).no?).to be(true)
      expect(not_uc.accepts(constant_of("")).no?).to be(true)
      expect(not_uc.accepts(constant_of("123")).no?).to be(true)
    end

    it "describes as `non-uppercase-string`" do
      expect(not_uc.describe).to eq("non-uppercase-string")
    end
  end

  describe ":not_numeric predicate semantics" do
    let(:not_num) { Rigor::Type::Combinator.non_numeric_string }

    it "matches strings with at least one non-digit character" do
      expect(not_num.accepts(constant_of("hello")).yes?).to be(true)
      expect(not_num.accepts(constant_of("12a")).yes?).to be(true)
      expect(not_num.accepts(constant_of("")).yes?).to be(true)
    end

    it "rejects strings the numeric-string predicate accepts" do
      expect(not_num.accepts(constant_of("123")).no?).to be(true)
      expect(not_num.accepts(constant_of("-12.5")).no?).to be(true)
    end

    it "describes as `non-numeric-string`" do
      expect(not_num.describe).to eq("non-numeric-string")
    end
  end
end
