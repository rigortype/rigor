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

  # The empty witness of a collection refinement is itself a shape (`Tuple[]`, the closed `{}`), so a
  # shape argument proves disjointness structurally — a fixed arity other than zero, a key the witness
  # cannot hold — where a `Constant` would compare values. Each accept is paired with the neighbouring
  # shape that still overlaps the witness, so the proof cannot pass by accepting every shape.
  describe "acceptance of shapes that exclude the empty witness" do
    let(:integer) { nominal_of("Integer") }
    let(:symbol) { nominal_of("Symbol") }

    def tuple(elements) = Rigor::Type::Tuple.new(elements)
    def hash_shape(pairs, **policy) = Rigor::Type::HashShape.new(pairs, **policy)

    describe "non-empty-array[T]" do
      let(:nea) { Rigor::Type::Combinator.non_empty_array(integer) }

      it "accepts a Tuple of non-zero arity whose elements the base accepts" do
        expect(nea.accepts(tuple([constant_of(1), constant_of(2), constant_of(3)])).yes?).to be(true)
        expect(nea.accepts(tuple([integer])).yes?).to be(true)
      end

      it "accepts a Union of non-empty Tuples" do
        union = Rigor::Type::Combinator.union(tuple([constant_of(1)]), tuple([constant_of(2), constant_of(3)]))
        expect(nea.accepts(union).yes?).to be(true)
      end

      it "rejects the zero-arity Tuple, which is the removed value" do
        expect(nea.accepts(tuple([])).no?).to be(true)
      end

      it "rejects a Union that has the zero-arity Tuple as a member" do
        union = Rigor::Type::Combinator.union(tuple([constant_of(1)]), tuple([]))
        expect(nea.accepts(union).no?).to be(true)
      end

      it "still rejects a non-empty Tuple whose elements the base rejects" do
        expect(nea.accepts(tuple([constant_of("a")])).no?).to be(true)
      end

      it "still rejects the base nominal, which holds the empty array" do
        expect(nea.accepts(nominal_of("Array", type_args: [integer])).no?).to be(true)
      end
    end

    describe "non-empty-hash[K, V]" do
      let(:neh) { Rigor::Type::Combinator.non_empty_hash(symbol, integer) }

      it "accepts a HashShape with a required key" do
        expect(neh.accepts(hash_shape({ name: constant_of(1) })).yes?).to be(true)
      end

      it "does not reject an open HashShape with a required key" do
        # Extra keys only add entries; the required one alone keeps every inhabitant non-empty. Asserted as
        # "not no" because the verdict on the untyped extra entries belongs to the base's Hash acceptance.
        expect(neh.accepts(hash_shape({ name: constant_of(1) }, extra_keys: :open)).no?).to be(false)
      end

      it "rejects the closed empty HashShape, which is the removed value" do
        expect(neh.accepts(hash_shape({})).no?).to be(true)
      end

      it "rejects a HashShape whose every key is optional" do
        # `{ ?name: 1 }` is inhabited by `{}`.
        expect(neh.accepts(hash_shape({ name: constant_of(1) }, optional_keys: [:name])).no?).to be(true)
      end

      it "rejects an open HashShape with no required key" do
        expect(neh.accepts(hash_shape({}, extra_keys: :open)).no?).to be(true)
      end

      it "still rejects a HashShape whose entries the base rejects" do
        expect(neh.accepts(hash_shape({ name: constant_of("a") })).no?).to be(true)
      end
    end

    # The same proofs against removed shapes other than the empty witness, which `T - U` can spell. They pin
    # what each arm compares: the Tuple arm the two arities, the HashShape arm the removed shape's closedness
    # and listed keys.
    describe "against a removed shape other than the empty witness" do
      def difference(base, removed) = Rigor::Type::Combinator.difference(base, removed)

      it "accepts a Tuple of another arity and rejects one of the removed arity" do
        minus_one_slot = difference(nominal_of("Array", type_args: [integer]), tuple([integer]))
        expect(minus_one_slot.accepts(tuple([constant_of(1), constant_of(2)])).yes?).to be(true)
        expect(minus_one_slot.accepts(tuple([constant_of(1)])).no?).to be(true)
      end

      it "accepts a required key a closed removed shape does not list and rejects one it does" do
        minus_a = difference(nominal_of("Hash", type_args: [symbol, integer]), hash_shape({ a: integer }))
        expect(minus_a.accepts(hash_shape({ b: constant_of(1) })).yes?).to be(true)
        expect(minus_a.accepts(hash_shape({ a: constant_of(1) })).no?).to be(true)
      end

      it "rejects any required key when the removed shape is open" do
        # `{ a: Integer, ... }` holds every hash with an Integer `:a`, whatever else it carries — `{ a: 1, b: 1 }`
        # included — so a shape requiring `:b` still overlaps it.
        open_minus_a = difference(
          nominal_of("Hash", type_args: [symbol, integer]),
          hash_shape({ a: integer }, extra_keys: :open)
        )
        expect(open_minus_a.accepts(hash_shape({ b: constant_of(1) })).no?).to be(true)
      end
    end

    describe "non-zero-int" do
      let(:nzi) { Rigor::Type::Combinator.non_zero_int }

      it "accepts an IntegerRange that does not cover zero" do
        expect(nzi.accepts(Rigor::Type::Combinator.positive_int).yes?).to be(true)
        expect(nzi.accepts(Rigor::Type::Combinator.integer_range(-5, -1)).yes?).to be(true)
      end

      it "rejects an IntegerRange that covers zero" do
        expect(nzi.accepts(Rigor::Type::Combinator.integer_range(0, 5)).no?).to be(true)
        expect(nzi.accepts(Rigor::Type::Combinator.integer_range(-1, 1)).no?).to be(true)
      end

      it "proves nothing against a non-Integer removed value, as the Constant arm counts 0 == 0.0" do
        minus_float_zero = Rigor::Type::Combinator.difference(integer, constant_of(0.0))
        expect(minus_float_zero.accepts(constant_of(0)).no?).to be(true)
        expect(minus_float_zero.accepts(Rigor::Type::Combinator.integer_range(-1, 1)).no?).to be(true)
      end
    end
  end

  describe "#dynamic" do
    it "delegates to the base's dynamic verdict (a Trinary)" do
      d = described_class.new(nominal_of("String"), constant_of(""))
      expect(d.dynamic).to be_a(Rigor::Trinary)
    end
  end
end
