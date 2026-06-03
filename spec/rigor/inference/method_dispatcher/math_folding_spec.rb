# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::MathFolding do
  def math_singleton = Rigor::Type::Combinator.singleton_of("Math")
  def c(value)       = Rigor::Type::Combinator.constant_of(value)

  def fold(method_name, *arg_types)
    described_class.try_dispatch(cc(
                                   receiver: math_singleton,
                                   method_name: method_name,
                                   args: arg_types
                                 ))
  end

  describe "single-argument transcendental functions" do
    it "folds Math.sqrt on a Float argument" do
      expect(fold(:sqrt, c(4.0))).to eq(c(2.0))
    end

    it "folds Math.sqrt on an Integer argument" do
      expect(fold(:sqrt, c(9))).to eq(c(3.0))
    end

    it "folds Math.cbrt" do
      expect(fold(:cbrt, c(27.0))).to eq(c(3.0))
    end

    it "folds Math.exp" do
      expect(fold(:exp, c(0))).to eq(c(1.0))
    end

    it "folds Math.log2 / Math.log10" do
      expect(fold(:log2, c(8))).to eq(c(3.0))
      expect(fold(:log10, c(1000))).to eq(c(3.0))
    end

    it "folds the trigonometric functions" do
      expect(fold(:sin, c(0))).to eq(c(0.0))
      expect(fold(:cos, c(0))).to eq(c(1.0))
      expect(fold(:tan, c(0))).to eq(c(0.0))
    end

    it "declines on a domain-error input (Math.sqrt(-1))" do
      expect(fold(:sqrt, c(-1))).to be_nil
    end

    it "declines for a non-numeric Constant argument" do
      expect(fold(:sqrt, c("4.0"))).to be_nil
    end

    it "declines for a non-Constant argument" do
      expect(fold(:sqrt, Rigor::Type::Combinator.nominal_of("Float"))).to be_nil
    end

    it "declines when the argument count is wrong" do
      expect(fold(:sqrt, c(4.0), c(2.0))).to be_nil
    end
  end

  describe "two-argument functions" do
    it "folds Math.atan2" do
      expect(fold(:atan2, c(0.0), c(1.0))).to eq(c(0.0))
    end

    it "folds Math.hypot" do
      expect(fold(:hypot, c(3.0), c(4.0))).to eq(c(5.0))
    end

    it "folds Math.ldexp" do
      expect(fold(:ldexp, c(0.5), c(3))).to eq(c(4.0))
    end

    it "declines when only one argument is given" do
      expect(fold(:hypot, c(3.0))).to be_nil
    end
  end

  describe "Math.log (variadic)" do
    it "folds the one-argument form" do
      expect(fold(:log, c(1))).to eq(c(0.0))
    end

    it "folds the two-argument (explicit base) form" do
      expect(fold(:log, c(8), c(2))).to eq(c(3.0))
    end

    it "declines on a domain-error input (Math.log(-1))" do
      expect(fold(:log, c(-1))).to be_nil
    end
  end

  describe "tuple-returning functions" do
    it "lifts Math.frexp to Tuple[Constant[Float], Constant[Integer]]" do
      result = fold(:frexp, c(8.0))
      expect(result).to be_a(Rigor::Type::Tuple)
      expect(result.elements.map(&:value)).to eq([0.5, 4])
    end

    it "lifts Math.lgamma to a two-element Tuple" do
      result = fold(:lgamma, c(1.0))
      expect(result).to be_a(Rigor::Type::Tuple)
      expect(result.elements.size).to eq(2)
      expect(result.elements.last.value).to eq(1)
    end
  end

  describe "dispatch gating" do
    it "declines when the receiver is not the Math singleton" do
      result = described_class.try_dispatch(cc(
                                              receiver: Rigor::Type::Combinator.singleton_of("Shellwords"),
                                              method_name: :sqrt,
                                              args: [c(4.0)]
                                            ))
      expect(result).to be_nil
    end

    it "declines for a method outside the supported set" do
      expect(fold(:no_such_function, c(1.0))).to be_nil
    end
  end
end
