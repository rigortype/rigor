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

    it "is no when target is unresolvable but actual's ancestor chain excludes it" do
      # When the target's Ruby class is not loaded (e.g. a stdlib
      # gem like `bigdecimal` that rigor's own process never
      # `require`s) but the actual side IS loaded, the actual's
      # ancestor chain is authoritative. `Integer.ancestors`
      # does not contain "Definitely::Not::A::Real::Class", so
      # the subtype relation is definitively `:no` — not the
      # conservative `:maybe` it used to be. Required to keep
      # the `OverloadSelector` from picking
      # `Integer#+(BigDecimal) -> BigDecimal` over
      # `Integer#+(Integer) -> Integer` when the bigdecimal RBS
      # reopen puts the BigDecimal arm first in the overload
      # list.
      unresolved = Rigor::Type::Combinator.nominal_of("Definitely::Not::A::Real::Class")
      expect(accepts(unresolved, int_nominal)).to be_no
    end

    it "is maybe when neither side resolves to a Ruby class" do
      # Two user-defined classes neither side can load. Without
      # an ancestor chain to fall back on we keep the
      # conservative `:maybe` answer.
      left = Rigor::Type::Combinator.nominal_of("Definitely::Not::A::Real::Class")
      right = Rigor::Type::Combinator.nominal_of("Also::Not::Real")
      expect(accepts(left, right)).to be_maybe
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

  describe "Nominal acceptance of Constant with an unloadable target" do
    # Regression: when `Nominal[BigDecimal]` (target unloadable
    # because rigor's process never requires `bigdecimal`)
    # checks acceptance of `Constant<1>` (value class Integer),
    # the answer MUST be `:no` so the `OverloadSelector` cannot
    # pick `Integer#+(BigDecimal) -> BigDecimal` over
    # `Integer#+(Integer) -> Integer`. Previously this answered
    # `:maybe` (resolve_class fallback) and the BigDecimal arm
    # — which the bigdecimal stdlib RBS reopens at the FRONT
    # of `Integer#+` — won by overload-list position, polluting
    # the inferred type of plain Integer arithmetic.
    it "answers :no when the target is unloadable but the constant's value class excludes it" do
      bd_nominal = Rigor::Type::Combinator.nominal_of("BigDecimal")
      expect(accepts(bd_nominal, int_constant)).to be_no
    end

    it "answers :yes when the target is unloadable but the constant's value class ancestors include it" do
      # `Numeric` IS loadable so this routes through `is_a?` —
      # asserted here to make the assignment of behavior clear:
      # the ancestor fallback only kicks in when the target
      # Ruby class can't be resolved.
      expect(accepts(numeric_nominal, int_constant)).to be_yes
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
      # Both sides unresolvable so the Nominal acceptance can
      # only answer `:maybe` — the ancestor-chain fallback that
      # collapsed the single-unresolved case to `:no` (see the
      # Nominal spec immediately above) needs an authoritative
      # actual side, and a Nominal-vs-Nominal pair where the
      # actual is also user-defined leaves us with no chain to
      # consult. The Union-merge then surfaces that `:maybe`.
      left = Rigor::Type::Combinator.nominal_of("Definitely::Not::A::Real::Class")
      right = Rigor::Type::Combinator.nominal_of("Also::Not::Real")
      union = Rigor::Type::Combinator.union(left, str_nominal)
      expect(accepts(union, right)).to be_maybe
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

    # Parametrized-ancestor projection: `Hash[K, V]` is
    # `Enumerable[[K, V]]` per RBS (`include Enumerable[[K, V]]` in
    # Hash's class body). Without projection the arity check would
    # reject because Hash carries two type_args and Enumerable only
    # one; with projection the actual is rewritten to `Enumerable
    # [Tuple[K, V]]` and the element-wise covariance succeeds.
    # Surfaced on Discourse via `URI.encode_www_form(hash)` calls
    # that the parameter binder previously flagged as type
    # mismatches.
    it "accepts Hash[K, V] against Enumerable[Tuple[K, V]] via ancestor projection" do
      tuple = Rigor::Type::Combinator.tuple_of(
        Rigor::Type::Combinator.nominal_of(Symbol),
        int_nominal
      )
      enum = Rigor::Type::Combinator.nominal_of(Enumerable, type_args: [tuple])
      hash = Rigor::Type::Combinator.nominal_of(
        Hash,
        type_args: [Rigor::Type::Combinator.nominal_of(Symbol), int_nominal]
      )
      expect(accepts(enum, hash)).to be_yes
    end

    it "still rejects Hash[K, V] vs Enumerable[T] when the projected Tuple is rejected" do
      enum_str_pair = Rigor::Type::Combinator.nominal_of(
        Enumerable,
        type_args: [
          Rigor::Type::Combinator.tuple_of(str_nominal, str_nominal)
        ]
      )
      hash_int = Rigor::Type::Combinator.nominal_of(
        Hash,
        type_args: [int_nominal, int_nominal]
      )
      expect(accepts(enum_str_pair, hash_int)).to be_no
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

  describe "HashShape acceptance (Slice 5)" do
    def shape(pairs = nil, **options)
      if pairs.nil?
        pairs = options
        options = {}
      end
      Rigor::Type::Combinator.hash_shape_of(pairs, **options)
    end

    it "accepts a HashShape with the same keys and accepted values (depth covariant)" do
      a = shape(a: numeric_nominal)
      b = shape(a: int_nominal)
      expect(accepts(a, b)).to be_yes
    end

    it "rejects extra known keys when the target shape is closed" do
      a = shape(a: int_nominal)
      b = shape(a: int_nominal, b: str_nominal)
      expect(accepts(a, b)).to be_no
    end

    it "accepts extra known keys when the target shape is open" do
      a = shape({ a: int_nominal }, extra_keys: :open)
      b = shape(a: int_nominal, b: str_nominal)
      expect(accepts(a, b)).to be_yes
    end

    it "rejects a HashShape missing a required key" do
      a = shape(a: int_nominal, b: str_nominal)
      b = shape(a: int_nominal)
      expect(accepts(a, b)).to be_no
    end

    it "allows optional keys to be absent on the right" do
      a = shape({ a: int_nominal, b: str_nominal }, optional_keys: [:b])
      b = shape(a: int_nominal)
      expect(accepts(a, b)).to be_yes
    end

    it "rejects an optional source key for a required target key" do
      a = shape(a: int_nominal)
      b = shape({ a: int_nominal }, optional_keys: [:a])
      expect(accepts(a, b)).to be_no
    end

    it "rejects an open source when the target shape is closed" do
      a = shape(a: int_nominal)
      b = shape({ a: int_nominal }, extra_keys: :open)
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
