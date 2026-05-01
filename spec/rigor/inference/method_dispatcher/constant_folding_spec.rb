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

  # Union[Constant…] folding. Each Constant in a union represents a
  # possible runtime value; a binary op over two unions is the
  # cartesian fold, deduplicated. Bounded by the input/output
  # cardinality caps so an analyzer-side blowup is not possible.
  describe "union fold" do
    def constant_union(*values)
      Rigor::Type::Combinator.union(
        *values.map { |v| Rigor::Type::Combinator.constant_of(v) }
      )
    end

    def fold_types(receiver, method_name, args = [])
      described_class.try_fold(
        receiver: receiver,
        method_name: method_name,
        args: args
      )
    end

    it "folds Constant[1] + Union[2, 3] to Union[3, 4]" do
      type = fold_types(
        Rigor::Type::Combinator.constant_of(1),
        :+,
        [constant_union(2, 3)]
      )
      values = type.members.map(&:value).sort
      expect(values).to eq([3, 4])
    end

    it "folds Union[1, 2] + Union[3, 4] and dedupes 5 (= 1+4 = 2+3)" do
      type = fold_types(
        constant_union(1, 2),
        :+,
        [constant_union(3, 4)]
      )
      values = type.members.map(&:value).sort
      expect(values).to eq([4, 5, 6])
    end

    it "folds Union[1, 2, 3] + Union[2, 4, 6] (the user-spec example)" do
      type = fold_types(
        constant_union(1, 2, 3),
        :+,
        [constant_union(2, 4, 6)]
      )
      values = type.members.map(&:value).sort
      expect(values).to eq([3, 4, 5, 6, 7, 8, 9])
    end

    it "collapses to a single Constant when the cartesian fold has a single result" do
      # `Union[1, 2] * Constant[0]` — every product is 0.
      type = fold_types(
        constant_union(1, 2),
        :*,
        [Rigor::Type::Combinator.constant_of(0)]
      )
      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(0)
    end

    it "drops always-raising pairs and keeps the safe ones" do
      # `Union[5, 7] / Union[0, 2]` — the (·, 0) pairs are
      # division-by-zero (caught by safe?), so only 5/2=2 and
      # 7/2=3 reach the result. The fold returns the survivors.
      type = fold_types(
        constant_union(5, 7),
        :/,
        [constant_union(0, 2)]
      )
      values = type.members.map(&:value).sort
      expect(values).to eq([2, 3])
    end

    it "returns nil when every pair is unsafe" do
      type = fold_types(
        constant_union(5, 7),
        :/,
        [Rigor::Type::Combinator.constant_of(0)]
      )
      expect(type).to be_nil
    end

    it "returns nil when input cartesian exceeds UNION_FOLD_INPUT_LIMIT" do
      # 6 × 6 = 36 inputs > 32 cap.
      receiver = constant_union(*(1..6).to_a)
      arg = constant_union(*(10..15).to_a)
      expect(fold_types(receiver, :+, [arg])).to be_nil
    end

    it "widens to IntegerRange when output cardinality exceeds UNION_FOLD_OUTPUT_LIMIT" do
      # 5 × 5 = 25 inputs (under input cap), `:+` over disjoint ranges
      # produces 25 distinct sums (>8). The graceful escape valve is to
      # return the bounding `IntegerRange[min..max]` rather than `nil`.
      receiver = constant_union(1, 2, 3, 4, 5)
      arg = constant_union(10, 20, 30, 40, 50)
      type = fold_types(receiver, :+, [arg])
      expect(type).to be_a(Rigor::Type::IntegerRange)
      expect(type.min).to eq(11)
      expect(type.max).to eq(55)
    end

    it "narrows to Union[true, false] via comparisons regardless of input width" do
      # `Union[1, 2, 3] < 2` — outputs only true/false; the
      # output cap is 8 so this comfortably folds.
      type = fold_types(
        constant_union(1, 2, 3),
        :<,
        [Rigor::Type::Combinator.constant_of(2)]
      )
      values = type.members.map(&:value).sort_by { |v| v ? 1 : 0 }
      expect(values).to eq([false, true])
    end

    it "folds unary methods over a Union receiver" do
      type = fold_types(constant_union(1, 2, 3, 4), :odd?)
      values = type.members.map(&:value).sort_by { |v| v ? 1 : 0 }
      expect(values).to eq([false, true])
    end

    it "passes single-Constant fold through unchanged (no Union wrapping)" do
      # The Union path must not regress the simple case.
      type = fold_types(
        Rigor::Type::Combinator.constant_of(1),
        :+,
        [Rigor::Type::Combinator.constant_of(2)]
      )
      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(3)
    end

    it "returns nil when a Union member is not a Constant" do
      # `Union[Constant[1], Nominal[Integer]]` is not a pure-constant union.
      receiver = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(1),
        Rigor::Type::Combinator.nominal_of("Integer")
      )
      expect(fold_types(receiver, :+, [Rigor::Type::Combinator.constant_of(2)])).to be_nil
    end
  end

  # IntegerRange (positive-int, non-negative-int, int<a, b>, …) folding.
  # Compare to PHPStan's `int<min, max>` family. The carrier never widens
  # beyond what the inputs imply, so `int<5, 10> + int<1, 2>` is exactly
  # `int<6, 12>` rather than the looser `Nominal[Integer]`.
  describe "integer range fold" do
    def positive_int = Rigor::Type::Combinator.positive_int
    def non_negative_int = Rigor::Type::Combinator.non_negative_int
    def negative_int = Rigor::Type::Combinator.negative_int
    def universal_int = Rigor::Type::Combinator.universal_int
    def constant_of(value) = Rigor::Type::Combinator.constant_of(value)
    def integer_range(low, high) = Rigor::Type::Combinator.integer_range(low, high)

    def fold_types(receiver, method_name, args = [])
      described_class.try_fold(
        receiver: receiver, method_name: method_name, args: args
      )
    end

    describe "binary arithmetic" do
      it "adds two finite ranges by summing endpoints" do
        type = fold_types(integer_range(5, 10), :+, [integer_range(1, 2)])
        expect(type).to eq(integer_range(6, 12))
      end

      it "subtracts ranges by reflecting the right endpoints" do
        type = fold_types(integer_range(5, 10), :-, [integer_range(1, 2)])
        expect(type).to eq(integer_range(3, 9))
      end

      it "promotes a Constant to a single-point range when added to a range" do
        type = fold_types(positive_int, :+, [constant_of(3)])
        expect(type).to eq(integer_range(4, Rigor::Type::IntegerRange::POS_INFINITY))
      end

      it "promotes the receiver Constant when added to a range" do
        type = fold_types(constant_of(10), :-, [non_negative_int])
        # 10 - [0..+∞] = [-∞..10]
        expect(type).to eq(integer_range(Rigor::Type::IntegerRange::NEG_INFINITY, 10))
      end
    end

    describe "binary comparison" do
      it "is always-true when ranges are entirely ordered" do
        # int<1, 5> < int<6, 10> → all true
        expect(
          fold_types(integer_range(1, 5), :<, [integer_range(6, 10)])
        ).to eq(constant_of(true))
      end

      it "is always-false when ranges are reversed" do
        expect(
          fold_types(integer_range(6, 10), :<, [integer_range(1, 5)])
        ).to eq(constant_of(false))
      end

      it "produces Union[true, false] on overlap" do
        type = fold_types(integer_range(1, 5), :<, [integer_range(3, 7)])
        expect(type).to be_a(Rigor::Type::Union)
        expect(type.members.map(&:value).sort_by { |v| v ? 1 : 0 }).to eq([false, true])
      end

      it "compares positive-int < 0 as always-false" do
        expect(fold_types(positive_int, :<, [constant_of(0)])).to eq(constant_of(false))
        expect(fold_types(positive_int, :>, [constant_of(0)])).to eq(constant_of(true))
      end

      it "compares non-negative-int >= 0 as always-true" do
        expect(fold_types(non_negative_int, :>=, [constant_of(0)])).to eq(constant_of(true))
      end
    end

    describe "unary predicates" do
      it "negative_int.negative? is always-true" do
        expect(fold_types(negative_int, :negative?)).to eq(constant_of(true))
        expect(fold_types(negative_int, :positive?)).to eq(constant_of(false))
        expect(fold_types(negative_int, :zero?)).to eq(constant_of(false))
      end

      it "positive_int.positive? is always-true and zero? always-false" do
        expect(fold_types(positive_int, :positive?)).to eq(constant_of(true))
        expect(fold_types(positive_int, :zero?)).to eq(constant_of(false))
      end

      it "non-negative-int .zero? collapses to Union[true, false]" do
        type = fold_types(non_negative_int, :zero?)
        expect(type).to be_a(Rigor::Type::Union)
        expect(type.members.map(&:value).sort_by { |v| v ? 1 : 0 }).to eq([false, true])
      end
    end

    describe "unary shifts and abs" do
      it "succ shifts the range by +1" do
        expect(fold_types(integer_range(1, 5), :succ)).to eq(integer_range(2, 6))
      end

      it "pred shifts by -1" do
        expect(fold_types(integer_range(1, 5), :pred)).to eq(integer_range(0, 4))
      end

      it "abs of a non-negative range is the range itself" do
        expect(fold_types(non_negative_int, :abs)).to eq(non_negative_int)
      end

      it "abs of a strictly-negative range reflects to non-negative" do
        expect(fold_types(integer_range(-10, -3), :abs)).to eq(integer_range(3, 10))
      end

      it "abs of a range straddling zero produces 0..max(|min|, |max|)" do
        expect(fold_types(integer_range(-3, 5), :abs)).to eq(integer_range(0, 5))
        expect(fold_types(integer_range(-7, 5), :abs)).to eq(integer_range(0, 7))
      end

      it "-@ negates the range" do
        expect(fold_types(integer_range(1, 5), :-@)).to eq(integer_range(-5, -1))
      end
    end

    describe "graceful widening" do
      it "widens a Union[Constant<Integer>...] to a bounding IntegerRange when output cap exceeded" do
        receiver = Rigor::Type::Combinator.union(
          *(1..5).map { |v| constant_of(v) }
        )
        arg = Rigor::Type::Combinator.union(
          *(10..14).map { |v| constant_of(v) }
        )
        type = fold_types(receiver, :+, [arg])
        expect(type).to be_a(Rigor::Type::IntegerRange)
        expect(type.min).to eq(11)
        expect(type.max).to eq(19)
      end

      it "does not widen when the result set has non-Integer members" do
        # Each Float arg keeps the result a Float, so widening is
        # not an option. The cap becomes a hard nil.
        receiver = Rigor::Type::Combinator.union(
          *(1..5).map { |v| constant_of(v) }
        )
        arg = Rigor::Type::Combinator.union(
          *(1..5).map { |v| constant_of(v.to_f) }
        )
        # 5×5 = 25 inputs (under input cap); 25 distinct Float sums (over output cap).
        # Inputs include Float, so widening to IntegerRange is rejected.
        expect(fold_types(receiver, :+, [arg])).to be_nil
      end
    end
  end
end
