# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::Acceptance do
  # The acceptance dispatch matrix needs many short-lived type carriers,
  # but they are all immutable flyweights or simple structural objects.
  # Using `let` for each would trip RSpec/MultipleMemoizedHelpers, so we
  # expose them as plain helper methods on the example group. The thin
  # value objects make any per-call construction cost negligible.
  def top = Rigor::Type::Combinator.top
  def bot = Rigor::Type::Combinator.bot
  def dyn_top = Rigor::Type::Combinator.untyped
  def int_nominal = Rigor::Type::Combinator.nominal_of(Integer)
  def str_nominal = Rigor::Type::Combinator.nominal_of(String)
  def numeric_nominal = Rigor::Type::Combinator.nominal_of(Numeric)
  def int_singleton = Rigor::Type::Combinator.singleton_of(Integer)
  def str_singleton = Rigor::Type::Combinator.singleton_of(String)
  def int_constant = Rigor::Type::Combinator.constant_of(1)
  def str_constant = Rigor::Type::Combinator.constant_of("hi")

  def int_or_str
    Rigor::Type::Combinator.union(int_nominal, str_nominal)
  end

  def accepts(self_type, other_type, mode: :gradual)
    described_class.accepts(self_type, other_type, mode: mode)
  end

  describe "Top" do
    it "accepts every other type" do
      [bot, dyn_top, int_nominal, int_singleton, int_constant, int_or_str].each do |other|
        expect(accepts(top, other)).to be_yes
      end
    end
  end

  describe "Bot" do
    it "accepts only Bot" do
      expect(accepts(bot, bot)).to be_yes
      expect(accepts(bot, int_nominal)).to be_no
    end
  end

  describe "Dynamic[T] in gradual mode" do
    it "accepts every concrete type" do
      [int_nominal, int_singleton, int_constant, int_or_str, top].each do |other|
        expect(accepts(dyn_top, other)).to be_yes
      end
    end
  end

  describe "Nominal" do
    it "accepts the exact same nominal" do
      expect(accepts(int_nominal, int_nominal)).to be_yes
    end

    it "accepts a subclass via Ruby hierarchy" do
      # Integer < Numeric
      expect(accepts(numeric_nominal, int_nominal)).to be_yes
    end

    it "rejects an unrelated nominal" do
      expect(accepts(int_nominal, str_nominal)).to be_no
    end

    it "accepts a Constant whose value is_a?(class)" do
      expect(accepts(int_nominal, int_constant)).to be_yes
      expect(accepts(numeric_nominal, int_constant)).to be_yes
    end

    it "rejects a Constant whose value is not_a?(class)" do
      expect(accepts(str_nominal, int_constant)).to be_no
    end

    it "rejects a Singleton" do
      expect(accepts(int_nominal, int_singleton)).to be_no
    end

    it "is maybe when the class name does not resolve to a Ruby class" do
      unresolved = Rigor::Type::Combinator.nominal_of("Definitely::Not::A::Real::Class")
      expect(accepts(unresolved, int_nominal)).to be_maybe
    end
  end

  describe "Singleton" do
    it "accepts the same singleton" do
      expect(accepts(int_singleton, int_singleton)).to be_yes
    end

    it "accepts a singleton of a subclass via Ruby hierarchy" do
      numeric_singleton = Rigor::Type::Combinator.singleton_of(Numeric)
      expect(accepts(numeric_singleton, int_singleton)).to be_yes
    end

    it "rejects a singleton of an unrelated class" do
      expect(accepts(int_singleton, str_singleton)).to be_no
    end

    it "rejects a Nominal (different value kind)" do
      expect(accepts(int_singleton, int_nominal)).to be_no
    end

    it "rejects a Constant" do
      expect(accepts(int_singleton, int_constant)).to be_no
    end
  end

  describe "Constant" do
    it "accepts only structurally equal constants" do
      expect(accepts(int_constant, Rigor::Type::Combinator.constant_of(1))).to be_yes
    end

    it "rejects different values" do
      expect(accepts(int_constant, Rigor::Type::Combinator.constant_of(2))).to be_no
    end

    it "rejects different value classes" do
      expect(accepts(int_constant, Rigor::Type::Combinator.constant_of(1.0))).to be_no
    end

    it "rejects a Nominal carrier" do
      expect(accepts(int_constant, int_nominal)).to be_no
    end
  end

  describe "Union" do
    it "accepts when at least one member accepts" do
      expect(accepts(int_or_str, int_constant)).to be_yes
      expect(accepts(int_or_str, str_constant)).to be_yes
    end

    it "rejects when no member accepts" do
      sym_constant = Rigor::Type::Combinator.constant_of(:foo)
      expect(accepts(int_or_str, sym_constant)).to be_no
    end

    it "is maybe when no member proves yes but some member is maybe" do
      unresolved = Rigor::Type::Combinator.nominal_of("Definitely::Not::A::Real::Class")
      union = Rigor::Type::Combinator.union(unresolved, str_nominal)
      expect(accepts(union, int_nominal)).to be_maybe
    end

    it "self.accepts(Union[A,B]) requires every member to be accepted" do
      union = Rigor::Type::Combinator.union(int_nominal, str_nominal)
      expect(accepts(top, union)).to be_yes
      expect(accepts(int_nominal, union)).to be_no
    end
  end

  describe "Bot/Dynamic short-circuits" do
    it "always accepts Bot regardless of self" do
      [int_nominal, str_nominal, int_constant, int_or_str].each do |self_type|
        expect(accepts(self_type, bot)).to be_yes
      end
    end

    it "accepts a Dynamic argument under gradual mode regardless of self" do
      [int_nominal, str_singleton, int_constant, int_or_str].each do |self_type|
        expect(accepts(self_type, dyn_top)).to be_yes
      end
    end
  end

  describe "modes" do
    it "raises ArgumentError for unsupported modes" do
      expect { accepts(int_nominal, int_constant, mode: :strict) }
        .to raise_error(ArgumentError, /not implemented/)
    end
  end

  describe "generics (Slice 4 phase 2d)" do
    def array_of(*type_args)
      Rigor::Type::Combinator.nominal_of(Array, type_args: type_args)
    end

    it "is lenient when self has no type_args (raw form accepts any instantiation)" do
      raw = Rigor::Type::Combinator.nominal_of(Array)
      applied = array_of(int_nominal)
      expect(accepts(raw, applied)).to be_yes
    end

    it "is maybe when other has no type_args (other is raw, self is applied)" do
      applied = array_of(int_nominal)
      raw = Rigor::Type::Combinator.nominal_of(Array)
      expect(accepts(applied, raw)).to be_maybe
    end

    it "yes when applied generics agree element-wise" do
      a = array_of(int_nominal)
      b = array_of(int_nominal)
      expect(accepts(a, b)).to be_yes
    end

    it "no when applied generics differ on a non-subtype element" do
      a = array_of(int_nominal)
      b = array_of(str_nominal)
      expect(accepts(a, b)).to be_no
    end

    it "yes when an element is covariantly accepted (Numeric accepts Integer)" do
      a = array_of(numeric_nominal)
      b = array_of(int_nominal)
      expect(accepts(a, b)).to be_yes
    end

    it "no on type_args arity mismatch" do
      a = array_of(int_nominal)
      b = array_of(int_nominal, str_nominal)
      expect(accepts(a, b)).to be_no
    end

    it "still rejects when the class names disagree" do
      a = array_of(int_nominal)
      b = Rigor::Type::Combinator.nominal_of(Hash, type_args: [int_nominal])
      expect(accepts(a, b)).to be_no
    end
  end

  describe "Tuple acceptance (Slice 5 phase 1)" do
    def tuple_of(*elems)
      Rigor::Type::Combinator.tuple_of(*elems)
    end

    it "accepts Tuple of equal arity element-wise (covariant)" do
      a = tuple_of(numeric_nominal, str_nominal)
      b = tuple_of(int_nominal, str_nominal)
      expect(accepts(a, b)).to be_yes
    end

    it "rejects Tuple of mismatched arity" do
      a = tuple_of(int_nominal, str_nominal)
      b = tuple_of(int_nominal)
      expect(accepts(a, b)).to be_no
    end

    it "rejects non-Tuple values" do
      a = tuple_of(int_nominal)
      expect(accepts(a, int_nominal)).to be_no
      expect(accepts(a, Rigor::Type::Combinator.nominal_of(Array))).to be_no
    end

    it "Nominal[Array] accepts a Tuple via projection" do
      array_raw = Rigor::Type::Combinator.nominal_of(Array)
      tup = tuple_of(int_constant, str_constant)
      expect(accepts(array_raw, tup)).to be_yes
    end

    it "Nominal[Array, [union]] accepts Tuple element-wise via projection" do
      array_int = Rigor::Type::Combinator.nominal_of(Array, type_args: [int_nominal])
      tup = tuple_of(int_constant, Rigor::Type::Combinator.constant_of(2))
      expect(accepts(array_int, tup)).to be_yes
    end
  end

  describe "HashShape acceptance (Slice 5 phase 1)" do
    def shape(pairs)
      Rigor::Type::Combinator.hash_shape_of(pairs)
    end

    it "accepts a HashShape with the same keys and accepted values (depth covariant)" do
      a = shape(a: numeric_nominal)
      b = shape(a: int_nominal)
      expect(accepts(a, b)).to be_yes
    end

    it "accepts a HashShape with extra keys on the right (width permissive)" do
      a = shape(a: int_nominal)
      b = shape(a: int_nominal, b: str_nominal)
      expect(accepts(a, b)).to be_yes
    end

    it "rejects a HashShape missing a required key" do
      a = shape(a: int_nominal, b: str_nominal)
      b = shape(a: int_nominal)
      expect(accepts(a, b)).to be_no
    end

    it "rejects non-HashShape values" do
      a = shape(a: int_nominal)
      expect(accepts(a, Rigor::Type::Combinator.nominal_of(Hash))).to be_no
    end

    it "Nominal[Hash] accepts a HashShape via projection" do
      hash_raw = Rigor::Type::Combinator.nominal_of(Hash)
      sh = shape(a: int_constant, b: str_constant)
      expect(accepts(hash_raw, sh)).to be_yes
    end

    it "Nominal[Hash, [Symbol, Integer]] accepts HashShape with symbol keys and integer values" do
      hash_int = Rigor::Type::Combinator.nominal_of(
        Hash,
        type_args: [Rigor::Type::Combinator.nominal_of(Symbol), int_nominal]
      )
      sh = shape(a: int_constant, b: Rigor::Type::Combinator.constant_of(2))
      expect(accepts(hash_int, sh)).to be_yes
    end
  end

  describe "Type#accepts public surface" do
    it "every type form exposes accepts as a public method" do
      [top, bot, dyn_top, int_nominal, int_singleton, int_constant, int_or_str].each do |t|
        expect(t).to respond_to(:accepts)
        result = t.accepts(int_constant)
        expect(result).to be_a(Rigor::Type::AcceptsResult)
      end
    end

    it "delegates to Acceptance.accepts with the same mode" do
      result = int_nominal.accepts(int_constant)
      expect(result).to be_yes
      expect(result.mode).to eq(:gradual)
    end
  end
end
