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
    it "types `(1..5).reduce(1, :*)` as Integer (factorial accumulator)" do
      expect(fold(int_range, :reduce, [constant_of(1), constant_of(:*)])).to eq(integer)
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
