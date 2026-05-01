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

  describe "non-iterator methods" do
    it "declines and lets RBS answer" do
      expect(block_params(constant_of(1), :+, [constant_of(2)])).to be_nil
      expect(block_params(constant_of(5), :each, [])).to be_nil
    end
  end
end
