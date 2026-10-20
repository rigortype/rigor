# frozen_string_literal: true

require "date"

RSpec.describe Rigor::Type::Constant do
  # Issue #1513 — a Float carrier pins the value, sign of zero included, which Ruby's `==` does not: `0.0 == -0.0`, yet
  # `1.0 / 0.0` and `1.0 / -0.0` differ. A NaN stays equal to itself so equality is reflexive, although `NaN != NaN`.
  describe "equality of Float values (#1513)" do
    def const(value) = described_class.new(value)

    it "tells 0.0 and -0.0 apart" do
      zero = 0.0
      negative_zero = -0.0
      expect(zero).to eq(negative_zero)
      expect(1.0 / zero).not_to eq(1.0 / negative_zero)
      expect(const(zero)).not_to eq(const(negative_zero))
      expect(const(zero)).not_to eql(const(negative_zero))
      expect(const(negative_zero)).to eq(const(-0.0))
      expect(const(zero)).to eq(const(0.0))
    end

    it "keeps NaN equal to NaN with one hash" do
      nan = Float::NAN
      expect(nan).not_to eq(Float::NAN)
      other_nan = -(0.0 / 0.0)
      expect(other_nan.nan?).to be(true)
      expect(const(Float::NAN)).to eq(const(other_nan))
      expect(const(Float::NAN).hash).to eq(const(other_nan).hash)
      expect(const(Float::NAN)).not_to eq(const(0.0))
    end

    it "compares the parts of a Complex the same way" do
      positive = Complex(0.0, 1.0)
      negative = Complex(-0.0, 1.0)
      expect(positive).to eq(negative)
      expect(const(positive)).not_to eq(const(negative))
      expect(const(Complex(1.0, Float::NAN))).to eq(const(Complex(1.0, -(0.0 / 0.0))))
      integral = Complex(1, 2)
      expect(const(integral)).to eq(const(Complex(1, 2)))
    end

    it "keys 0.0 and -0.0 apart and every NaN together, other values as themselves" do
      values = [0.0, -0.0, 0.0, Float::NAN, -(0.0 / 0.0), 1, 1.0]
      unique = values.uniq { |v| described_class.value_key(v) }
      expect(unique.map(&:to_s)).to eq(%w[0.0 -0.0 NaN 1 1.0])
    end
  end

  describe "construction" do
    it "wraps an Integer value" do
      c = described_class.new(42)
      expect(c.value).to eq(42)
    end

    it "wraps a String value as a frozen copy" do
      s = +"hello"
      c = described_class.new(s)
      expect(c.value).to eq("hello")
      expect(c.value).to be_frozen
    end

    it "wraps a Symbol value" do
      c = described_class.new(:foo)
      expect(c.value).to eq(:foo)
    end

    it "wraps true / false / nil" do
      expect(described_class.new(true).value).to be(true)
      expect(described_class.new(false).value).to be(false)
      expect(described_class.new(nil).value).to be_nil
    end

    it "wraps a Date value as a frozen copy" do
      d = Date.new(2026, 6, 1)
      c = described_class.new(d)
      expect(c.value).to eq(Date.new(2026, 6, 1))
      expect(c.value).to be_frozen
    end

    it "wraps a Time value as a frozen copy" do
      t = Time.utc(2026, 6, 1)
      c = described_class.new(t)
      expect(c.value).to eq(Time.utc(2026, 6, 1))
    end

    it "rejects an unsupported class" do
      expect { described_class.new([]) }.to raise_error(ArgumentError, /scalar literals/)
    end

    it "freezes the carrier" do
      expect(described_class.new(42)).to be_frozen
    end
  end

  describe "describe" do
    it "renders an Integer as its string form" do
      expect(described_class.new(42).describe).to eq("42")
    end

    it "renders a String via inspect" do
      expect(described_class.new("hi").describe).to eq('"hi"')
    end

    it "renders a Symbol via inspect" do
      expect(described_class.new(:foo).describe).to eq(":foo")
    end

    it "renders a Date as ISO-8601" do
      d = Date.new(2026, 6, 1)
      expect(described_class.new(d).describe).to eq("2026-06-01")
    end

    it "renders true / false / nil as their inspect form" do
      expect(described_class.new(true).describe).to eq("true")
      expect(described_class.new(false).describe).to eq("false")
      expect(described_class.new(nil).describe).to eq("nil")
    end
  end

  describe "erase_to_rbs" do
    it "erases true to 'true'" do
      expect(described_class.new(true).erase_to_rbs).to eq("true")
    end

    it "erases false to 'false'" do
      expect(described_class.new(false).erase_to_rbs).to eq("false")
    end

    it "erases nil to 'nil'" do
      expect(described_class.new(nil).erase_to_rbs).to eq("nil")
    end

    it "erases an Integer to its decimal representation" do
      expect(described_class.new(42).erase_to_rbs).to eq("42")
      expect(described_class.new(-7).erase_to_rbs).to eq("-7")
    end

    it "erases a Symbol via inspect" do
      expect(described_class.new(:foo).erase_to_rbs).to eq(":foo")
    end

    it "erases a String via inspect" do
      expect(described_class.new("hi").erase_to_rbs).to eq('"hi"')
    end

    it "widen non-RBS-literal scalars to their class name" do
      expect(described_class.new(3.14).erase_to_rbs).to eq("Float")
      expect(described_class.new(Date.new(2026, 6, 1)).erase_to_rbs).to eq("Date")
    end
  end

  describe "capability predicates" do
    it "answers top / bot / dynamic as no" do
      c = described_class.new(42)
      expect(c.top).to eq(Rigor::Trinary.no)
      expect(c.bot).to eq(Rigor::Trinary.no)
      expect(c.dynamic).to eq(Rigor::Trinary.no)
    end
  end

  describe "equality" do
    it "is equal to another Constant with the same value and class" do
      a = described_class.new(42)
      b = described_class.new(42)
      expect(a).to eq(b)
    end

    it "differs when the value differs" do
      expect(described_class.new(42)).not_to eq(described_class.new(99))
    end

    it "has matching hashes for equal values" do
      a = described_class.new(42)
      b = described_class.new(42)
      expect(a.hash).to eq(b.hash)
    end
  end

  describe "inspect" do
    it "includes the short describe form" do
      expect(described_class.new(42).inspect).to eq("#<Rigor::Type::Constant 42>")
    end
  end

  describe "accepts (via AcceptanceRouter)" do
    it "accepts the same value" do
      c = described_class.new(42)
      expect(c.accepts(described_class.new(42)).yes?).to be(true)
    end

    it "rejects a different value" do
      c = described_class.new(42)
      expect(c.accepts(described_class.new(99)).no?).to be(true)
    end
  end
end
