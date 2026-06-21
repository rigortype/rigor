# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::Union do
  def constant_of(value) = Rigor::Type::Combinator.constant_of(value)
  def nominal_of(name) = Rigor::Type::Combinator.nominal_of(name)

  describe "construction" do
    it "requires at least two members" do
      expect { described_class.new([nominal_of("String")]) }
        .to raise_error(ArgumentError, /at least two members/)
    end

    it "rejects a non-Array argument" do
      expect { described_class.new(nominal_of("String")) }
        .to raise_error(ArgumentError, /at least two members/)
    end

    it "freezes the members array and the carrier" do
      u = described_class.new([nominal_of("String"), nominal_of("Integer")])
      expect(u.members).to be_frozen
      expect(u).to be_frozen
    end

    it "preserves member order" do
      u = described_class.new([nominal_of("String"), nominal_of("Integer")])
      expect(u.members.map(&:class_name)).to eq(%w[String Integer])
    end
  end

  describe "describe" do
    it "renders a plain union as joined by |" do
      u = described_class.new([nominal_of("String"), nominal_of("Integer")])
      expect(u.describe).to eq("String | Integer")
    end

    it "renders true | false as bool" do
      u = described_class.new([constant_of(true), constant_of(false)])
      expect(u.describe).to eq("bool")
    end

    it "renders T | nil as T?" do
      u = described_class.new([nominal_of("String"), constant_of(nil)])
      expect(u.describe).to eq("String?")
    end

    it "renders bool | nil as bool?" do
      u = described_class.new([constant_of(true), constant_of(false), constant_of(nil)])
      expect(u.describe).to eq("bool?")
    end

    it "renders multi-member nil union without optional sugar" do
      u = described_class.new([nominal_of("String"), nominal_of("Integer"), constant_of(nil)])
      expect(u.describe).to eq("String | Integer | nil")
    end

    it "renders bool pair alongside other types" do
      u = described_class.new([constant_of(true), constant_of(false), nominal_of("Integer")])
      expect(u.describe).to eq("bool | Integer")
    end
  end

  describe "erase_to_rbs" do
    it "joins erased members with |" do
      u = described_class.new([nominal_of("String"), nominal_of("Integer")])
      expect(u.erase_to_rbs).to eq("String | Integer")
    end

    it "deduplicates members that erase to the same RBS string" do
      # Nominal and Refined both erase to the base class name
      ref = Rigor::Type::Combinator.lowercase_string
      u = described_class.new([nominal_of("String"), ref])
      expect(u.erase_to_rbs).to eq("String")
    end

    it "returns untyped when any member erases to untyped" do
      dynamic = Rigor::Type::Combinator.untyped
      u = described_class.new([nominal_of("String"), dynamic])
      expect(u.erase_to_rbs).to eq("untyped")
    end
  end

  describe "capability predicates" do
    it "answers top and bot as no" do
      u = described_class.new([nominal_of("String"), nominal_of("Integer")])
      expect(u.top).to eq(Rigor::Trinary.no)
      expect(u.bot).to eq(Rigor::Trinary.no)
    end

    it "answers dynamic as maybe when any member is dynamic" do
      dynamic = Rigor::Type::Combinator.untyped
      u = described_class.new([nominal_of("String"), dynamic])
      expect(u.dynamic).to eq(Rigor::Trinary.maybe)
    end

    it "answers dynamic as no when no member is dynamic" do
      u = described_class.new([nominal_of("String"), nominal_of("Integer")])
      expect(u.dynamic).to eq(Rigor::Trinary.no)
    end
  end

  describe "inspect" do
    it "includes the short describe form" do
      u = described_class.new([nominal_of("String"), nominal_of("Integer")])
      expect(u.inspect).to eq("#<Rigor::Type::Union String | Integer>")
    end
  end

  describe "value semantics" do
    it "is equal to another Union with the same members in the same order" do
      a = described_class.new([nominal_of("String"), nominal_of("Integer")])
      b = described_class.new([nominal_of("String"), nominal_of("Integer")])
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "differs when the member set differs" do
      a = described_class.new([nominal_of("String"), nominal_of("Integer")])
      b = described_class.new([nominal_of("String"), nominal_of("Float")])
      expect(a).not_to eq(b)
    end
  end

  describe "accepts (via AcceptanceRouter)" do
    it "accepts a member type" do
      u = described_class.new([nominal_of("String"), nominal_of("Integer")])
      expect(u.accepts(constant_of("hi")).yes?).to be(true)
    end

    it "accepts a type that is a subtype of any member" do
      u = described_class.new([nominal_of("String"), nominal_of("Integer")])
      expect(u.accepts(constant_of(5)).yes?).to be(true)
    end

    it "rejects a type outside the union" do
      u = described_class.new([nominal_of("String"), nominal_of("Integer")])
      expect(u.accepts(constant_of(1.5)).no?).to be(true)
    end
  end

  describe "private helpers" do
    describe "boolean_pair?" do
      it "detects when both true and false are members" do
        u = described_class.new([constant_of(true), constant_of(false)])
        expect(u.send(:boolean_pair?)).to be(true)
      end

      it "returns false when only true is present" do
        u = described_class.new([constant_of(true), nominal_of("Integer")])
        expect(u.send(:boolean_pair?)).to be(false)
      end
    end

    describe "nil_literal?" do
      it "detects a Constant[nil] member" do
        u = described_class.new([nominal_of("String"), constant_of(nil)])
        expect(u.send(:nil_literal?, constant_of(nil))).to be(true)
      end

      it "rejects a non-nil Constant" do
        u = described_class.new([nominal_of("String"), nominal_of("Integer")])
        expect(u.send(:nil_literal?, constant_of(5))).to be(false)
      end
    end

    describe "optional?" do
      it "returns true for T | nil" do
        u = described_class.new([nominal_of("String"), constant_of(nil)])
        expect(u.send(:optional?)).to be(true)
      end

      it "returns false for T | U | nil" do
        u = described_class.new([nominal_of("String"), nominal_of("Integer"), constant_of(nil)])
        expect(u.send(:optional?)).to be(false)
      end

      it "returns true for bool | nil (counts bool pair as one)" do
        u = described_class.new([constant_of(true), constant_of(false), constant_of(nil)])
        expect(u.send(:optional?)).to be(true)
      end

      it "returns false when nil is absent" do
        u = described_class.new([nominal_of("String"), nominal_of("Integer")])
        expect(u.send(:optional?)).to be(false)
      end
    end
  end
end
