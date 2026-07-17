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
      result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :+, args: [literal_string]))
      expect(result).to eq(literal_string)
    end

    it "lifts literal-string + Constant<non-empty-string> to non-empty-literal-string" do
      # string_const = "hi" which is non-empty, so the concatenation is provably non-empty
      result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :+, args: [string_const]))
      expect(result).to eq(Rigor::Type::Combinator.non_empty_literal_string)
    end

    it "lifts literal-string + Constant[\"\"] to literal-string (empty arg gives no non-empty guarantee)" do
      empty_const = Rigor::Type::Combinator.constant_of("")
      result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :+, args: [empty_const]))
      expect(result).to eq(literal_string)
    end

    it "lifts Constant<non-empty-string> + literal-string to non-empty-literal-string" do
      # string_const = "hi" which is non-empty
      result = described_class.try_dispatch(cc(receiver: string_const, method_name: :+, args: [literal_string]))
      expect(result).to eq(Rigor::Type::Combinator.non_empty_literal_string)
    end

    it "lifts non-empty-literal-string + literal-string to non-empty-literal-string" do
      nels = Rigor::Type::Combinator.non_empty_literal_string
      result = described_class.try_dispatch(cc(receiver: nels, method_name: :+, args: [literal_string]))
      expect(result).to eq(nels)
    end

    it "declines when the argument is plain Nominal[String] (not necessarily literal)" do
      result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :+, args: [nominal_string]))
      expect(result).to be_nil
    end

    it "declines when the receiver is plain Nominal[String]" do
      result = described_class.try_dispatch(cc(receiver: nominal_string, method_name: :+, args: [literal_string]))
      expect(result).to be_nil
    end
  end

  describe "<< (mutating append)" do
    it "lifts literal-string << literal-string to literal-string" do
      result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :<<, args: [literal_string]))
      expect(result).to eq(literal_string)
    end

    it "lifts literal-string << Constant<non-empty-string> to non-empty-literal-string" do
      result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :<<, args: [string_const]))
      expect(result).to eq(Rigor::Type::Combinator.non_empty_literal_string)
    end

    it "declines literal-string << Nominal[String] (arg is not literal-bearing)" do
      result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :<<, args: [nominal_string]))
      expect(result).to be_nil
    end

    it "declines when receiver is plain Nominal[String]" do
      result = described_class.try_dispatch(cc(receiver: nominal_string, method_name: :<<, args: [literal_string]))
      expect(result).to be_nil
    end
  end

  describe "concat (alias of <<)" do
    it "lifts literal-string.concat(literal-string) to literal-string" do
      result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :concat, args: [literal_string]))
      expect(result).to eq(literal_string)
    end

    it "declines when the argument is non-literal" do
      result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :concat, args: [nominal_string]))
      expect(result).to be_nil
    end
  end

  describe "* (string repetition)" do
    it "lifts literal-string * Constant<Integer> to literal-string" do
      result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :*, args: [int_const]))
      expect(result).to eq(literal_string)
    end

    it "lifts literal-string * Nominal[Integer] to literal-string" do
      result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :*, args: [nominal_integer]))
      expect(result).to eq(literal_string)
    end

    it "declines when the multiplier is not Integer-typed" do
      result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :*, args: [literal_string]))
      expect(result).to be_nil
    end

    it "declines when the receiver is plain Nominal[String]" do
      result = described_class.try_dispatch(cc(receiver: nominal_string, method_name: :*, args: [int_const]))
      expect(result).to be_nil
    end
  end

  describe "Array#join (Tuple receiver lift)" do
    let(:tuple_of_literals) { Rigor::Type::Combinator.tuple_of(literal_string, string_const) }
    let(:tuple_of_constants) { Rigor::Type::Combinator.tuple_of(string_const, string_const) }
    let(:tuple_with_nominal) { Rigor::Type::Combinator.tuple_of(literal_string, nominal_string) }

    it "lifts Tuple[literal, Constant<String>].join to literal-string (no separator)" do
      result = described_class.try_dispatch(cc(receiver: tuple_of_literals, method_name: :join, args: []))
      expect(result).to eq(literal_string)
    end

    it "lifts Tuple[…].join(literal-string) to literal-string" do
      result = described_class.try_dispatch(cc(
                                              receiver: tuple_of_literals, method_name: :join, args: [string_const]
                                            ))
      expect(result).to eq(literal_string)
    end

    # An all-`Constant` tuple with an absent or `Constant<String>` separator is exactly what
    # `ShapeDispatch.tuple_join` folds to a precise `Constant<String>`. This tier runs ahead of
    # ShapeDispatch, so it MUST decline (return nil) rather than shadow that with `literal-string`.
    it "declines Tuple[Constant<String>, Constant<String>].join so ShapeDispatch folds the precise Constant" do
      result = described_class.try_dispatch(cc(receiver: tuple_of_constants, method_name: :join, args: []))
      expect(result).to be_nil
    end

    it "declines an all-Constant tuple join with a Constant<String> separator" do
      result = described_class.try_dispatch(cc(
                                              receiver: tuple_of_constants, method_name: :join, args: [string_const]
                                            ))
      expect(result).to be_nil
    end

    it "declines Tuple[].join (empty tuple) so ShapeDispatch folds Constant<\"\">" do
      empty_tuple = Rigor::Type::Combinator.tuple_of
      result = described_class.try_dispatch(cc(receiver: empty_tuple, method_name: :join, args: []))
      expect(result).to be_nil
    end

    it "still lifts an all-Constant tuple join to literal-string when the separator is non-Constant" do
      # A `literal-string` separator has no knowable value, so the precise Constant fold is unreachable and
      # this tier keeps producing `literal-string`.
      result = described_class.try_dispatch(cc(
                                              receiver: tuple_of_constants, method_name: :join, args: [literal_string]
                                            ))
      expect(result).to eq(literal_string)
    end

    it "declines when an element is a plain Nominal[String]" do
      result = described_class.try_dispatch(cc(receiver: tuple_with_nominal, method_name: :join, args: []))
      expect(result).to be_nil
    end

    it "declines when the separator is not literal-bearing" do
      result = described_class.try_dispatch(cc(
                                              receiver: tuple_of_literals, method_name: :join, args: [nominal_string]
                                            ))
      expect(result).to be_nil
    end

    it "declines when the receiver is a plain Nominal[Array]" do
      array = Rigor::Type::Combinator.nominal_of("Array")
      result = described_class.try_dispatch(cc(receiver: array, method_name: :join, args: []))
      expect(result).to be_nil
    end

    it "declines when more than one separator argument is supplied" do
      result = described_class.try_dispatch(cc(
                                              receiver: tuple_of_literals, method_name: :join, args: [string_const,
                                                                                                      string_const]
                                            ))
      expect(result).to be_nil
    end
  end

  describe "String#% (template % values)" do
    it "lifts literal-string % literal-string to literal-string" do
      result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :%, args: [literal_string]))
      expect(result).to eq(literal_string)
    end

    it "lifts literal-string % Constant<Integer> to literal-string" do
      result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :%, args: [int_const]))
      expect(result).to eq(literal_string)
    end

    it "lifts literal-string % Tuple[literal, Constant<Integer>] to literal-string" do
      tuple = Rigor::Type::Combinator.tuple_of(literal_string, int_const)
      result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :%, args: [tuple]))
      expect(result).to eq(literal_string)
    end

    it "declines when receiver is plain Nominal[String]" do
      result = described_class.try_dispatch(cc(receiver: nominal_string, method_name: :%, args: [literal_string]))
      expect(result).to be_nil
    end

    it "declines when an arg-tuple element is not literal-bearing" do
      tuple = Rigor::Type::Combinator.tuple_of(literal_string, nominal_string)
      result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :%, args: [tuple]))
      expect(result).to be_nil
    end

    it "declines when the value arg is plain Nominal[Integer]" do
      result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :%, args: [nominal_integer]))
      expect(result).to be_nil
    end
  end

  describe "literal-string preservation through #center / #ljust / #rjust (v0.1.1 Track 1 slice 5c)" do
    %i[center ljust rjust].each do |sel|
      it "lifts ##{sel}(width) on literal-string to literal-string (default padding)" do
        result = described_class.try_dispatch(cc(receiver: literal_string, method_name: sel, args: [int_const]))
        expect(result).to eq(literal_string)
      end

      it "lifts ##{sel}(width, literal-string) to literal-string when both are literal" do
        result = described_class.try_dispatch(cc(
                                                receiver: literal_string, method_name: sel, args: [int_const,
                                                                                                   literal_string]
                                              ))
        expect(result).to eq(literal_string)
      end

      it "declines for ##{sel} when the padding argument is not literal-bearing" do
        result = described_class.try_dispatch(cc(
                                                receiver: literal_string, method_name: sel, args: [int_const,
                                                                                                   nominal_string]
                                              ))
        expect(result).to be_nil
      end

      it "declines for ##{sel} when the width argument is not Integer-typed" do
        result = described_class.try_dispatch(cc(
                                                receiver: literal_string, method_name: sel, args: [nominal_string]
                                              ))
        expect(result).to be_nil
      end

      it "declines for ##{sel} when the receiver is plain Nominal[String]" do
        result = described_class.try_dispatch(cc(
                                                receiver: nominal_string, method_name: sel, args: [int_const]
                                              ))
        expect(result).to be_nil
      end
    end
  end

  describe "literal-string preservation through #strip / #chomp / #scrub family (v0.1.1 Track 1 slice 5a)" do
    %i[strip lstrip rstrip chomp chop scrub].each do |sel|
      it "preserves literal-string through ##{sel} (no args)" do
        result = described_class.try_dispatch(cc(receiver: literal_string, method_name: sel, args: []))
        expect(result).to eq(literal_string)
      end

      it "declines for ##{sel} when the receiver is plain Nominal[String]" do
        result = described_class.try_dispatch(cc(receiver: nominal_string, method_name: sel, args: []))
        expect(result).to be_nil
      end
    end

    it "preserves literal-string through #strip on `non-empty-literal-string` (carrier collapses to literal-string)" do
      nels = Rigor::Type::Combinator.non_empty_literal_string
      result = described_class.try_dispatch(cc(receiver: nels, method_name: :strip, args: []))
      expect(result).to eq(literal_string)
    end

    it "declines when the preserving method is given an argument (slice 5a covers no-arg only)" do
      result = described_class.try_dispatch(cc(
                                              receiver: literal_string, method_name: :chomp, args: [Rigor::Type::Combinator.constant_of("\n")]
                                            ))
      expect(result).to be_nil
    end
  end

  describe "unrecognised method names" do
    it "declines for methods outside the recognised set" do
      result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :gsub, args: [literal_string]))
      expect(result).to be_nil
    end
  end

  describe "argument-arity checks" do
    it "declines when the call has zero or multiple arguments" do
      expect(described_class.try_dispatch(cc(receiver: literal_string, method_name: :+, args: []))).to be_nil
      two_args = [literal_string, literal_string]
      expect(described_class.try_dispatch(cc(receiver: literal_string, method_name: :+, args: two_args))).to be_nil
    end
  end

  describe "non-empty-string propagation through + and *" do
    let(:non_empty_literal) { Rigor::Type::Combinator.non_empty_literal_string }
    let(:pos_int) { Rigor::Type::Combinator.positive_int }

    describe "+ (non-empty propagation)" do
      it "non-empty-literal-string + literal-string → non-empty-literal-string" do
        result = described_class.try_dispatch(cc(receiver: non_empty_literal, method_name: :+, args: [literal_string]))
        expect(result).to eq(non_empty_literal)
      end

      it "literal-string + non-empty-literal-string → non-empty-literal-string" do
        result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :+, args: [non_empty_literal]))
        expect(result).to eq(non_empty_literal)
      end

      it "non-empty-literal-string + non-empty-literal-string → non-empty-literal-string" do
        result = described_class.try_dispatch(cc(receiver: non_empty_literal, method_name: :+,
                                                 args: [non_empty_literal]))
        expect(result).to eq(non_empty_literal)
      end

      it "literal-string + literal-string remains literal-string (no non-empty uplift)" do
        result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :+, args: [literal_string]))
        expect(result).to eq(literal_string)
      end

      it "literal-string + Constant[non-empty] → non-empty-literal-string" do
        result = described_class.try_dispatch(cc(
                                                receiver: literal_string, method_name: :+, args: [Rigor::Type::Combinator.constant_of("hi")]
                                              ))
        expect(result).to eq(non_empty_literal)
      end
    end

    describe "* (repetition with zero and positive multiplier)" do
      it "literal-string * Constant[0] → Constant[\"\"]" do
        result = described_class.try_dispatch(cc(
                                                receiver: literal_string, method_name: :*, args: [Rigor::Type::Combinator.constant_of(0)]
                                              ))
        expect(result).to eq(Rigor::Type::Combinator.constant_of(""))
      end

      it "non-empty-literal-string * Constant[0] → Constant[\"\"]" do
        result = described_class.try_dispatch(cc(
                                                receiver: non_empty_literal, method_name: :*, args: [Rigor::Type::Combinator.constant_of(0)]
                                              ))
        expect(result).to eq(Rigor::Type::Combinator.constant_of(""))
      end

      it "non-empty-literal-string * Constant[3] → non-empty-literal-string" do
        result = described_class.try_dispatch(cc(
                                                receiver: non_empty_literal, method_name: :*, args: [Rigor::Type::Combinator.constant_of(3)]
                                              ))
        expect(result).to eq(non_empty_literal)
      end

      it "non-empty-literal-string * positive-int → non-empty-literal-string" do
        result = described_class.try_dispatch(cc(receiver: non_empty_literal, method_name: :*, args: [pos_int]))
        expect(result).to eq(non_empty_literal)
      end

      it "literal-string * positive-int stays literal-string (receiver may be empty)" do
        result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :*, args: [pos_int]))
        expect(result).to eq(literal_string)
      end

      it "literal-string * Nominal[Integer] stays literal-string (multiplier unknown)" do
        result = described_class.try_dispatch(cc(receiver: literal_string, method_name: :*, args: [nominal_integer]))
        expect(result).to eq(literal_string)
      end
    end
  end

  describe "#upcase / #downcase / #capitalize / #swapcase / #reverse — non-empty-literal preservation" do
    let(:non_empty_literal) { Rigor::Type::Combinator.non_empty_literal_string }

    %i[upcase downcase capitalize swapcase reverse].each do |sel|
      it "##{sel} on literal-string → literal-string" do
        result = described_class.try_dispatch(cc(receiver: literal_string, method_name: sel, args: []))
        expect(result).to eq(literal_string)
      end

      it "##{sel} on non-empty-literal-string → non-empty-literal-string" do
        result = described_class.try_dispatch(cc(receiver: non_empty_literal, method_name: sel, args: []))
        expect(result).to eq(non_empty_literal)
      end

      it "declines ##{sel} when receiver is plain Nominal[String]" do
        result = described_class.try_dispatch(cc(receiver: nominal_string, method_name: sel, args: []))
        expect(result).to be_nil
      end

      it "declines ##{sel} when an argument is supplied (no-arg only)" do
        result = described_class.try_dispatch(cc(
                                                receiver: literal_string, method_name: sel, args: [literal_string]
                                              ))
        expect(result).to be_nil
      end
    end
  end

  describe "known_zero_integer? (private helper)" do
    it "recognises an IntegerRange [0, 0] as zero" do
      range = Rigor::Type::IntegerRange.new(0, 0)
      result = described_class.send(:known_zero_integer?, range)
      expect(result).to be(true)
    end

    it "rejects an IntegerRange [1, 5] as non-zero" do
      range = Rigor::Type::IntegerRange.new(1, 5)
      result = described_class.send(:known_zero_integer?, range)
      expect(result).to be(false)
    end
  end
end
