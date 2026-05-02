# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::IteratorDispatch do
  def constant_of(value) = Rigor::Type::Combinator.constant_of(value)
  def integer_range(low, high) = Rigor::Type::Combinator.integer_range(low, high)
  def integer_nominal = Rigor::Type::Combinator.nominal_of("Integer")
  def positive_int = Rigor::Type::Combinator.positive_int
  def non_negative_int = Rigor::Type::Combinator.non_negative_int

  def block_params(receiver, method_name, args = [])
    described_class.block_param_types(
      receiver: receiver, method_name: method_name, args: args
    )
  end

  describe ".times" do
    it "binds `n.times` to int<0, n-1> for a Constant<Integer> receiver" do
      expect(block_params(constant_of(5), :times)).to eq([integer_range(0, 4)])
    end

    it "collapses 1.times to Constant[0]" do
      expect(block_params(constant_of(1), :times)).to eq([constant_of(0)])
    end

    it "binds Nominal[Integer].times to non_negative_int" do
      expect(block_params(integer_nominal, :times)).to eq([non_negative_int])
    end

    it "binds positive_int.times to non_negative_int" do
      expect(block_params(positive_int, :times)).to eq([non_negative_int])
    end

    it "binds a finite range like int<5, 10>.times to int<0, upper-1>" do
      expect(block_params(integer_range(5, 10), :times)).to eq([integer_range(0, 9)])
    end

    it "is vacuous on 0.times — falls back to non_negative_int" do
      # `0.times` does not iterate; the body still type-checks
      # against a sensible binding.
      expect(block_params(constant_of(0), :times)).to eq([non_negative_int])
    end

    it "is vacuous on a strictly-negative receiver" do
      expect(block_params(constant_of(-3), :times)).to eq([non_negative_int])
    end

    it "declines for non-Integer receivers" do
      expect(block_params(Rigor::Type::Combinator.constant_of("foo"), :times)).to be_nil
      expect(block_params(Rigor::Type::Combinator.nominal_of("Float"), :times)).to be_nil
    end
  end

  describe ".upto" do
    it "binds 3.upto(7) to int<3, 7>" do
      expect(block_params(constant_of(3), :upto, [constant_of(7)])).to eq([integer_range(3, 7)])
    end

    it "collapses 5.upto(5) to Constant[5]" do
      expect(block_params(constant_of(5), :upto, [constant_of(5)])).to eq([constant_of(5)])
    end

    it "uses the receiver lower and arg upper for ranges" do
      # int<-2, 2>.upto(int<3, 5>) -> [int<-2, 5>]
      result = block_params(integer_range(-2, 2), :upto, [integer_range(3, 5)])
      expect(result).to eq([integer_range(-2, 5)])
    end

    it "produces the universal range for two Nominal[Integer]s" do
      result = block_params(integer_nominal, :upto, [integer_nominal])
      expect(result).to eq([Rigor::Type::Combinator.universal_int])
    end

    it "is vacuous when receiver lower exceeds arg upper" do
      # 10.upto(5) doesn't iterate; fallback to non_negative_int.
      expect(block_params(constant_of(10), :upto, [constant_of(5)])).to eq([non_negative_int])
    end

    it "declines when either side is non-Integer" do
      expect(block_params(constant_of(1), :upto, [constant_of("foo")])).to be_nil
      expect(block_params(constant_of("a"), :upto, [constant_of(5)])).to be_nil
    end
  end

  describe ".downto" do
    it "binds 7.downto(3) to int<3, 7>" do
      expect(block_params(constant_of(7), :downto, [constant_of(3)])).to eq([integer_range(3, 7)])
    end

    it "collapses 5.downto(5) to Constant[5]" do
      expect(block_params(constant_of(5), :downto, [constant_of(5)])).to eq([constant_of(5)])
    end

    it "is vacuous when arg exceeds receiver" do
      expect(block_params(constant_of(3), :downto, [constant_of(7)])).to eq([non_negative_int])
    end
  end

  describe ".each_with_index" do
    def nominal(name, type_args: []) = Rigor::Type::Combinator.nominal_of(name, type_args: type_args)
    def tuple(*elements) = Rigor::Type::Combinator.tuple_of(*elements)
    def hash_shape(pairs) = Rigor::Type::Combinator.hash_shape_of(pairs)
    def union_of(*members) = Rigor::Type::Combinator.union(*members)

    it "yields (element, non_negative_int) for Array[T]" do
      receiver = nominal("Array", type_args: [nominal("Integer")])
      expect(block_params(receiver, :each_with_index)).to eq([nominal("Integer"), non_negative_int])
    end

    it "yields (element, non_negative_int) for Set[T]" do
      receiver = nominal("Set", type_args: [nominal("Symbol")])
      expect(block_params(receiver, :each_with_index)).to eq([nominal("Symbol"), non_negative_int])
    end

    it "yields (element, non_negative_int) for Range[T]" do
      receiver = nominal("Range", type_args: [nominal("Integer")])
      expect(block_params(receiver, :each_with_index)).to eq([nominal("Integer"), non_negative_int])
    end

    it "yields (Tuple[K, V], non_negative_int) for Hash[K, V]" do
      receiver = nominal("Hash", type_args: [nominal("Symbol"), nominal("Integer")])
      expect(block_params(receiver, :each_with_index))
        .to eq([tuple(nominal("Symbol"), nominal("Integer")), non_negative_int])
    end

    it "preserves per-position precision for a heterogeneous Tuple" do
      receiver = tuple(constant_of(1), constant_of("a"))
      expect(block_params(receiver, :each_with_index))
        .to eq([union_of(constant_of(1), constant_of("a")), non_negative_int])
    end

    it "yields (Tuple[K, V], non_negative_int) for HashShape" do
      receiver = hash_shape(name: nominal("String"))
      expect(block_params(receiver, :each_with_index))
        .to eq([tuple(constant_of(:name), nominal("String")), non_negative_int])
    end

    it "yields the Constant<Range>'s precise integer-range element" do
      receiver = constant_of(1..5)
      expect(block_params(receiver, :each_with_index)).to eq([integer_range(1, 5), non_negative_int])
    end

    it "declines on receivers it cannot project (Top, Dynamic, raw nominals without type_args)" do
      expect(block_params(Rigor::Type::Combinator.untyped, :each_with_index)).to be_nil
      expect(block_params(nominal("Array"), :each_with_index)).to be_nil
    end
  end

  describe ".each_with_object" do
    def nominal(name, type_args: []) = Rigor::Type::Combinator.nominal_of(name, type_args: type_args)
    def tuple(*elements) = Rigor::Type::Combinator.tuple_of(*elements)

    it "yields (element, memo) where memo is the second-argument type" do
      receiver = nominal("Array", type_args: [nominal("Integer")])
      memo = tuple
      expect(block_params(receiver, :each_with_object, [memo])).to eq([nominal("Integer"), memo])
    end

    it "preserves per-position precision for a heterogeneous Tuple receiver" do
      receiver = Rigor::Type::Combinator.tuple_of(constant_of(1), constant_of("a"))
      memo = nominal("Hash")
      element_union = Rigor::Type::Combinator.union(constant_of(1), constant_of("a"))
      expect(block_params(receiver, :each_with_object, [memo])).to eq([element_union, memo])
    end

    it "declines when the memo arg is missing" do
      receiver = nominal("Array", type_args: [nominal("Integer")])
      expect(block_params(receiver, :each_with_object, [])).to be_nil
    end
  end

  describe ".inject / .reduce" do
    def nominal(name, type_args: []) = Rigor::Type::Combinator.nominal_of(name, type_args: type_args)

    let(:int_array) { nominal("Array", type_args: [nominal("Integer")]) }

    it "with a seed argument: yields (seed, element)" do
      seed = constant_of(0)
      expect(block_params(int_array, :inject, [seed])).to eq([seed, nominal("Integer")])
      expect(block_params(int_array, :reduce, [seed])).to eq([seed, nominal("Integer")])
    end

    it "with no arguments: memo and element both bind to the receiver's element type" do
      expect(block_params(int_array, :inject, [])).to eq([nominal("Integer"), nominal("Integer")])
    end

    it "declines on the Symbol-call form `inject(:+)` (no block)" do
      expect(block_params(int_array, :inject, [constant_of(:+)])).to be_nil
    end

    it "declines on the seed + Symbol form `inject(0, :+)` (no block)" do
      expect(block_params(int_array, :inject, [constant_of(0), constant_of(:+)])).to be_nil
    end

    it "preserves the seed type even when wider than the element" do
      seed = nominal("String")
      expect(block_params(int_array, :inject, [seed])).to eq([seed, nominal("Integer")])
    end
  end

  describe ".group_by / .partition (single-element-yield placeholders)" do
    def nominal(name, type_args: []) = Rigor::Type::Combinator.nominal_of(name, type_args: type_args)
    def tuple(*elements) = Rigor::Type::Combinator.tuple_of(*elements)

    it "yields the receiver's element type as the only block param" do
      receiver = nominal("Array", type_args: [nominal("Integer")])
      expect(block_params(receiver, :group_by)).to eq([nominal("Integer")])
      expect(block_params(receiver, :partition)).to eq([nominal("Integer")])
    end

    it "preserves per-position precision for a Tuple receiver" do
      receiver = tuple(constant_of(:a), constant_of(:b))
      union = Rigor::Type::Combinator.union(constant_of(:a), constant_of(:b))
      expect(block_params(receiver, :group_by)).to eq([union])
      expect(block_params(receiver, :partition)).to eq([union])
    end

    it "yields Tuple[K, V] for a Hash receiver" do
      receiver = nominal("Hash", type_args: [nominal("Symbol"), nominal("Integer")])
      expect(block_params(receiver, :group_by))
        .to eq([tuple(nominal("Symbol"), nominal("Integer"))])
    end

    it "declines for receivers IteratorDispatch cannot project" do
      expect(block_params(Rigor::Type::Combinator.untyped, :group_by)).to be_nil
      expect(block_params(nominal("Array"), :partition)).to be_nil
    end
  end

  describe ".each_slice / .each_cons (Array-yielding placeholders)" do
    def nominal(name, type_args: []) = Rigor::Type::Combinator.nominal_of(name, type_args: type_args)
    def tuple(*elements) = Rigor::Type::Combinator.tuple_of(*elements)

    it "wraps the element type in Array[element] (slice arg ignored)" do
      receiver = nominal("Array", type_args: [nominal("Integer")])
      array_of_integer = nominal("Array", type_args: [nominal("Integer")])
      expect(block_params(receiver, :each_slice, [constant_of(2)])).to eq([array_of_integer])
      expect(block_params(receiver, :each_cons, [constant_of(3)])).to eq([array_of_integer])
    end

    it "preserves per-position precision for a Tuple receiver" do
      receiver = tuple(constant_of(1), constant_of(2), constant_of(3))
      union = Rigor::Type::Combinator.union(constant_of(1), constant_of(2), constant_of(3))
      array_of_union = nominal("Array", type_args: [union])
      expect(block_params(receiver, :each_slice, [constant_of(2)])).to eq([array_of_union])
    end

    it "declines for receivers IteratorDispatch cannot project" do
      expect(block_params(nominal("Array"), :each_slice, [constant_of(2)])).to be_nil
    end
  end

  describe "non-iterator methods" do
    it "declines and lets RBS answer" do
      expect(block_params(constant_of(1), :+, [constant_of(2)])).to be_nil
      expect(block_params(constant_of(5), :each, [])).to be_nil
    end
  end
end
