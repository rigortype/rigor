# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::ReduceFolding do
  def constant_of(value) = Rigor::Type::Combinator.constant_of(value)
  def nominal(name, type_args: []) = Rigor::Type::Combinator.nominal_of(name, type_args: type_args)
  def integer = nominal("Integer")
  def string = nominal("String")

  let(:environment) { Rigor::Environment.default }
  let(:int_array) { nominal("Array", type_args: [integer]) }
  let(:str_array) { nominal("Array", type_args: [string]) }
  # `(1..5)` literal types as `Constant[Range]`, the shape this tier sees.
  let(:int_range) { constant_of(1..5) }

  def fold(receiver, method_name, args)
    described_class.try_dispatch(
      cc(receiver: receiver, method_name: method_name, args: args, environment: environment)
    )
  end

  describe "the 2-arg seed form `reduce(seed, :op)`" do
    it "folds `(1..5).reduce(1, :*)` to `Constant[120]` (factorial accumulator)" do
      expect(fold(int_range, :reduce, [constant_of(1), constant_of(:*)])).to eq(constant_of(120))
    end

    it "covers the `inject` alias `[1,2,3].inject(0, :+)`" do
      expect(fold(int_array, :inject, [constant_of(0), constant_of(:+)])).to eq(integer)
    end

    it "widens the seed in the empty-collection join (no `0 | Integer` leak)" do
      expect(fold(int_array, :reduce, [constant_of(0), constant_of(:+)])).to eq(integer)
    end
  end

  describe "the 1-arg no-seed form `reduce(:op)`" do
    it "types `[1,2,3].reduce(:+)` as Integer with no manufactured nil" do
      expect(fold(int_array, :reduce, [constant_of(:+)])).to eq(integer)
    end

    it "types a String-element fold `[\"a\"].reduce(:+)` as String" do
      expect(fold(str_array, :reduce, [constant_of(:+)])).to eq(string)
    end
  end

  describe "constant execution over fully-constant receivers" do
    def tuple(*values)
      Rigor::Type::Tuple.new(values.map { |v| constant_of(v) })
    end

    it "folds `(1..5).reduce(1, :*)` to `Constant[120]`" do
      expect(fold(int_range, :reduce, [constant_of(1), constant_of(:*)]))
        .to eq(constant_of(120))
    end

    it "folds an empty seeded range `(1..0).reduce(1, :*)` to the seed `Constant[1]`" do
      expect(fold(constant_of(1..0), :reduce, [constant_of(1), constant_of(:*)]))
        .to eq(constant_of(1))
    end

    it "folds a Tuple `[1,2,3].reduce(:+)` to `Constant[6]`" do
      expect(fold(tuple(1, 2, 3), :reduce, [constant_of(:+)])).to eq(constant_of(6))
    end

    it "folds a seeded Tuple `[1,2,3].inject(10, :+)` to `Constant[16]`" do
      expect(fold(tuple(1, 2, 3), :inject, [constant_of(10), constant_of(:+)]))
        .to eq(constant_of(16))
    end

    it "folds Float members `[1.5, 2.5].reduce(:+)` to `Constant[4.0]`" do
      expect(fold(tuple(1.5, 2.5), :reduce, [constant_of(:+)])).to eq(constant_of(4.0))
    end

    it "folds `:gcd` over a Tuple `[12, 8].reduce(:gcd)` to `Constant[4]`" do
      expect(fold(tuple(12, 8), :reduce, [constant_of(:gcd)])).to eq(constant_of(4))
    end

    describe "declines and falls through to the nominal fold" do
      it "declines an unbounded range before enumerating (size cap, no `to_a`)" do
        expect(fold(constant_of(1..1_000_000), :reduce, [constant_of(:+)])).to eq(integer)
      end

      it "declines an endless range `(1..)` (constant path declines; nominal path too)" do
        # The constant path declines (no finite size); `element_type_of`
        # on an endless `Constant[Range]` also declines, so the whole
        # tier returns nil — byte-identical to pre-fold behaviour.
        expect(fold(constant_of(1..), :reduce, [constant_of(:+)])).to be_nil
      end

      it "declines on the magnitude cap `(1..64).reduce(:*)` (bignum factorial)" do
        expect(fold(constant_of(1..64), :reduce, [constant_of(:*)])).to eq(integer)
      end

      it "declines a Tuple over the element cap (65 members)" do
        big = Rigor::Type::Tuple.new(Array.new(65) { constant_of(1) })
        expect(fold(big, :reduce, [constant_of(:+)])).to eq(integer)
      end

      it "declines an operator outside the constant allow-list (`:max`)" do
        # `Integer#max` does not exist; the nominal fold also cannot
        # dispatch it, so the whole call declines (nil).
        expect(fold(tuple(1, 2, 3), :reduce, [constant_of(:max)])).to be_nil
      end

      it "declines division by zero (rescue harness)" do
        expect(fold(tuple(1, 0), :reduce, [constant_of(:/)])).to eq(integer)
      end

      it "declines an empty no-seed Tuple (Ruby returns nil; no `Constant[nil]`)" do
        expect(fold(Rigor::Type::Tuple.new([]), :reduce, [constant_of(:+)])).to be_nil
      end

      it "declines a non-Constant seed (range members constant, seed nominal)" do
        # A nominal seed makes the fold non-constant, so the value path
        # declines but the carrier path still answers `Integer`.
        expect(fold(int_range, :reduce, [integer, constant_of(:*)])).to eq(integer)
      end

      it "declines a Tuple with a non-Constant member" do
        mixed = Rigor::Type::Tuple.new([constant_of(1), integer, constant_of(3)])
        expect(fold(mixed, :reduce, [constant_of(:+)])).to eq(integer)
      end
    end
  end

  describe "declines (returns nil → today's Dynamic[top] behaviour)" do
    it "declines when the final argument is not a Symbol" do
      expect(fold(int_array, :reduce, [constant_of(0)])).to be_nil
      expect(fold(int_array, :reduce, [constant_of(0), constant_of(1)])).to be_nil
    end

    it "declines for methods other than reduce / inject" do
      expect(fold(int_array, :sum, [constant_of(:+)])).to be_nil
    end

    it "declines when a block is present (block-fold path owns it)" do
      ctx = cc(receiver: int_array, method_name: :reduce, args: [constant_of(:+)],
               block_type: integer, environment: environment)
      expect(described_class.try_dispatch(ctx)).to be_nil
    end

    it "declines on receivers whose element type cannot be projected" do
      expect(fold(Rigor::Type::Combinator.untyped, :reduce, [constant_of(:+)])).to be_nil
      expect(fold(nominal("Array"), :reduce, [constant_of(:+)])).to be_nil
    end

    it "declines when the operator is not dispatchable on the operand types" do
      sym_array = nominal("Array", type_args: [nominal("Symbol")])
      expect(fold(sym_array, :reduce, [constant_of(:*)])).to be_nil
    end
  end
end
