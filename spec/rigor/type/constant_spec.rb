# frozen_string_literal: true

require "date"

RSpec.describe Rigor::Type::Constant do
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
