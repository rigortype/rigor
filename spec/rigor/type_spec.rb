# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Type::Combinator do
  describe ".top" do
    it "is a flyweight" do
      expect(described_class.top).to equal(described_class.top)
    end

    it "describes as 'top' and erases to 'top'" do
      expect(described_class.top.describe).to eq("top")
      expect(described_class.top.erase_to_rbs).to eq("top")
    end
  end

  describe ".bot" do
    it "is a flyweight" do
      expect(described_class.bot).to equal(described_class.bot)
    end

    it "describes as 'bot' and erases to 'bot'" do
      expect(described_class.bot.describe).to eq("bot")
      expect(described_class.bot.erase_to_rbs).to eq("bot")
    end
  end

  describe ".untyped" do
    it "is a flyweight Dynamic[Top]" do
      expect(described_class.untyped).to equal(described_class.untyped)
      expect(described_class.untyped.describe).to eq("Dynamic[top]")
      expect(described_class.untyped.erase_to_rbs).to eq("untyped")
    end
  end

  describe ".dynamic" do
    it "wraps the static facet" do
      facet = described_class.nominal_of(Integer)
      d = described_class.dynamic(facet)
      expect(d.describe).to eq("Dynamic[Integer]")
      expect(d.erase_to_rbs).to eq("untyped")
    end

    it "collapses Dynamic[Top] to the canonical untyped flyweight" do
      expect(described_class.dynamic(described_class.top)).to equal(described_class.untyped)
    end

    it "collapses Dynamic[Dynamic[T]] to Dynamic[T]" do
      inner = described_class.nominal_of(String)
      once = described_class.dynamic(inner)
      twice = described_class.dynamic(once)
      expect(twice).to eq(once)
    end
  end

  describe ".nominal_of" do
    it "accepts Class objects" do
      n = described_class.nominal_of(Integer)
      expect(n.class_name).to eq("Integer")
      expect(n.describe).to eq("Integer")
      expect(n.erase_to_rbs).to eq("Integer")
    end

    it "accepts class-name strings" do
      expect(described_class.nominal_of("MyClass").describe).to eq("MyClass")
    end

    it "rejects anonymous classes" do
      anon = Class.new
      expect { described_class.nominal_of(anon) }.to raise_error(ArgumentError)
    end
  end

  describe ".singleton_of" do
    it "accepts Class/Module objects" do
      s = described_class.singleton_of(Integer)
      expect(s).to be_a(Rigor::Type::Singleton)
      expect(s.class_name).to eq("Integer")
      expect(s.describe).to eq("singleton(Integer)")
      expect(s.erase_to_rbs).to eq("singleton(Integer)")
    end

    it "accepts class-name strings" do
      expect(described_class.singleton_of("MyClass").describe).to eq("singleton(MyClass)")
    end

    it "rejects anonymous classes" do
      anon = Class.new
      expect { described_class.singleton_of(anon) }.to raise_error(ArgumentError)
    end

    it "is structurally distinct from Nominal even for the same class name" do
      n = described_class.nominal_of("Foo")
      s = described_class.singleton_of("Foo")
      expect(s).not_to eq(n)
      expect(n).not_to eq(s)
    end

    it "compares structurally across independent constructions" do
      a = described_class.singleton_of("Foo")
      b = described_class.singleton_of("Foo")
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "answers top/bot/dynamic with Trinary.no" do
      s = described_class.singleton_of("Foo")
      expect(s.top).to eq(Rigor::Trinary.no)
      expect(s.bot).to eq(Rigor::Trinary.no)
      expect(s.dynamic).to eq(Rigor::Trinary.no)
    end
  end

  describe ".constant_of" do
    it "wraps scalar literals" do
      expect(described_class.constant_of(1).describe).to eq("1")
      expect(described_class.constant_of(2.5).describe).to eq("2.5")
      expect(described_class.constant_of("hi").describe).to eq('"hi"')
      expect(described_class.constant_of(:foo).describe).to eq(":foo")
      expect(described_class.constant_of(true).describe).to eq("true")
      expect(described_class.constant_of(false).describe).to eq("false")
      expect(described_class.constant_of(nil).describe).to eq("nil")
    end

    it "erases to the underlying class name (or RBS literal for true/false/nil)" do
      expect(described_class.constant_of(1).erase_to_rbs).to eq("Integer")
      expect(described_class.constant_of("hi").erase_to_rbs).to eq("String")
      expect(described_class.constant_of(:foo).erase_to_rbs).to eq("Symbol")
      expect(described_class.constant_of(true).erase_to_rbs).to eq("true")
      expect(described_class.constant_of(false).erase_to_rbs).to eq("false")
      expect(described_class.constant_of(nil).erase_to_rbs).to eq("nil")
    end

    it "rejects compound literals" do
      expect { described_class.constant_of([1, 2]) }.to raise_error(ArgumentError)
      expect { described_class.constant_of({}) }.to raise_error(ArgumentError)
    end

    it "compares structurally including value class" do
      expect(described_class.constant_of(1)).to eq(described_class.constant_of(1))
      expect(described_class.constant_of(1)).not_to eq(described_class.constant_of(1.0))
      expect(described_class.constant_of("a")).not_to eq(described_class.constant_of(:a))
    end
  end

  describe ".union" do
    let(:int) { described_class.constant_of(1) }
    let(:str) { described_class.constant_of("hi") }
    let(:sym) { described_class.constant_of(:foo) }

    it "collapses to bot when no members" do
      expect(described_class.union).to equal(described_class.bot)
    end

    it "collapses to the single member" do
      expect(described_class.union(int)).to eq(int)
    end

    it "drops bot members" do
      expect(described_class.union(int, described_class.bot)).to eq(int)
    end

    it "absorbs into top" do
      expect(described_class.union(int, described_class.top)).to equal(described_class.top)
    end

    it "deduplicates structurally equal members" do
      a = described_class.constant_of(1)
      b = described_class.constant_of(1)
      expect(described_class.union(a, b)).to eq(a)
    end

    it "flattens nested unions and sorts deterministically" do
      u1 = described_class.union(int, str)
      u2 = described_class.union(u1, sym)
      expect(u2.describe).to eq([int, str, sym].map { |t| t.describe(:short) }.sort.join(" | "))
    end

    it "produces structurally equal results regardless of input order" do
      a = described_class.union(int, str, sym)
      b = described_class.union(sym, int, str)
      expect(a).to eq(b)
    end
  end
end
