# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::LiteralStringFolding do
  let(:literal_string) { Rigor::Type::Combinator.literal_string }
  let(:string_const) { Rigor::Type::Combinator.constant_of("hi") }
  let(:int_const) { Rigor::Type::Combinator.constant_of(3) }
  let(:nominal_string) { Rigor::Type::Combinator.nominal_of("String") }
  let(:nominal_integer) { Rigor::Type::Combinator.nominal_of("Integer") }

  describe "+ (string concatenation)" do
    it "lifts literal-string + literal-string to literal-string" do
      result = described_class.try_dispatch(receiver: literal_string, method_name: :+, args: [literal_string])
      expect(result).to eq(literal_string)
    end

    it "lifts literal-string + Constant<String> to literal-string" do
      result = described_class.try_dispatch(receiver: literal_string, method_name: :+, args: [string_const])
      expect(result).to eq(literal_string)
    end

    it "lifts Constant<String> + literal-string to literal-string" do
      result = described_class.try_dispatch(receiver: string_const, method_name: :+, args: [literal_string])
      expect(result).to eq(literal_string)
    end

    it "lifts non-empty-literal-string + literal-string (Intersection containing literal-string)" do
      nels = Rigor::Type::Combinator.non_empty_literal_string
      result = described_class.try_dispatch(receiver: nels, method_name: :+, args: [literal_string])
      expect(result).to eq(literal_string)
    end

    it "declines when the argument is plain Nominal[String] (not necessarily literal)" do
      result = described_class.try_dispatch(receiver: literal_string, method_name: :+, args: [nominal_string])
      expect(result).to be_nil
    end

    it "declines when the receiver is plain Nominal[String]" do
      result = described_class.try_dispatch(receiver: nominal_string, method_name: :+, args: [literal_string])
      expect(result).to be_nil
    end
  end

  describe "<< (mutating append)" do
    it "lifts literal-string << literal-string to literal-string" do
      result = described_class.try_dispatch(receiver: literal_string, method_name: :<<, args: [literal_string])
      expect(result).to eq(literal_string)
    end

    it "lifts literal-string << Constant<String> to literal-string" do
      result = described_class.try_dispatch(receiver: literal_string, method_name: :<<, args: [string_const])
      expect(result).to eq(literal_string)
    end

    it "declines literal-string << Nominal[String] (arg is not literal-bearing)" do
      result = described_class.try_dispatch(receiver: literal_string, method_name: :<<, args: [nominal_string])
      expect(result).to be_nil
    end

    it "declines when receiver is plain Nominal[String]" do
      result = described_class.try_dispatch(receiver: nominal_string, method_name: :<<, args: [literal_string])
      expect(result).to be_nil
    end
  end

  describe "concat (alias of <<)" do
    it "lifts literal-string.concat(literal-string) to literal-string" do
      result = described_class.try_dispatch(receiver: literal_string, method_name: :concat, args: [literal_string])
      expect(result).to eq(literal_string)
    end

    it "declines when the argument is non-literal" do
      result = described_class.try_dispatch(receiver: literal_string, method_name: :concat, args: [nominal_string])
      expect(result).to be_nil
    end
  end

  describe "* (string repetition)" do
    it "lifts literal-string * Constant<Integer> to literal-string" do
      result = described_class.try_dispatch(receiver: literal_string, method_name: :*, args: [int_const])
      expect(result).to eq(literal_string)
    end

    it "lifts literal-string * Nominal[Integer] to literal-string" do
      result = described_class.try_dispatch(receiver: literal_string, method_name: :*, args: [nominal_integer])
      expect(result).to eq(literal_string)
    end

    it "declines when the multiplier is not Integer-typed" do
      result = described_class.try_dispatch(receiver: literal_string, method_name: :*, args: [literal_string])
      expect(result).to be_nil
    end

    it "declines when the receiver is plain Nominal[String]" do
      result = described_class.try_dispatch(receiver: nominal_string, method_name: :*, args: [int_const])
      expect(result).to be_nil
    end
  end

  describe "Array#join (Tuple receiver lift)" do # rubocop:disable RSpec/MultipleMemoizedHelpers
    let(:tuple_of_literals) { Rigor::Type::Combinator.tuple_of(literal_string, string_const) }
    let(:tuple_with_nominal) { Rigor::Type::Combinator.tuple_of(literal_string, nominal_string) }
    let(:empty_tuple) { Rigor::Type::Combinator.tuple_of }

    it "lifts Tuple[literal, Constant<String>].join to literal-string (no separator)" do
      result = described_class.try_dispatch(receiver: tuple_of_literals, method_name: :join, args: [])
      expect(result).to eq(literal_string)
    end

    it "lifts Tuple[…].join(literal-string) to literal-string" do
      result = described_class.try_dispatch(
        receiver: tuple_of_literals, method_name: :join, args: [string_const]
      )
      expect(result).to eq(literal_string)
    end

    it "lifts Tuple[].join (empty tuple) to literal-string" do
      result = described_class.try_dispatch(receiver: empty_tuple, method_name: :join, args: [])
      expect(result).to eq(literal_string)
    end

    it "declines when an element is a plain Nominal[String]" do
      result = described_class.try_dispatch(receiver: tuple_with_nominal, method_name: :join, args: [])
      expect(result).to be_nil
    end

    it "declines when the separator is not literal-bearing" do
      result = described_class.try_dispatch(
        receiver: tuple_of_literals, method_name: :join, args: [nominal_string]
      )
      expect(result).to be_nil
    end

    it "declines when the receiver is a plain Nominal[Array]" do
      array = Rigor::Type::Combinator.nominal_of("Array")
      result = described_class.try_dispatch(receiver: array, method_name: :join, args: [])
      expect(result).to be_nil
    end

    it "declines when more than one separator argument is supplied" do
      result = described_class.try_dispatch(
        receiver: tuple_of_literals, method_name: :join, args: [string_const, string_const]
      )
      expect(result).to be_nil
    end
  end

  describe "unrecognised method names" do
    it "declines for methods outside the recognised set" do
      result = described_class.try_dispatch(receiver: literal_string, method_name: :upcase, args: [literal_string])
      expect(result).to be_nil
    end
  end

  describe "argument-arity checks" do
    it "declines when the call has zero or multiple arguments" do
      expect(described_class.try_dispatch(receiver: literal_string, method_name: :+, args: [])).to be_nil
      two_args = [literal_string, literal_string]
      expect(described_class.try_dispatch(receiver: literal_string, method_name: :+, args: two_args)).to be_nil
    end
  end
end
