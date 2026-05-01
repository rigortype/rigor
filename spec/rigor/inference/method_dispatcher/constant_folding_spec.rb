# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::ConstantFolding do
  def fold(value, method_name, args = [])
    described_class.try_fold(
      receiver: Rigor::Type::Combinator.constant_of(value),
      method_name: method_name,
      args: args.map { |v| Rigor::Type::Combinator.constant_of(v) }
    )
  end

  describe "binary fold (existing surface)" do
    it "folds 1 + 2 to Constant[3]" do
      type = fold(1, :+, [2])
      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(3)
    end

    it "returns nil when the method is not in the binary catalogue" do
      expect(fold(1, :divmod, [2])).to be_nil
    end
  end

  describe "unary fold (v0.0.3 C)" do
    describe "Integer" do
      it "folds Integer#odd? to a Constant boolean" do
        type = fold(3, :odd?)
        expect(type.value).to be(true)

        expect(fold(4, :odd?).value).to be(false)
      end

      it "folds Integer#even? / #zero? / #positive? / #negative?" do
        expect(fold(4, :even?).value).to be(true)
        expect(fold(0, :zero?).value).to be(true)
        expect(fold(5, :positive?).value).to be(true)
        expect(fold(-1, :negative?).value).to be(true)
      end

      it "folds Integer#succ to the next integer" do
        expect(fold(1, :succ).value).to eq(2)
        expect(fold(-1, :pred).value).to eq(-2)
      end

      it "folds Integer#to_s to a Constant String" do
        type = fold(42, :to_s)
        expect(type.value).to eq("42")
      end
    end

    describe "String" do
      it "folds String#upcase / #downcase / #reverse" do
        expect(fold("hi", :upcase).value).to eq("HI")
        expect(fold("HI", :downcase).value).to eq("hi")
        expect(fold("abc", :reverse).value).to eq("cba")
      end

      it "folds String#length / #size / #empty?" do
        expect(fold("abc", :length).value).to eq(3)
        expect(fold("", :empty?).value).to be(true)
      end

      it "folds String#to_sym to a Constant Symbol" do
        type = fold("hi", :to_sym)
        expect(type.value).to eq(:hi)
      end
    end

    describe "boolean / nil" do
      it "folds true.! to false (and vice versa)" do
        expect(fold(true, :!).value).to be(false)
        expect(fold(false, :!).value).to be(true)
      end

      it "folds nil.nil? to true and 1.nil? on Integer is unsupported (no `nil?` in INTEGER_UNARY)" do
        expect(fold(nil, :nil?).value).to be(true)
        # Integer's nil? is not in the catalogue — folding
        # is conservative, returning nil so the RBS tier
        # answers via `Method | Bool`. The integration
        # test below proves the engine still returns the
        # correct precise value through dispatch.
        expect(fold(1, :nil?)).to be_nil
      end
    end

    it "returns nil when the method is not in the unary catalogue" do
      expect(fold(3, :no_such_method)).to be_nil
    end

    it "returns nil when the method's result is not a foldable scalar" do
      # `Integer#digits` returns an Array — not in the
      # `foldable_constant_value?` envelope.
      expect(fold(123, :digits)).to be_nil
    end
  end
end
