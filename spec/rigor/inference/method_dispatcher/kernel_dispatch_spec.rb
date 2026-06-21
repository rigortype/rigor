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
    described_class.try_dispatch(cc(receiver: receiver, method_name: :Array, args: [arg]))
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
      result = described_class.try_dispatch(cc(receiver: receiver, method_name: :Integer, args: [nominal("String")]))
      expect(result).to be_nil
    end

    it "declines arities other than 1" do
      two_args = [nominal("String"), nominal("Integer")]
      expect(described_class.try_dispatch(cc(receiver: receiver, method_name: :Array, args: []))).to be_nil
      expect(described_class.try_dispatch(cc(receiver: receiver, method_name: :Array, args: two_args))).to be_nil
    end
  end

  describe ".try_dispatch on Kernel#Integer (v0.1.1 Track 1 slice 2b)" do
    def universal_int = Rigor::Type::Combinator.universal_int

    def integer_dispatch(arg)
      described_class.try_dispatch(cc(receiver: receiver, method_name: :Integer, args: [arg]))
    end

    it "narrows Integer(decimal-int-string) to universal-int (signed: `\"-7\"` parses to -7)" do
      # The decimal-int-string predicate `/\A-?\d+\z/` admits a leading
      # sign, so `Integer("-7") == -7 < 0` — the result is a plain
      # Integer, NOT non-negative-int. `Integer()` is total over the
      # carrier, so the (signed) IntegerRange is sound.
      expect(integer_dispatch(Rigor::Type::Combinator.decimal_int_string)).to eq(universal_int)
    end

    it "declines Integer(numeric-string) — the widened grammar is not Integer-total nor non-negative" do
      # numeric-string now covers the full Ruby numeric-literal grammar
      # (`1.5`, `2i`, `-3`, …), so Integer(numeric_string) may raise or
      # be negative — narrowing it to non-negative-int would be unsound.
      expect(integer_dispatch(Rigor::Type::Combinator.numeric_string)).to be_nil
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

    it "declines on `Integer(refined-string, base)` (refinement path is no-base only)" do
      result = described_class.try_dispatch(cc(
                                              receiver: receiver,
                                              method_name: :Integer,
                                              args: [Rigor::Type::Combinator.decimal_int_string, constant_of(10)]
                                            ))
      expect(result).to be_nil
    end
  end

  describe ".try_dispatch on Kernel#Integer / Kernel#Float (constant folding)" do
    def kernel_dispatch(method_name, *args)
      described_class.try_dispatch(cc(receiver: receiver, method_name: method_name, args: args))
    end

    it "folds Integer() on a constant string" do
      expect(kernel_dispatch(:Integer, constant_of("42"))).to eq(constant_of(42))
      expect(kernel_dispatch(:Integer, constant_of("  -7  "))).to eq(constant_of(-7))
    end

    it "folds Integer() with an explicit base" do
      expect(kernel_dispatch(:Integer, constant_of("ff"), constant_of(16))).to eq(constant_of(255))
    end

    it "folds Integer() on a constant numeric (truncating a Float)" do
      expect(kernel_dispatch(:Integer, constant_of(3.7))).to eq(constant_of(3))
    end

    it "declines Integer() on an unparseable string" do
      expect(kernel_dispatch(:Integer, constant_of("not a number"))).to be_nil
    end

    it "declines Integer() on a non-string / non-numeric constant" do
      expect(kernel_dispatch(:Integer, constant_of(nil))).to be_nil
    end

    it "folds Float() on a constant string or numeric" do
      expect(kernel_dispatch(:Float, constant_of("3.14"))).to eq(constant_of(3.14))
      expect(kernel_dispatch(:Float, constant_of(42))).to eq(constant_of(42.0))
    end

    it "declines Float() on an unparseable string" do
      expect(kernel_dispatch(:Float, constant_of("abc"))).to be_nil
    end
  end

  describe ".try_dispatch on Kernel#Rational / #Complex" do
    def numeric_kernel(method_name, *args)
      described_class.try_dispatch(
        cc(receiver: receiver, method_name: method_name, args: args.map { |a| constant_of(a) })
      )
    end

    it "folds Rational(num, den) with Ruby normalisation (2/4 -> 1/2)" do
      expect(numeric_kernel(:Rational, 2, 4).value).to eq(Rational(1, 2))
    end

    it "folds Complex(re, im) and the single-arg form" do
      expect(numeric_kernel(:Complex, 1, 2).value).to eq(Complex(1, 2))
      expect(numeric_kernel(:Complex, 3).value).to eq(Complex(3))
    end

    it "accepts Float / Rational / Complex constant args, not only Integer" do
      # Exercises each arm of numeric_constant?'s value-class `||` chain;
      # the Integer args above short-circuit before reaching them.
      expect(numeric_kernel(:Complex, 1.5, 2.5).value).to eq(Complex(1.5, 2.5))
      expect(numeric_kernel(:Complex, Rational(1, 2), Rational(3, 4)).value)
        .to eq(Complex(Rational(1, 2), Rational(3, 4)))
      expect(numeric_kernel(:Complex, Complex(1, 2)).value).to eq(Complex(1, 2))
    end

    it "declines when an argument is not a numeric Constant" do
      expect(numeric_kernel(:Rational, "x")).to be_nil
    end

    it "declines arities other than 1 or 2" do
      expect(numeric_kernel(:Rational, 1, 2, 3)).to be_nil
    end
  end
end
