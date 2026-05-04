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

    describe "type_args (Slice 4 phase 2d)" do
      it "defaults to an empty type_args list (raw form)" do
        n = described_class.nominal_of(Array)
        expect(n.type_args).to eq([])
        expect(n.describe).to eq("Array")
        expect(n.erase_to_rbs).to eq("Array")
      end

      it "carries an applied generic in describe and erase_to_rbs" do
        n = described_class.nominal_of(Array, type_args: [described_class.nominal_of(Integer)])
        expect(n.type_args).to eq([described_class.nominal_of(Integer)])
        expect(n.describe).to eq("Array[Integer]")
        expect(n.erase_to_rbs).to eq("Array[Integer]")
      end

      it "renders multiple type_args separated by commas" do
        n = described_class.nominal_of(
          Hash,
          type_args: [described_class.nominal_of(Symbol), described_class.nominal_of(Integer)]
        )
        expect(n.describe).to eq("Hash[Symbol, Integer]")
      end

      it "is structurally distinct from the raw form for the same class" do
        raw = described_class.nominal_of(Array)
        applied = described_class.nominal_of(Array, type_args: [described_class.nominal_of(Integer)])
        expect(raw).not_to eq(applied)
        expect(raw.hash).not_to eq(applied.hash)
      end

      it "is structurally equal across independent constructions" do
        a = described_class.nominal_of(Array, type_args: [described_class.nominal_of(Integer)])
        b = described_class.nominal_of(Array, type_args: [described_class.nominal_of(Integer)])
        expect(a).to eq(b)
        expect(a.hash).to eq(b.hash)
      end

      it "freezes the type_args array" do
        n = described_class.nominal_of(Array, type_args: [described_class.nominal_of(Integer)])
        expect(n.type_args).to be_frozen
      end

      it "rejects non-array type_args" do
        expect { Rigor::Type::Nominal.new("Array", :not_an_array) } # rigor:disable argument-type-mismatch
          .to raise_error(ArgumentError, /type_args must be an Array/)
      end
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
      one = described_class.constant_of(1)
      another_one = described_class.constant_of(1)
      expect(one).to eq(another_one)
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

  describe ".key_of / .value_of (v0.0.7 type functions)" do
    let(:int) { described_class.nominal_of("Integer") }
    let(:str) { described_class.nominal_of("String") }
    let(:sym) { described_class.nominal_of("Symbol") }

    describe "HashShape" do
      let(:shape) do
        described_class.hash_shape_of(name: str, age: int)
      end

      it "key_of projects to a union of Constant<Symbol> for each key" do
        result = described_class.key_of(shape)
        expect(result).to be_a(Rigor::Type::Union)
        expect(result.members.map(&:value).sort).to eq(%i[age name])
      end

      it "value_of projects to a union of the entry types" do
        result = described_class.value_of(shape)
        expect(result).to eq(described_class.union(str, int))
      end

      it "collapses to bot for an empty HashShape" do
        empty = described_class.hash_shape_of({})
        expect(described_class.key_of(empty)).to be_a(Rigor::Type::Bot)
        expect(described_class.value_of(empty)).to be_a(Rigor::Type::Bot)
      end
    end

    describe "Tuple" do
      let(:tuple) { described_class.tuple_of(str, int, sym) }

      it "key_of projects to a union of Constant<Integer> indices" do
        result = described_class.key_of(tuple)
        expect(result.members.map(&:value).sort).to eq([0, 1, 2])
      end

      it "value_of projects to a union of the per-position types" do
        result = described_class.value_of(tuple)
        expect(result).to eq(described_class.union(str, int, sym))
      end

      it "collapses to bot for an empty Tuple" do
        empty = described_class.tuple_of
        expect(described_class.key_of(empty)).to be_a(Rigor::Type::Bot)
        expect(described_class.value_of(empty)).to be_a(Rigor::Type::Bot)
      end
    end

    describe "Nominal[Hash, [K, V]] / Nominal[Array, [E]]" do
      it "key_of(Hash[Symbol, Integer]) is Symbol" do
        h = described_class.nominal_of("Hash", type_args: [sym, int])
        expect(described_class.key_of(h)).to eq(sym)
      end

      it "value_of(Hash[Symbol, Integer]) is Integer" do
        h = described_class.nominal_of("Hash", type_args: [sym, int])
        expect(described_class.value_of(h)).to eq(int)
      end

      it "key_of(Array[String]) is non-negative-int" do
        a = described_class.nominal_of("Array", type_args: [str])
        expect(described_class.key_of(a)).to eq(described_class.non_negative_int)
      end

      it "value_of(Array[String]) is String" do
        a = described_class.nominal_of("Array", type_args: [str])
        expect(described_class.value_of(a)).to eq(str)
      end

      it "untyped Hash / Array fall back to untyped" do
        h = described_class.nominal_of("Hash")
        expect(described_class.key_of(h)).to eq(described_class.untyped)
        expect(described_class.value_of(h)).to eq(described_class.untyped)
      end

      it "other nominal classes project to top" do
        klass = described_class.nominal_of("MyClass")
        expect(described_class.key_of(klass)).to be_a(Rigor::Type::Top)
        expect(described_class.value_of(klass)).to be_a(Rigor::Type::Top)
      end
    end

    describe "Constant scalars" do
      it "key_of(Constant<Range>) projects to non-negative-int for integer ranges" do
        r = described_class.constant_of(1..5)
        expect(described_class.key_of(r)).to eq(described_class.non_negative_int)
      end

      it "value_of(Constant<Range>) projects to the integer range" do
        r = described_class.constant_of(1..5)
        expect(described_class.value_of(r)).to eq(described_class.integer_range(1, 5))
      end

      it "value_of(Constant<Range>) handles exclusive endpoints" do
        r = described_class.constant_of(1...5)
        expect(described_class.value_of(r)).to eq(described_class.integer_range(1, 4))
      end
    end

    describe "Top / Union fallback" do
      it "Top falls through unchanged" do
        expect(described_class.key_of(described_class.top)).to be_a(Rigor::Type::Top)
        expect(described_class.value_of(described_class.top)).to be_a(Rigor::Type::Top)
      end

      it "Union projects to top (no per-member projection in v0.0.7)" do
        u = described_class.union(int, str)
        expect(described_class.key_of(u)).to be_a(Rigor::Type::Top)
      end
    end
  end
end
