# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::KernelDispatch do
  def receiver = Rigor::Type::Combinator.nominal_of("Object")
  def nominal(name) = Rigor::Type::Combinator.nominal_of(name)
  def constant_of(value) = Rigor::Type::Combinator.constant_of(value)
  def array_of(*type_args) = Rigor::Type::Combinator.nominal_of("Array", type_args: type_args)
  def tuple_of(*elements) = Rigor::Type::Combinator.tuple_of(*elements)
  def union_of(*members) = Rigor::Type::Combinator.union(*members)

  def dispatch(arg)
    described_class.try_dispatch(receiver: receiver, method_name: :Array, args: [arg])
  end

  describe ".try_dispatch on Kernel#Array" do
    it "wraps a Nominal scalar as Array[Nominal]" do
      expect(dispatch(nominal("Integer"))).to eq(array_of(nominal("Integer")))
    end

    it "preserves the element type when the argument is already Array[E]" do
      expect(dispatch(array_of(nominal("String")))).to eq(array_of(nominal("String")))
    end

    it "treats Constant[nil] as the empty Array (element Bot)" do
      expect(dispatch(constant_of(nil))).to eq(array_of(Rigor::Type::Combinator.bot))
    end

    it "materialises a Tuple as Array[union of elements]" do
      tuple = tuple_of(nominal("Integer"), nominal("String"))
      expect(dispatch(tuple)).to eq(array_of(union_of(nominal("Integer"), nominal("String"))))
    end

    it "distributes across a Union by mapping element_type_of over each member" do
      union = union_of(nominal("Target"), array_of(nominal("Target")))
      expect(dispatch(union)).to eq(array_of(nominal("Target")))
    end

    it "keeps the constant-string element shape (Array(\"x\") -> [\"x\"])" do
      expect(dispatch(constant_of("x"))).to eq(array_of(constant_of("x")))
    end

    it "returns nil for shapes the tier cannot prove (Dynamic, Top, Bot)" do
      expect(dispatch(Rigor::Type::Combinator.untyped)).to be_nil
      expect(dispatch(Rigor::Type::Combinator.top)).to be_nil
      expect(dispatch(Rigor::Type::Combinator.bot)).to be_nil
    end

    it "declines methods other than :Array (Integer with non-refined arg falls through to RBS)" do
      result = described_class.try_dispatch(receiver: receiver, method_name: :Integer, args: [nominal("String")])
      expect(result).to be_nil
    end

    it "declines arities other than 1" do
      two_args = [nominal("String"), nominal("Integer")]
      expect(described_class.try_dispatch(receiver: receiver, method_name: :Array, args: [])).to be_nil
      expect(described_class.try_dispatch(receiver: receiver, method_name: :Array, args: two_args)).to be_nil
    end
  end

  describe ".try_dispatch on Kernel#Integer (v0.1.1 Track 1 slice 2b)" do
    def non_negative_int = Rigor::Type::Combinator.non_negative_int

    def integer_dispatch(arg)
      described_class.try_dispatch(receiver: receiver, method_name: :Integer, args: [arg])
    end

    it "narrows Integer(decimal-int-string) to non-negative-int" do
      expect(integer_dispatch(Rigor::Type::Combinator.decimal_int_string)).to eq(non_negative_int)
    end

    it "narrows Integer(numeric-string) to non-negative-int" do
      expect(integer_dispatch(Rigor::Type::Combinator.numeric_string)).to eq(non_negative_int)
    end

    it "declines on non-digit refinements (lowercase / uppercase / hex)" do
      [
        Rigor::Type::Combinator.lowercase_string,
        Rigor::Type::Combinator.uppercase_string,
        Rigor::Type::Combinator.hex_int_string,
        Rigor::Type::Combinator.octal_int_string
      ].each do |arg|
        expect(integer_dispatch(arg)).to be_nil
      end
    end

    it "declines on plain Nominal[String] (no predicate to lean on)" do
      expect(integer_dispatch(nominal("String"))).to be_nil
    end

    it "declines on `Integer(s, base)` (slice 2b covers no-base form only)" do
      result = described_class.try_dispatch(
        receiver: receiver,
        method_name: :Integer,
        args: [Rigor::Type::Combinator.decimal_int_string, constant_of(10)]
      )
      expect(result).to be_nil
    end
  end
end
