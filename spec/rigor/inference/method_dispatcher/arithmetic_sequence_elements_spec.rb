# frozen_string_literal: true

require "spec_helper"

# Issue #1794. Every expectation is what CRuby's block-less `step` yields: `1.step(10, 2)` Integers,
# `1.step(10, 0.5)` and `1.step(Float::INFINITY, 2)` Floats, `1.step(10, 2r)` Rationals after the first value.
RSpec.describe Rigor::Inference::MethodDispatcher::ArithmeticSequenceElements do
  def constant_of(value) = Rigor::Type::Combinator.constant_of(value)
  def nominal(name, type_args: []) = Rigor::Type::Combinator.nominal_of(name, type_args: type_args)
  def untyped = Rigor::Type::Combinator.untyped
  def dynamic_numeric = Rigor::Type::Combinator.dynamic(nominal("Numeric"))
  def sequence(element) = nominal("Enumerator::ArithmeticSequence", type_args: [element])

  def step(receiver, args = [], method_name: :step, block_type: nil)
    described_class.try_dispatch(cc(receiver: receiver, method_name: method_name, args: args, block_type: block_type))
  end

  describe ".try_dispatch" do
    it "carries Integer elements when the receiver, limit and step are all Integer" do
      expect(step(constant_of(1), [constant_of(10), constant_of(2)])).to eq(sequence(nominal("Integer")))
      expect(step(nominal("Integer"))).to eq(sequence(nominal("Integer")))
      expect(step(constant_of(1), [constant_of(nil), constant_of(2)])).to eq(sequence(nominal("Integer")))
      by_to = Rigor::Type::Combinator.hash_shape_of(by: constant_of(2), to: constant_of(10))
      expect(step(constant_of(1), [by_to])).to eq(sequence(nominal("Integer")))
    end

    it "carries Dynamic[Numeric] elements when an operand is untyped, since it may be a Float" do
      expect(step(constant_of(1), [untyped, constant_of(2)])).to eq(sequence(dynamic_numeric))
    end

    it "declines to the RBS Numeric elements when an operand is not Integer" do
      expect(step(constant_of(1), [constant_of(10), constant_of(0.5)])).to be_nil
      expect(step(constant_of(1), [constant_of(Float::INFINITY), constant_of(2)])).to be_nil
      expect(step(constant_of(1), [constant_of(10), constant_of(2r)])).to be_nil
      expect(step(constant_of(1.0), [constant_of(10), constant_of(2)])).to be_nil
    end

    it "declines for the block form and for other methods" do
      expect(step(constant_of(1), [constant_of(10)], block_type: untyped)).to be_nil
      expect(step(constant_of(1), [constant_of(10)], method_name: :upto)).to be_nil
    end
  end

  describe ".element_receiver" do
    let(:environment) { Rigor::Environment.default }

    it "reads the element through Enumerator for the inherited surface and the block of its own each" do
      enumerator = nominal("Enumerator", type_args: [nominal("Integer")])
      seq = sequence(nominal("Integer"))
      expect(described_class.element_receiver(seq, :map, environment)).to eq(enumerator)
      expect(described_class.element_receiver(seq, :first, environment)).to eq(enumerator)
      expect(described_class.element_receiver(seq, :each, environment, block: true)).to eq(enumerator)
    end

    it "leaves the sequence's own surface, Object's, and a sequence with no element to the receiver" do
      seq = sequence(nominal("Integer"))
      expect(described_class.element_receiver(seq, :each, environment)).to be_nil
      expect(described_class.element_receiver(seq, :last, environment)).to be_nil
      expect(described_class.element_receiver(seq, :tap, environment)).to be_nil
      expect(described_class.element_receiver(nominal("Enumerator::ArithmeticSequence"), :map, environment)).to be_nil
    end
  end
end
