# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::BlockFolding do
  def constant_of(value) = Rigor::Type::Combinator.constant_of(value)
  def tuple_of(*elems) = Rigor::Type::Combinator.tuple_of(*elems)
  def array_of(elem) = Rigor::Type::Combinator.nominal_of("Array", type_args: [elem])
  def integer_nominal = Rigor::Type::Combinator.nominal_of("Integer")
  def string_nominal = Rigor::Type::Combinator.nominal_of("String")
  def non_empty_array(elem) = Rigor::Type::Combinator.non_empty_array(elem)
  def hash_shape_of(pairs) = Rigor::Type::Combinator.hash_shape_of(pairs)
  def true_const = constant_of(true)
  def false_const = constant_of(false)
  def bool_union = Rigor::Type::Combinator.union(true_const, false_const)

  def fold(receiver:, method:, block:, args: [])
    described_class.try_fold(
      receiver: receiver, method_name: method, args: args, block_type: block
    )
  end

  describe "filter-shaped folds (block returns Constant[false] → empty)" do
    it "select { false } on a Tuple receiver folds to the empty tuple" do
      result = fold(receiver: tuple_of(constant_of(1), constant_of(2)),
                    method: :select, block: false_const)
      expect(result).to eq(tuple_of)
    end

    it "filter { false } on Array[Integer] folds to the empty tuple" do
      # `filter` is an alias of `select` in Ruby; we cover it explicitly
      # because the dispatcher receives the raw method name.
      result = fold(receiver: array_of(integer_nominal), method: :filter, block: false_const)
      expect(result).to eq(tuple_of)
    end

    it "take_while { false } folds to the empty tuple" do
      result = fold(receiver: array_of(integer_nominal), method: :take_while, block: false_const)
      expect(result).to eq(tuple_of)
    end

    it "drop_while { true } folds to the empty tuple" do
      result = fold(receiver: array_of(integer_nominal), method: :drop_while, block: true_const)
      expect(result).to eq(tuple_of)
    end

    it "reject { true } folds to the empty tuple" do
      result = fold(receiver: array_of(integer_nominal), method: :reject, block: true_const)
      expect(result).to eq(tuple_of)
    end
  end

  describe "filter-shaped folds (block returns Constant[true] → receiver shape)" do
    it "select { true } on Array[T] returns Array[T]" do
      result = fold(receiver: array_of(integer_nominal), method: :select, block: true_const)
      expect(result).to eq(array_of(integer_nominal))
    end

    it "reject { false } on Array[T] returns Array[T]" do
      result = fold(receiver: array_of(integer_nominal), method: :reject, block: false_const)
      expect(result).to eq(array_of(integer_nominal))
    end

    it "take_while { true } on Array[T] returns Array[T]" do
      result = fold(receiver: array_of(integer_nominal), method: :take_while, block: true_const)
      expect(result).to eq(array_of(integer_nominal))
    end

    it "drop_while { false } on Array[T] returns Array[T]" do
      result = fold(receiver: array_of(integer_nominal), method: :drop_while, block: false_const)
      expect(result).to eq(array_of(integer_nominal))
    end

    it "select { true } on a Tuple widens to Array[union] (sub-multisets are unknowable per-position)" do
      tup = tuple_of(integer_nominal, string_nominal)
      result = fold(receiver: tup, method: :select, block: true_const)
      expect(result).to eq(array_of(Rigor::Type::Combinator.union(integer_nominal, string_nominal)))
    end
  end

  describe "any?/all?/none? predicate folds with constant block" do
    it "all? { true } folds to Constant[true] regardless of receiver shape" do
      expect(fold(receiver: array_of(integer_nominal), method: :all?, block: true_const))
        .to eq(true_const)
      expect(fold(receiver: tuple_of, method: :all?, block: true_const)).to eq(true_const)
      expect(fold(receiver: tuple_of(integer_nominal), method: :all?, block: true_const))
        .to eq(true_const)
    end

    it "all? { false } folds to Constant[false] on a non-empty receiver" do
      expect(fold(receiver: tuple_of(integer_nominal), method: :all?, block: false_const))
        .to eq(false_const)
      expect(fold(receiver: non_empty_array(integer_nominal), method: :all?, block: false_const))
        .to eq(false_const)
    end

    it "all? { false } folds to Constant[true] on an empty receiver (vacuous)" do
      expect(fold(receiver: tuple_of, method: :all?, block: false_const)).to eq(true_const)
    end

    it "all? { false } widens to bool when the receiver's emptiness is unknown" do
      expect(fold(receiver: array_of(integer_nominal), method: :all?, block: false_const))
        .to eq(bool_union)
    end

    it "any? { false } folds to Constant[false] regardless of receiver shape" do
      expect(fold(receiver: array_of(integer_nominal), method: :any?, block: false_const))
        .to eq(false_const)
      expect(fold(receiver: tuple_of(integer_nominal), method: :any?, block: false_const))
        .to eq(false_const)
    end

    it "any? { true } folds to Constant[true] on a non-empty receiver" do
      expect(fold(receiver: tuple_of(integer_nominal), method: :any?, block: true_const))
        .to eq(true_const)
      expect(fold(receiver: non_empty_array(integer_nominal), method: :any?, block: true_const))
        .to eq(true_const)
    end

    it "any? { true } folds to Constant[false] on an empty receiver" do
      expect(fold(receiver: tuple_of, method: :any?, block: true_const)).to eq(false_const)
    end

    it "any? { true } widens to bool when receiver emptiness is unknown" do
      expect(fold(receiver: array_of(integer_nominal), method: :any?, block: true_const))
        .to eq(bool_union)
    end

    it "none? { false } folds to Constant[true] regardless of receiver shape" do
      expect(fold(receiver: array_of(integer_nominal), method: :none?, block: false_const))
        .to eq(true_const)
      expect(fold(receiver: tuple_of(integer_nominal), method: :none?, block: false_const))
        .to eq(true_const)
    end

    it "none? { true } folds to Constant[false] on a non-empty receiver" do
      expect(fold(receiver: tuple_of(integer_nominal), method: :none?, block: true_const))
        .to eq(false_const)
    end

    it "none? { true } folds to Constant[true] on an empty receiver" do
      expect(fold(receiver: tuple_of, method: :none?, block: true_const)).to eq(true_const)
    end
  end

  describe "find/detect/find_index/index falsey-block short-circuit" do
    %i[find detect find_index index].each do |method|
      it "folds `#{method} { false }` to Constant[nil]" do
        result = fold(receiver: array_of(integer_nominal), method: method, block: false_const)
        expect(result).to eq(constant_of(nil))
      end

      it "declines on the truthy side (per-position analysis is a future slice)" do
        result = fold(receiver: array_of(integer_nominal), method: method, block: true_const)
        expect(result).to be_nil
      end

      it "declines when called with a positional argument (value-search form)" do
        result = fold(receiver: array_of(integer_nominal), method: method, block: false_const,
                      args: [constant_of(0)])
        expect(result).to be_nil
      end
    end
  end

  describe "count with a block" do
    it "folds count { false } to Constant[0] regardless of receiver shape" do
      expect(fold(receiver: array_of(integer_nominal), method: :count, block: false_const))
        .to eq(constant_of(0))
      expect(fold(receiver: tuple_of(integer_nominal, integer_nominal), method: :count, block: false_const))
        .to eq(constant_of(0))
    end

    it "folds count { true } to Constant[size] on a Tuple receiver" do
      tup = tuple_of(integer_nominal, string_nominal, integer_nominal)
      expect(fold(receiver: tup, method: :count, block: true_const)).to eq(constant_of(3))
    end

    it "folds count { true } to Constant[0] on the empty Tuple" do
      expect(fold(receiver: tuple_of, method: :count, block: true_const)).to eq(constant_of(0))
    end

    it "folds count { true } over a finite-bound Range constant" do
      # `(1..5).count { true }` — the inclusive integer range
      # has 5 elements, so the truthy block sees all of them.
      const_range = constant_of(1..5)
      expect(fold(receiver: const_range, method: :count, block: true_const)).to eq(constant_of(5))
    end

    it "declines count { true } when receiver size is unknown (Array[T])" do
      expect(fold(receiver: array_of(integer_nominal), method: :count, block: true_const))
        .to be_nil
    end

    it "declines when count carries a positional argument (value-count form)" do
      expect(fold(receiver: array_of(integer_nominal), method: :count, block: false_const,
                  args: [constant_of(0)])).to be_nil
    end
  end

  describe "decline cases (return nil so RBS / iterator tier answers)" do
    it "declines when block_type is nil (no block at the call site)" do
      expect(fold(receiver: array_of(integer_nominal), method: :select, block: nil)).to be_nil
    end

    it "declines when block_type is bool_union (block can return either)" do
      result = fold(receiver: array_of(integer_nominal), method: :select, block: bool_union)
      expect(result).to be_nil
    end

    it "declines for unrecognised methods (e.g. map — element-wise re-evaluation belongs to a later slice)" do
      expect(fold(receiver: array_of(integer_nominal), method: :map, block: true_const)).to be_nil
    end

    it "declines when receiver shape is unknown (Top/Dynamic — let RBS answer)" do
      expect(fold(receiver: Rigor::Type::Combinator.top, method: :select, block: true_const))
        .to be_nil
    end

    it "treats Constant[1] as truthy and Constant[nil] as falsey for predicate folds" do
      # Block bodies often produce `Constant[1]` (e.g. `x.tap { 1 }`) or
      # `Constant[nil]`; predicate folds should follow Ruby's
      # truthiness semantics, not require literal true/false.
      expect(fold(receiver: array_of(integer_nominal), method: :all?, block: constant_of(1)))
        .to eq(true_const)
      expect(fold(receiver: array_of(integer_nominal), method: :any?, block: constant_of(nil)))
        .to eq(false_const)
    end
  end
end
