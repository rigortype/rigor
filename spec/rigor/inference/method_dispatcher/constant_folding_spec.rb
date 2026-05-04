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
      # `:foo_no_such_op` is purely synthetic — the existing surface
      # gates folds via the `NUMERIC_BINARY` set, and `divmod` now
      # has its own Tuple-shaped fold path (covered separately below).
      expect(fold(1, :foo_no_such_op, [2])).to be_nil
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

  # Methods unlocked by the offline numeric.yml catalog: methods
  # whose CRuby implementation the catalog classifies as `leaf`
  # (no Ruby-level callout) or `leaf_when_numeric` (callout only on
  # non-Numeric arg, gated upstream by the literal-only fold).
  # The hand-rolled `NUMERIC_BINARY` / `INTEGER_UNARY` sets do not
  # cover these, so before the wiring landed the fold returned nil.
  describe "catalog-driven binary fold" do
    it "folds Integer#** (power)" do
      expect(fold(2, :**, [10]).value).to eq(1024)
      expect(fold(5, :**, [3]).value).to eq(125)
    end

    it "folds Float#** (power)" do
      expect(fold(2.0, :**, [10]).value).to eq(1024.0)
    end

    it "folds bitwise & | ^ << >>" do
      expect(fold(0xff, :&, [0x0f]).value).to eq(0x0f)
      expect(fold(1, :|, [2]).value).to eq(3)
      expect(fold(0xa, :^, [0xc]).value).to eq(6)
      expect(fold(1, :<<, [3]).value).to eq(8)
      expect(fold(8, :>>, [2]).value).to eq(2)
    end

    it "folds Integer#=== (case-equality is value-equality on Integer)" do
      expect(fold(5, :===, [5]).value).to be(true)
      expect(fold(5, :===, [6]).value).to be(false)
    end

    it "folds Integer#div / #fdiv / #modulo / #remainder / #pow" do
      expect(fold(5, :div, [2]).value).to eq(2)
      expect(fold(5, :fdiv, [2]).value).to eq(2.5)
      expect(fold(5, :modulo, [2]).value).to eq(1)
      expect(fold(5, :remainder, [2]).value).to eq(1)
      expect(fold(2, :pow, [10]).value).to eq(1024)
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

    def constant_union(*values)
      Rigor::Type::Combinator.union(*values.map { |v| constant_of(v) })
    end

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

    describe "binary multiplication" do
      it "multiplies two finite ranges via 4-corner min/max" do
        # int<-2, 3> * int<1, 4> → corners {-2, -8, 3, 12} → int<-8, 12>
        type = fold_types(integer_range(-2, 3), :*, [integer_range(1, 4)])
        expect(type).to eq(integer_range(-8, 12))
      end

      it "preserves sign for two non-negative ranges" do
        type = fold_types(integer_range(2, 5), :*, [integer_range(3, 7)])
        expect(type).to eq(integer_range(6, 35))
      end

      it "treats 0 × +∞ as 0 (algebraic, not Float arithmetic)" do
        # non_negative_int × Constant[0] = exactly Constant[0]
        # because 0 × anything is 0 even at the +∞ endpoint.
        type = fold_types(non_negative_int, :*, [constant_of(0)])
        expect(type).to eq(constant_of(0))
      end

      it "extends to +∞ when a positive endpoint hits +∞" do
        # positive_int × int<2, 3> → int<2, +∞>
        type = fold_types(positive_int, :*, [integer_range(2, 3)])
        expect(type).to eq(integer_range(2, Rigor::Type::IntegerRange::POS_INFINITY))
      end
    end

    describe "binary integer division" do
      it "divides two non-zero ranges via corner quotients" do
        # int<10, 20> / int<2, 5> → corners {2, 5, 4, 10} → int<2, 10>
        type = fold_types(integer_range(10, 20), :/, [integer_range(2, 5)])
        expect(type).to eq(integer_range(2, 10))
      end

      it "bails when the divisor range covers 0" do
        expect(fold_types(positive_int, :/, [integer_range(-1, 1)])).to be_nil
        expect(fold_types(positive_int, :/, [non_negative_int])).to be_nil
      end

      it "narrows positive_int / Constant[2] to non_negative_int" do
        # 1/2 = 0, ∞/2 = ∞ → int<0, +∞> = non-negative-int
        type = fold_types(positive_int, :/, [constant_of(2)])
        expect(type).to eq(non_negative_int)
      end
    end

    describe "binary modulo" do
      it "narrows `range % positive Constant` to int<0, n-1>" do
        type = fold_types(integer_range(-100, 100), :%, [constant_of(5)])
        expect(type).to eq(integer_range(0, 4))
      end

      it "narrows `range % negative Constant` to int<n+1, 0>" do
        type = fold_types(integer_range(-100, 100), :%, [constant_of(-3)])
        expect(type).to eq(integer_range(-2, 0))
      end

      it "bails on divisor 0" do
        expect(fold_types(integer_range(-3, 3), :%, [constant_of(0)])).to be_nil
      end

      it "bails on non-point divisor (conservative)" do
        expect(fold_types(positive_int, :%, [integer_range(2, 5)])).to be_nil
      end
    end

    describe "even?/odd? precision" do
      it "is exact on a single-point range" do
        expect(fold_types(integer_range(4, 4), :even?)).to eq(constant_of(true))
        expect(fold_types(integer_range(4, 4), :odd?)).to eq(constant_of(false))
        expect(fold_types(integer_range(7, 7), :odd?)).to eq(constant_of(true))
      end

      it "produces Union[true, false] on any range with cardinality >= 2" do
        type = fold_types(integer_range(1, 2), :even?)
        expect(type).to be_a(Rigor::Type::Union)
        expect(type.members.map(&:value).sort_by { |v| v ? 1 : 0 }).to eq([false, true])
      end

      it "produces Union[true, false] for unbounded ranges" do
        type = fold_types(positive_int, :odd?)
        expect(type).to be_a(Rigor::Type::Union)
      end
    end

    describe "bit_length" do
      it "narrows finite ranges to int<0, max_bit_length>" do
        # 0..255 → bit_length 0..8
        type = fold_types(integer_range(0, 255), :bit_length)
        expect(type).to eq(integer_range(0, 8))
      end

      it "considers magnitude on the negative side" do
        # int<-256, 100> → max bit_length is bit_length(256)=9 (for negatives, bit_length(-256)=8;
        # but we use [|min|, |max|].max .bit_length per Ruby semantics here,
        # which gives max(bit_length(-256), bit_length(100)) = max(8, 7) = 8.
        type = fold_types(integer_range(-256, 100), :bit_length)
        expect(type.min).to eq(0)
        expect(type.max).to eq([-256.bit_length, 100.bit_length].max)
      end

      it "widens to non_negative_int for unbounded ranges" do
        expect(fold_types(positive_int, :bit_length)).to eq(non_negative_int)
      end
    end

    describe "divmod (Tuple-shaped result)" do
      it "folds 5.divmod(3) to Tuple[Constant[1], Constant[2]]" do
        type = fold_types(constant_of(5), :divmod, [constant_of(3)])
        expect(type).to be_a(Rigor::Type::Tuple)
        expect(type.elements.size).to eq(2)
        expect(type.elements[0]).to eq(constant_of(1))
        expect(type.elements[1]).to eq(constant_of(2))
      end

      it "uses Ruby's floor-division semantics for negatives" do
        # (-7).divmod(3) is [-3, 2] in Ruby (floor toward −∞), not [-2, -1].
        type = fold_types(constant_of(-7), :divmod, [constant_of(3)])
        expect(type.elements[0]).to eq(constant_of(-3))
        expect(type.elements[1]).to eq(constant_of(2))
      end

      it "handles negative divisor" do
        # 7.divmod(-3) → [-3, -2]
        type = fold_types(constant_of(7), :divmod, [constant_of(-3)])
        expect(type.elements[0]).to eq(constant_of(-3))
        expect(type.elements[1]).to eq(constant_of(-2))
      end

      it "folds Float divmod to Tuple[Constant[Integer], Constant[Float]]" do
        # 5.0.divmod(2.5) → [2, 0.0]
        type = fold_types(constant_of(5.0), :divmod, [constant_of(2.5)])
        expect(type).to be_a(Rigor::Type::Tuple)
        expect(type.elements[0]).to eq(constant_of(2))
        expect(type.elements[1]).to eq(constant_of(0.0))
      end

      it "folds 5.divmod(2.5) to a mixed Integer/Float tuple" do
        # 5.divmod(2.5) → [2, 0.0]
        type = fold_types(constant_of(5), :divmod, [constant_of(2.5)])
        expect(type.elements[0]).to eq(constant_of(2))
        expect(type.elements[1]).to eq(constant_of(0.0))
      end

      it "bails on integer divmod by 0 (always raises)" do
        expect(fold_types(constant_of(5), :divmod, [constant_of(0)])).to be_nil
      end

      it "rejects non-Numeric arguments" do
        expect(fold_types(constant_of(5), :divmod, [constant_of("3")])).to be_nil
      end

      it "projects union receivers per tuple position" do
        # Union[5, 7].divmod(3) → 5.divmod(3) = [1, 2]; 7.divmod(3) = [2, 1]
        # → Tuple[Union[Constant[1], Constant[2]], Union[Constant[1], Constant[2]]]
        type = fold_types(constant_union(5, 7), :divmod, [constant_of(3)])
        expect(type).to be_a(Rigor::Type::Tuple)
        expect(type.elements.size).to eq(2)
        q = type.elements[0]
        r = type.elements[1]
        expect(q).to be_a(Rigor::Type::Union)
        expect(q.members.map(&:value).sort).to eq([1, 2])
        expect(r).to be_a(Rigor::Type::Union)
        expect(r.members.map(&:value).sort).to eq([1, 2])
      end

      it "drops always-raising pairs and keeps the safe ones in a union" do
        # Union[5, 7].divmod(Union[0, 3]) — (·, 0) raises ZDE; (5,3)=[1,2], (7,3)=[2,1]
        type = fold_types(
          constant_union(5, 7), :divmod, [constant_union(0, 3)]
        )
        expect(type).to be_a(Rigor::Type::Tuple)
        expect(type.elements[0]).to be_a(Rigor::Type::Union)
        expect(type.elements[0].members.map(&:value).sort).to eq([1, 2])
        expect(type.elements[1]).to be_a(Rigor::Type::Union)
        expect(type.elements[1].members.map(&:value).sort).to eq([1, 2])
      end

      it "returns nil when every pair raises" do
        expect(
          fold_types(constant_union(5, 7), :divmod, [constant_of(0)])
        ).to be_nil
      end

      it "respects the input cardinality cap" do
        # 6 * 6 = 36 > UNION_FOLD_INPUT_LIMIT — bail before invocation.
        receiver = Rigor::Type::Combinator.union(*(1..6).map { |v| constant_of(v) })
        arg = Rigor::Type::Combinator.union(*(7..12).map { |v| constant_of(v) })
        expect(fold_types(receiver, :divmod, [arg])).to be_nil
      end

      it "does not yet fold IntegerRange divmod (returns nil)" do
        # Range divmod is a follow-up; for now the fold bails so the
        # caller can fall back to the RBS-widened result.
        expect(fold_types(positive_int, :divmod, [constant_of(3)])).to be_nil
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

  describe "include-aware module-catalog fallthrough (v0.0.5+)" do
    def constant_of(value) = Rigor::Type::Combinator.constant_of(value)

    def fold_types(receiver, method_name, args = [])
      described_class.try_fold(
        receiver: receiver,
        method_name: method_name,
        args: args
      )
    end

    it "folds Integer#clamp through Comparable's catalog when Numeric has no entry" do
      # `Integer#clamp(0..10)` is provided by the included
      # Comparable module — it is NOT registered directly on
      # Integer in `Init_Numeric`, so numeric.yml has no entry.
      # The include-aware fallthrough consults
      # `COMPARABLE_CATALOG`, which classifies `clamp` as
      # `:leaf`, and the fold materialises through the Ruby
      # invocation `5.clamp(0..10) #=> 5`.
      result = fold_types(constant_of(5), :clamp, [constant_of(0..10)])
      expect(result).to eq(constant_of(5))
    end

    it "folds the wider half of clamp(0..10) for Constant[100]" do
      # `100.clamp(0..10) #=> 10`.
      result = fold_types(constant_of(100), :clamp, [constant_of(0..10)])
      expect(result).to eq(constant_of(10))
    end
  end

  describe "two-argument fold dispatch (v0.0.5+)" do
    def constant_of(value) = Rigor::Type::Combinator.constant_of(value)

    def fold_types(receiver, method_name, args = [])
      described_class.try_fold(
        receiver: receiver,
        method_name: method_name,
        args: args
      )
    end

    it "folds Comparable#between? to Constant[true] when receiver is in range" do
      result = fold_types(constant_of(5), :between?, [constant_of(0), constant_of(10)])
      expect(result).to eq(constant_of(true))
    end

    it "folds Comparable#between? to Constant[false] when receiver is out of range" do
      result = fold_types(constant_of(100), :between?, [constant_of(0), constant_of(10)])
      expect(result).to eq(constant_of(false))
    end

    it "folds Comparable#clamp(min, max) to the lower bound when below the range" do
      result = fold_types(constant_of(-5), :clamp, [constant_of(0), constant_of(10)])
      expect(result).to eq(constant_of(0))
    end

    it "folds Comparable#clamp(min, max) to the upper bound when above the range" do
      result = fold_types(constant_of(100), :clamp, [constant_of(0), constant_of(10)])
      expect(result).to eq(constant_of(10))
    end

    it "folds Integer#pow(exp, mod) via the catalog" do
      # Modular exponentiation: `100.pow(50, 17) #=> 4`.
      result = fold_types(constant_of(100), :pow, [constant_of(50), constant_of(17)])
      expect(result).to eq(constant_of(4))
    end

    it "widens between? to a Union over a Constant union of receivers" do
      receivers = Rigor::Type::Combinator.union(constant_of(5), constant_of(100))
      result = fold_types(receivers, :between?, [constant_of(0), constant_of(10)])
      expect(result).to eq(
        Rigor::Type::Combinator.union(constant_of(true), constant_of(false))
      )
    end

    it "bails when an IntegerRange argument reaches the 2-arg path" do
      # IntegerRange args (vs IntegerRange receivers) still
      # decline; the v0.0.6 IntegerRange-aware ternary fold
      # only triggers for IntegerRange receivers paired with
      # scalar Constant args.
      receiver = constant_of(5)
      range_arg = Rigor::Type::Combinator.integer_range(0, 10)
      expect(fold_types(receiver, :between?, [range_arg, constant_of(20)])).to be_nil
    end

    describe "IntegerRange receiver — v0.0.6 ternary fold" do
      def integer_range(min, max) = Rigor::Type::Combinator.integer_range(min, max)

      it "folds int<3, 7>.between?(0, 10) to Constant[true] when fully inside" do
        result = fold_types(integer_range(3, 7), :between?, [constant_of(0), constant_of(10)])
        expect(result).to eq(constant_of(true))
      end

      it "folds int<20, 30>.between?(0, 10) to Constant[false] when fully outside" do
        result = fold_types(integer_range(20, 30), :between?, [constant_of(0), constant_of(10)])
        expect(result).to eq(constant_of(false))
      end

      it "widens int<3, 15>.between?(0, 10) to bool when partially overlapping" do
        result = fold_types(integer_range(3, 15), :between?, [constant_of(0), constant_of(10)])
        expect(result).to eq(
          Rigor::Type::Combinator.union(constant_of(true), constant_of(false))
        )
      end

      it "folds int<3, 7>.clamp(0, 10) to the same range (bracket contains range)" do
        result = fold_types(integer_range(3, 7), :clamp, [constant_of(0), constant_of(10)])
        expect(result).to eq(integer_range(3, 7))
      end

      it "folds int<3, 7>.clamp(4, 6) to int<4, 6> (intersection)" do
        result = fold_types(integer_range(3, 7), :clamp, [constant_of(4), constant_of(6)])
        expect(result).to eq(integer_range(4, 6))
      end

      it "collapses single-point clamp to a Constant" do
        result = fold_types(integer_range(3, 7), :clamp, [constant_of(5), constant_of(5)])
        expect(result).to eq(constant_of(5))
      end

      it "declines clamp when bracket excludes the range entirely" do
        # int<10, 20>.clamp(0, 5) — the bracket is fully below
        # the range, so every receiver value snaps to 5; the
        # fold declines so the RBS tier widens rather than the
        # dispatcher inventing the snap point.
        result = fold_types(integer_range(10, 20), :clamp, [constant_of(0), constant_of(5)])
        expect(result).to be_nil
      end

      it "declines when min > max in the bracket arguments" do
        result = fold_types(integer_range(3, 7), :between?, [constant_of(10), constant_of(0)])
        expect(result).to be_nil
      end

      it "still declines when an IntegerRange argument is passed alongside the range receiver" do
        result = fold_types(integer_range(3, 7), :between?, [integer_range(0, 5), constant_of(10)])
        expect(result).to be_nil
      end
    end

    describe "String#% format-string fold (v0.0.7)" do
      def constant_of(value) = Rigor::Type::Combinator.constant_of(value)
      def tuple_of(*elems) = Rigor::Type::Combinator.tuple_of(*elems)
      def hash_shape_of(pairs) = Rigor::Type::Combinator.hash_shape_of(pairs)

      it "folds Constant<String> % Tuple of Constants to a precise String" do
        result = fold_types(constant_of("%d / %d"), :%, [tuple_of(constant_of(1), constant_of(2))])
        expect(result).to eq(constant_of("1 / 2"))
      end

      it "folds Constant<String> % HashShape of Constants for hash format specs" do
        shape = hash_shape_of(name: constant_of("Alice"), age: constant_of(30))
        # The format template uses Ruby's `%{key}` hash-format
        # spec. Build it from String#new to keep the rubocop
        # FormatStringToken cop quiet (the cop only inspects
        # interpolated string literals).
        template = String.new("%") << "{name} is " << "%" << "{age}"
        result = fold_types(constant_of(template), :%, [shape])
        expect(result).to eq(constant_of("Alice is 30"))
      end

      it "still folds the single-Constant arg case via the standard binary path" do
        result = fold_types(constant_of("hi %s"), :%, [constant_of("world")])
        expect(result).to eq(constant_of("hi world"))
      end

      it "declines when a Tuple element is non-Constant" do
        tup = tuple_of(constant_of(1), Rigor::Type::Combinator.nominal_of("Integer"))
        expect(fold_types(constant_of("%d / %d"), :%, [tup])).to be_nil
      end

      it "declines on a malformed format spec (no crash)" do
        # `%q` is not a recognised String#% conversion; Ruby raises
        # `ArgumentError`. The fold catches the exception and falls
        # through.
        expect(fold_types(constant_of("%q"), :%, [tuple_of(constant_of(1))])).to be_nil
      end

      it "declines for non-String receivers" do
        # Sanity: `Constant<Integer> % Constant<Integer>` still flows
        # through the standard numeric binary path (modulo).
        expect(fold_types(constant_of(7), :%, [constant_of(3)])).to eq(constant_of(1))
      end
    end

    describe "Constant<Range> unary precision (v0.0.7)" do
      def tuple_of(*elems) = Rigor::Type::Combinator.tuple_of(*elems)

      it "lifts (1..3).to_a to a per-position Tuple" do
        result = fold_types(constant_of(1..3), :to_a)
        expect(result).to eq(tuple_of(constant_of(1), constant_of(2), constant_of(3)))
      end

      it "lifts (1...4).to_a to the same Tuple (exclusive end)" do
        result = fold_types(constant_of(1...4), :to_a)
        expect(result).to eq(tuple_of(constant_of(1), constant_of(2), constant_of(3)))
      end

      it "declines (1..100).to_a when the cardinality exceeds RANGE_TO_A_LIMIT" do
        # The fold returns nil so RBS widens to `Array[Integer]`.
        expect(fold_types(constant_of(1..100), :to_a)).to be_nil
      end

      it "lifts (1..5).first to Constant[1]" do
        expect(fold_types(constant_of(1..5), :first)).to eq(constant_of(1))
      end

      it "lifts (1..5).last to Constant[5]" do
        expect(fold_types(constant_of(1..5), :last)).to eq(constant_of(5))
      end

      it "lifts (1..5).min to Constant[1]" do
        expect(fold_types(constant_of(1..5), :min)).to eq(constant_of(1))
      end

      it "lifts (1..5).max to Constant[5]" do
        expect(fold_types(constant_of(1..5), :max)).to eq(constant_of(5))
      end

      it "lifts (1..5).count / .size / .length to Constant[5]" do
        %i[count size length].each do |m|
          expect(fold_types(constant_of(1..5), m)).to eq(constant_of(5))
        end
      end

      it "yields Constant[nil] for an empty range's first/last/min/max" do
        empty = constant_of(5...5)
        expect(fold_types(empty, :first)).to eq(constant_of(nil))
        expect(fold_types(empty, :last)).to eq(constant_of(nil))
      end

      it "yields the empty Tuple for an empty range's to_a" do
        expect(fold_types(constant_of(5...5), :to_a)).to eq(tuple_of)
      end

      it "still declines for non-integer-bounded ranges" do
        # Float ranges decline because the elements would not be a
        # finite enumerable; RBS tier widens.
        expect(fold_types(constant_of(1.0..2.0), :to_a)).to be_nil
      end
    end
  end
end
