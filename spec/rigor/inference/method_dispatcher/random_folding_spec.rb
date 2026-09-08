# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::RandomFolding do
  def random_singleton = Rigor::Type::Combinator.singleton_of("Random")
  def c(value) = Rigor::Type::Combinator.constant_of(value)

  def float_range(min, max, exclude_end: false)
    Rigor::Type::Combinator.float_range(min, max, exclude_end: exclude_end)
  end

  def integer_range(min, max) = Rigor::Type::Combinator.integer_range(min, max)

  def fold(*arg_types, receiver: random_singleton, method_name: :rand)
    described_class.try_dispatch(cc(receiver: receiver, method_name: method_name, args: arg_types))
  end

  it "folds a literal range to itself, keeping the class and the written end" do
    expect(fold(c(1..6))).to eq(integer_range(1, 6))
    expect(fold(c(1...6))).to eq(integer_range(1, 5))
    expect(fold(c(0.0...1.0))).to eq(float_range(0.0, 1.0, exclude_end: true))
    expect(fold(c(1.0..2.0))).to eq(float_range(1.0, 2.0))
    expect(fold(c(1..2.5))).to eq(float_range(1.0, 2.5))
  end

  it "declines an empty, unbounded, or non-finite range" do
    expect(fold(c(5..1))).to be_nil
    expect(fold(c(1...1))).to be_nil
    expect(fold(c(1..))).to be_nil
    expect(fold(c(..1.0))).to be_nil
    expect(fold(c(0.0..Float::INFINITY))).to be_nil
  end

  it "leaves the other argument shapes to the RBS tier: the corpus reads them as its unknown-value oracle" do
    expect(fold).to be_nil
    expect(fold(c(6))).to be_nil
    expect(fold(c(1.5))).to be_nil
    expect(fold(c(nil))).to be_nil
    expect(fold(Rigor::Type::Combinator.nominal_of("Range", type_args: [Rigor::Type::Combinator.nominal_of("Integer")])))
      .to be_nil
    expect(fold(c(1..6), c(7))).to be_nil
  end

  it "answers only Singleton[Random]#rand" do
    expect(fold(c(1..6), receiver: Rigor::Type::Combinator.singleton_of("Math"))).to be_nil
    expect(fold(c(1..6), method_name: :bytes)).to be_nil
  end
end
