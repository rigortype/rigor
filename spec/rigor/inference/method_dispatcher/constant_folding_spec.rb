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

    it "returns nil when output cardinality exceeds UNION_FOLD_OUTPUT_LIMIT" do
      # 5 × 5 = 25 inputs (under input cap), but `:+` over
      # disjoint ranges produces > 8 distinct sums:
      # `[1..5] + [10, 20, 30, 40, 50]` → 25 distinct sums.
      receiver = constant_union(1, 2, 3, 4, 5)
      arg = constant_union(10, 20, 30, 40, 50)
      expect(fold_types(receiver, :+, [arg])).to be_nil
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
end
