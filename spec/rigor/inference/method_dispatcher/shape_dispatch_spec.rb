# frozen_string_literal: true

RSpec.describe Rigor::Inference::MethodDispatcher::ShapeDispatch do
  def constant(value)
    Rigor::Type::Combinator.constant_of(value)
  end

  def tuple(*elements)
    Rigor::Type::Combinator.tuple_of(*elements)
  end

  def hash_shape(pairs)
    Rigor::Type::Combinator.hash_shape_of(pairs)
  end

  def dispatch(receiver:, method_name:, args: [])
    described_class.try_dispatch(cc(receiver: receiver, method_name: method_name, args: args))
  end

  describe "Tuple element access" do
    let(:t) { tuple(constant(1), constant(2), constant(3)) }

    it "returns the precise element for `tuple[i]` with a static index" do
      expect(dispatch(receiver: t, method_name: :[], args: [constant(0)])).to eq(constant(1))
      expect(dispatch(receiver: t, method_name: :[], args: [constant(2)])).to eq(constant(3))
    end

    it "supports negative indices" do
      expect(dispatch(receiver: t, method_name: :[], args: [constant(-1)])).to eq(constant(3))
      expect(dispatch(receiver: t, method_name: :[], args: [constant(-3)])).to eq(constant(1))
    end

    it "falls through (nil) for out-of-range indices" do
      expect(dispatch(receiver: t, method_name: :[], args: [constant(3)])).to be_nil
      expect(dispatch(receiver: t, method_name: :[], args: [constant(-4)])).to be_nil
    end

    it "returns a sliced Tuple for `tuple[start, length]`" do
      result = dispatch(receiver: t, method_name: :[], args: [constant(1), constant(2)])
      expect(result).to eq(tuple(constant(2), constant(3)))
    end

    it "returns Constant[nil] for statically nil start-length slices" do
      expect(dispatch(receiver: t, method_name: :[], args: [constant(4), constant(1)])).to eq(constant(nil))
      expect(dispatch(receiver: t, method_name: :[], args: [constant(1), constant(-1)])).to eq(constant(nil))
    end

    it "returns a sliced Tuple for `tuple[range]`" do
      expect(dispatch(receiver: t, method_name: :[], args: [constant(0..1)])).to eq(tuple(constant(1), constant(2)))
      expect(dispatch(receiver: t, method_name: :[], args: [constant(1...3)])).to eq(tuple(constant(2), constant(3)))
      expect(dispatch(receiver: t, method_name: :[], args: [constant(1..)])).to eq(tuple(constant(2), constant(3)))
    end

    it "returns Constant[nil] for statically nil range slices" do
      expect(dispatch(receiver: t, method_name: :[], args: [constant(4..5)])).to eq(constant(nil))
    end

    it "does not claim fetch with Range or start-length arguments" do
      expect(dispatch(receiver: t, method_name: :fetch, args: [constant(0..1)])).to be_nil
      expect(dispatch(receiver: t, method_name: :fetch, args: [constant(0), constant(1)])).to be_nil
    end

    it "treats `fetch(i)` like `[]` when the index is in range" do
      expect(dispatch(receiver: t, method_name: :fetch, args: [constant(1)])).to eq(constant(2))
    end

    it "falls through for `fetch(out_of_range)` so RbsDispatch handles the projection" do
      expect(dispatch(receiver: t, method_name: :fetch, args: [constant(99)])).to be_nil
    end

    # `Array#slice` is an exact alias of `Array#[]`, so it folds identically
    # across the integer / Range / start-length forms.
    it "folds `tuple.slice(i)` like `tuple[i]`, including negative indices" do
      expect(dispatch(receiver: t, method_name: :slice, args: [constant(0)])).to eq(constant(1))
      expect(dispatch(receiver: t, method_name: :slice, args: [constant(-1)])).to eq(constant(3))
    end

    it "folds `tuple.slice(start, length)` and `tuple.slice(range)`" do
      expect(dispatch(receiver: t, method_name: :slice, args: [constant(1), constant(2)]))
        .to eq(tuple(constant(2), constant(3)))
      expect(dispatch(receiver: t, method_name: :slice, args: [constant(0..1)]))
        .to eq(tuple(constant(1), constant(2)))
    end

    it "falls through for `slice(out_of_range)` like `[]`" do
      expect(dispatch(receiver: t, method_name: :slice, args: [constant(3)])).to be_nil
    end

    it "returns the first element for `tuple.first`" do
      expect(dispatch(receiver: t, method_name: :first)).to eq(constant(1))
    end

    it "returns Constant[nil] for `[].first` (empty tuple)" do
      expect(dispatch(receiver: tuple, method_name: :first)).to eq(constant(nil))
    end

    it "returns the last element for `tuple.last`" do
      expect(dispatch(receiver: t, method_name: :last)).to eq(constant(3))
    end

    it "returns the size as a Constant for size/length/count" do
      expect(dispatch(receiver: t, method_name: :size)).to eq(constant(3))
      expect(dispatch(receiver: t, method_name: :length)).to eq(constant(3))
      expect(dispatch(receiver: t, method_name: :count)).to eq(constant(3))
    end

    it "falls through when the index argument is non-static" do
      dyn = Rigor::Type::Combinator.untyped
      expect(dispatch(receiver: t, method_name: :[], args: [dyn])).to be_nil
    end

    it "falls through for non-integer keys on a Tuple" do
      expect(dispatch(receiver: t, method_name: :[], args: [constant(:a)])).to be_nil
    end

    it "falls through for methods outside the catalogue" do
      # `:map` is not handled by ShapeDispatch — element-wise
      # block re-evaluation lives in `ExpressionTyper` (v0.0.6
      # phase 2). `:reverse` IS handled by ShapeDispatch as of
      # v0.0.7, so the existing assertion shifts to a method that
      # has not been catalogued.
      expect(dispatch(receiver: t, method_name: :map)).to be_nil
      expect(dispatch(receiver: t, method_name: :weird_method)).to be_nil
    end

    it "ignores arity mismatches by returning nil" do
      # `tuple.first(2)` is the Slice-4 RBS overload; we let RbsDispatch
      # handle it through the projection so the precise tier doesn't
      # accidentally claim ownership.
      expect(dispatch(receiver: t, method_name: :first, args: [constant(2)])).to be_nil
    end

    describe "Tuple unary precision (v0.0.7)" do
      let(:numeric_t) { tuple(constant(1), constant(2), constant(3)) }
      let(:mixed_t) { tuple(constant(1), constant("x"), constant(:foo)) }

      it "folds empty? per the tuple's known arity" do
        expect(dispatch(receiver: tuple, method_name: :empty?)).to eq(constant(true))
        expect(dispatch(receiver: numeric_t, method_name: :empty?)).to eq(constant(false))
      end

      it "folds any? for an empty / non-empty tuple" do
        expect(dispatch(receiver: tuple, method_name: :any?)).to eq(constant(false))
        expect(dispatch(receiver: numeric_t, method_name: :any?)).to eq(constant(true))
      end

      it "folds all? to true on a tuple whose every element is provably truthy" do
        expect(dispatch(receiver: numeric_t, method_name: :all?)).to eq(constant(true))
        expect(dispatch(receiver: tuple, method_name: :all?)).to eq(constant(true))
      end

      it "folds all? to false when any element is provably falsey" do
        falsey = tuple(constant(1), constant(nil), constant(2))
        expect(dispatch(receiver: falsey, method_name: :all?)).to eq(constant(false))
      end

      it "folds none? to true when every element is provably falsey" do
        all_falsey = tuple(constant(nil), constant(false))
        expect(dispatch(receiver: all_falsey, method_name: :none?)).to eq(constant(true))
        expect(dispatch(receiver: tuple, method_name: :none?)).to eq(constant(true))
      end

      it "folds include?(needle) to a precise bool when comparable to Constants" do
        expect(dispatch(receiver: numeric_t, method_name: :include?, args: [constant(2)]))
          .to eq(constant(true))
        expect(dispatch(receiver: numeric_t, method_name: :include?, args: [constant(99)]))
          .to eq(constant(false))
      end

      it "folds sum across numeric Constant elements" do
        expect(dispatch(receiver: numeric_t, method_name: :sum)).to eq(constant(6))
        expect(dispatch(receiver: tuple, method_name: :sum)).to eq(constant(0))
      end

      it "declines sum when an element is non-numeric" do
        expect(dispatch(receiver: mixed_t, method_name: :sum)).to be_nil
      end

      it "folds join with no separator and a Constant String separator" do
        expect(dispatch(receiver: numeric_t, method_name: :join)).to eq(constant("123"))
        expect(dispatch(receiver: numeric_t, method_name: :join, args: [constant("-")]))
          .to eq(constant("1-2-3"))
      end

      it "declines join with a non-Constant-String separator" do
        expect(dispatch(receiver: numeric_t, method_name: :join, args: [constant(0)])).to be_nil
      end

      it "folds min / max on comparable Constant elements" do
        expect(dispatch(receiver: numeric_t, method_name: :min)).to eq(constant(1))
        expect(dispatch(receiver: numeric_t, method_name: :max)).to eq(constant(3))
      end

      it "folds min / max to Constant[nil] on the empty tuple" do
        expect(dispatch(receiver: tuple, method_name: :min)).to eq(constant(nil))
        expect(dispatch(receiver: tuple, method_name: :max)).to eq(constant(nil))
      end

      it "folds min(n) / max(n) to a Tuple in Ruby's order (min ascending, max descending)" do
        unsorted = tuple(constant(3), constant(1), constant(4), constant(1), constant(5))
        expect(dispatch(receiver: unsorted, method_name: :min, args: [constant(2)]))
          .to eq(tuple(constant(1), constant(1)))
        expect(dispatch(receiver: unsorted, method_name: :max, args: [constant(2)]))
          .to eq(tuple(constant(5), constant(4)))
        # n >= size returns every element sorted; n == 0 is the empty Tuple.
        expect(dispatch(receiver: numeric_t, method_name: :min, args: [constant(9)]))
          .to eq(tuple(constant(1), constant(2), constant(3)))
        expect(dispatch(receiver: numeric_t, method_name: :max, args: [constant(0)])).to eq(tuple)
      end

      it "declines min(n) / max(n) on a non-static or negative count" do
        expect(dispatch(receiver: numeric_t, method_name: :min, args: [constant(-1)])).to be_nil
        expect(dispatch(receiver: numeric_t, method_name: :max, args: [Rigor::Type::Combinator.untyped]))
          .to be_nil
      end

      it "folds minmax to a Tuple[min, max] of comparable Constant elements" do
        unsorted = tuple(constant(3), constant(1), constant(2))
        expect(dispatch(receiver: unsorted, method_name: :minmax))
          .to eq(Rigor::Type::Combinator.tuple_of(constant(1), constant(3)))
      end

      it "folds minmax to Tuple[nil, nil] on the empty tuple" do
        expect(dispatch(receiver: tuple, method_name: :minmax))
          .to eq(Rigor::Type::Combinator.tuple_of(constant(nil), constant(nil)))
      end

      it "declines minmax on incomparable mixed-class Constant elements" do
        mixed = tuple(constant(1), constant("a"))
        expect(dispatch(receiver: mixed, method_name: :minmax)).to be_nil
      end

      it "folds sort to a per-position Tuple of sorted Constants" do
        unsorted = tuple(constant(3), constant(1), constant(2))
        expect(dispatch(receiver: unsorted, method_name: :sort))
          .to eq(Rigor::Type::Combinator.tuple_of(constant(1), constant(2), constant(3)))
      end

      it "folds reverse to a per-position Tuple in reversed order" do
        expect(dispatch(receiver: numeric_t, method_name: :reverse))
          .to eq(Rigor::Type::Combinator.tuple_of(constant(3), constant(2), constant(1)))
      end

      it "folds to_a to the tuple itself" do
        expect(dispatch(receiver: numeric_t, method_name: :to_a)).to eq(numeric_t)
      end
    end

    describe "Tuple#values_at (Slice 5 phase 2)" do
      let(:t) { tuple(constant(1), constant(2), constant(3)) }

      it "returns a Tuple of per-index elements for static integer indices" do
        result = dispatch(receiver: t, method_name: :values_at, args: [constant(0), constant(2)])
        expect(result).to be_a(Rigor::Type::Tuple)
        expect(result.elements.map(&:value)).to eq([1, 3])
      end

      it "supports negative indices" do
        result = dispatch(receiver: t, method_name: :values_at, args: [constant(-1)])
        expect(result.elements.map(&:value)).to eq([3])
      end

      it "fills out-of-range indices with Constant[nil]" do
        result = dispatch(receiver: t, method_name: :values_at, args: [constant(0), constant(5)])
        expect(result.elements.map(&:value)).to eq([1, nil])
      end

      it "falls through when any argument is non-static" do
        dyn = Rigor::Type::Combinator.untyped
        expect(dispatch(receiver: t, method_name: :values_at, args: [constant(0), dyn])).to be_nil
      end

      it "falls through when called with no arguments" do
        expect(dispatch(receiver: t, method_name: :values_at, args: [])).to be_nil
      end
    end

    describe "Tuple#+ (concatenation) (Slice 5 phase 2)" do
      let(:a) { tuple(constant(1), constant(2)) }
      let(:b) { tuple(constant(3), constant(4)) }

      it "concatenates two Tuples" do
        result = dispatch(receiver: a, method_name: :+, args: [b])
        expect(result).to be_a(Rigor::Type::Tuple)
        expect(result.elements.map(&:value)).to eq([1, 2, 3, 4])
      end

      it "falls through when the argument is not a Tuple" do
        nominal_arr = Rigor::Type::Combinator.nominal_of("Array", type_args: [constant(0)])
        expect(dispatch(receiver: a, method_name: :+, args: [nominal_arr])).to be_nil
      end

      it "falls through when called with no arguments" do
        expect(dispatch(receiver: a, method_name: :+, args: [])).to be_nil
      end
    end

    describe "Tuple#compact (Slice 5 phase 2)" do
      it "removes Constant[nil] entries from a Tuple" do
        t = tuple(constant(1), constant(nil), constant(3))
        result = dispatch(receiver: t, method_name: :compact)
        expect(result.elements.map(&:value)).to eq([1, 3])
      end

      it "returns the same Tuple when no nil entries" do
        t = tuple(constant(1), constant(2))
        result = dispatch(receiver: t, method_name: :compact)
        expect(result).to eq(t)
      end

      it "declines when an element is non-Constant" do
        mixed = tuple(constant(1), Rigor::Type::Combinator.nominal_of("Integer"))
        expect(dispatch(receiver: mixed, method_name: :compact)).to be_nil
      end
    end

    describe "Tuple#take (Slice 5 phase 2)" do
      let(:t) { tuple(constant(1), constant(2), constant(3)) }

      it "returns the first n elements" do
        result = dispatch(receiver: t, method_name: :take, args: [constant(2)])
        expect(result.elements.map(&:value)).to eq([1, 2])
      end

      it "returns the empty Tuple for n <= 0" do
        result = dispatch(receiver: t, method_name: :take, args: [constant(0)])
        expect(result.elements).to be_empty
      end

      it "returns the full Tuple when n >= size" do
        result = dispatch(receiver: t, method_name: :take, args: [constant(10)])
        expect(result.elements.map(&:value)).to eq([1, 2, 3])
      end

      it "falls through when the argument is non-static" do
        dyn = Rigor::Type::Combinator.untyped
        expect(dispatch(receiver: t, method_name: :take, args: [dyn])).to be_nil
      end

      it "falls through when called with no arguments" do
        expect(dispatch(receiver: t, method_name: :take, args: [])).to be_nil
      end

      it "falls through on a negative count (Array#take raises)" do
        expect(dispatch(receiver: t, method_name: :take, args: [constant(-1)])).to be_nil
      end
    end

    describe "Tuple#drop" do
      let(:t) { tuple(constant(1), constant(2), constant(3)) }

      it "drops the first n elements" do
        expect(dispatch(receiver: t, method_name: :drop, args: [constant(1)]).elements.map(&:value)).to eq([2, 3])
      end

      it "returns the empty Tuple when n >= size" do
        expect(dispatch(receiver: t, method_name: :drop, args: [constant(9)]).elements).to be_empty
      end

      it "falls through on a negative count (Array#drop raises)" do
        expect(dispatch(receiver: t, method_name: :drop, args: [constant(-1)])).to be_nil
      end
    end

    describe "Tuple#rotate" do
      let(:t) { tuple(constant(1), constant(2), constant(3)) }

      it "rotates left by one with no argument" do
        expect(dispatch(receiver: t, method_name: :rotate, args: []).elements.map(&:value)).to eq([2, 3, 1])
      end

      it "rotates left by n" do
        expect(dispatch(receiver: t, method_name: :rotate, args: [constant(2)]).elements.map(&:value)).to eq([3, 1, 2])
      end

      it "rotates right on a negative n (Array#rotate modulo)" do
        expect(dispatch(receiver: t, method_name: :rotate, args: [constant(-1)]).elements.map(&:value)).to eq([3, 1, 2])
      end
    end

    describe "Tuple#uniq" do
      it "keeps the first occurrence of each distinct value" do
        t = tuple(constant(1), constant(2), constant(2), constant(3), constant(1))
        expect(dispatch(receiver: t, method_name: :uniq).elements.map(&:value)).to eq([1, 2, 3])
      end

      it "falls through with a block (args present) or mixed non-constant elements" do
        dyn = tuple(constant(1), Rigor::Type::Combinator.untyped)
        expect(dispatch(receiver: dyn, method_name: :uniq)).to be_nil
      end
    end

    describe "Tuple#index / #find_index / #rindex" do
      let(:t) { tuple(constant(:a), constant(:b), constant(:a)) }

      it "index / find_index return the first matching index" do
        expect(dispatch(receiver: t, method_name: :index, args: [constant(:a)])).to eq(constant(0))
        expect(dispatch(receiver: t, method_name: :find_index, args: [constant(:b)])).to eq(constant(1))
      end

      it "rindex returns the last matching index" do
        expect(dispatch(receiver: t, method_name: :rindex, args: [constant(:a)])).to eq(constant(2))
      end

      it "returns Constant[nil] when nothing matches" do
        expect(dispatch(receiver: t, method_name: :index, args: [constant(:z)])).to eq(constant(nil))
      end

      it "falls through for the block form (no argument)" do
        expect(dispatch(receiver: t, method_name: :index, args: [])).to be_nil
      end
    end

    describe "Tuple#zip per-position fold (v0.0.7)" do
      it "pairs receiver and other-Tuple per position" do
        a = tuple(constant(1), constant(2), constant(3))
        b = Rigor::Type::Combinator.tuple_of(constant(4), constant(5), constant(6))
        result = dispatch(receiver: a, method_name: :zip, args: [b])
        expect(result).to be_a(Rigor::Type::Tuple)
        expect(result.elements.map { |e| e.elements.map(&:value) })
          .to eq([[1, 4], [2, 5], [3, 6]])
      end

      it "pads short other Tuples with Constant[nil]" do
        a = tuple(constant(1), constant(2), constant(3))
        b = Rigor::Type::Combinator.tuple_of(constant(4), constant(5))
        result = dispatch(receiver: a, method_name: :zip, args: [b])
        expect(result.elements.last.elements.last).to eq(constant(nil))
      end

      it "supports multi-arg zip (3-tuple positions)" do
        a = tuple(constant(1), constant(2))
        b = Rigor::Type::Combinator.tuple_of(constant(10), constant(20))
        c = Rigor::Type::Combinator.tuple_of(constant(100), constant(200))
        result = dispatch(receiver: a, method_name: :zip, args: [b, c])
        expect(result.elements.map { |e| e.elements.map(&:value) })
          .to eq([[1, 10, 100], [2, 20, 200]])
      end

      it "declines when an arg is not a Tuple" do
        a = tuple(constant(1), constant(2))
        nominal_arr = Rigor::Type::Combinator.nominal_of("Array", type_args: [constant(0)])
        expect(dispatch(receiver: a, method_name: :zip, args: [nominal_arr])).to be_nil
      end
    end

    describe "Tuple#to_h shape conversion (v0.0.7)" do
      it "folds a Tuple of 2-Tuples whose first element is a Constant to a HashShape" do
        pair_a = Rigor::Type::Combinator.tuple_of(constant(:a), constant(1))
        pair_b = Rigor::Type::Combinator.tuple_of(constant(:b), constant(2))
        result = dispatch(receiver: tuple(pair_a, pair_b), method_name: :to_h)
        expect(result).to eq(Rigor::Type::Combinator.hash_shape_of(a: constant(1), b: constant(2)))
      end

      it "folds an empty Tuple to the empty HashShape" do
        expect(dispatch(receiver: tuple, method_name: :to_h))
          .to eq(Rigor::Type::Combinator.hash_shape_of({}))
      end

      it "declines when an inner pair is not 2-element" do
        bad = Rigor::Type::Combinator.tuple_of(constant(:a), constant(1), constant(2))
        expect(dispatch(receiver: tuple(bad), method_name: :to_h)).to be_nil
      end

      it "declines when a pair's key is non-Constant" do
        nominal_key = Rigor::Type::Combinator.nominal_of("Symbol")
        bad = Rigor::Type::Combinator.tuple_of(nominal_key, constant(1))
        expect(dispatch(receiver: tuple(bad), method_name: :to_h)).to be_nil
      end

      it "declines on duplicate keys" do
        pair_a1 = Rigor::Type::Combinator.tuple_of(constant(:a), constant(1))
        pair_a2 = Rigor::Type::Combinator.tuple_of(constant(:a), constant(2))
        expect(dispatch(receiver: tuple(pair_a1, pair_a2), method_name: :to_h)).to be_nil
      end
    end
  end

  describe "HashShape element access" do
    let(:shape) { hash_shape(a: constant(1), b: constant("two")) }

    it "returns the precise value for `shape[k]` with a static key" do
      expect(dispatch(receiver: shape, method_name: :[], args: [constant(:a)])).to eq(constant(1))
      expect(dispatch(receiver: shape, method_name: :[], args: [constant(:b)])).to eq(constant("two"))
    end

    it "returns Constant[nil] for `[]` on a missing key" do
      expect(dispatch(receiver: shape, method_name: :[], args: [constant(:missing)])).to eq(constant(nil))
    end

    it "returns Constant[nil] for `dig` on a missing key" do
      expect(dispatch(receiver: shape, method_name: :dig, args: [constant(:missing)])).to eq(constant(nil))
    end

    it "resolves `fetch(k)` to the precise value when k is present" do
      expect(dispatch(receiver: shape, method_name: :fetch, args: [constant(:a)])).to eq(constant(1))
    end

    it "falls through (nil) for `fetch(missing)` so RbsDispatch handles the projection" do
      # `fetch` raises at runtime; the precise tier defers rather than
      # manufacturing a Constant[nil] the runtime would never produce.
      expect(dispatch(receiver: shape, method_name: :fetch, args: [constant(:missing)])).to be_nil
    end

    it "supports string keys" do
      string_shape = hash_shape("k" => constant(42))
      expect(dispatch(receiver: string_shape, method_name: :[], args: [constant("k")])).to eq(constant(42))
    end

    it "returns size/length as a Constant" do
      expect(dispatch(receiver: shape, method_name: :size)).to eq(constant(2))
      expect(dispatch(receiver: shape, method_name: :length)).to eq(constant(2))
    end

    it "falls through for open-shape size because extra keys are possible" do
      open_shape = Rigor::Type::Combinator.hash_shape_of({ a: constant(1) }, extra_keys: :open)
      expect(dispatch(receiver: open_shape, method_name: :size)).to be_nil
    end

    it "adds nil for optional-key reads" do
      optional_shape = Rigor::Type::Combinator.hash_shape_of(
        { a: constant(1), b: constant("two") },
        optional_keys: [:b]
      )
      expected = Rigor::Type::Combinator.union(constant("two"), constant(nil))
      expect(dispatch(receiver: optional_shape, method_name: :[], args: [constant(:b)])).to eq(expected)
      expect(dispatch(receiver: optional_shape, method_name: :dig, args: [constant(:b)])).to eq(expected)
      expect(dispatch(receiver: optional_shape, method_name: :fetch, args: [constant(:b)])).to be_nil
      expect(dispatch(receiver: optional_shape, method_name: :size)).to be_nil
    end

    it "falls through for non-static keys" do
      dyn = Rigor::Type::Combinator.untyped
      expect(dispatch(receiver: shape, method_name: :[], args: [dyn])).to be_nil
    end

    it "falls through for non-Symbol/String keys" do
      expect(dispatch(receiver: shape, method_name: :[], args: [constant(1)])).to be_nil
    end

    it "falls through for multi-arg dig when the intermediate is a non-shape Constant" do
      # shape.dig(:a, :b) — :a resolves to Constant[1], which is
      # neither nil nor a shape, so the chain cannot continue.
      expect(dispatch(receiver: shape, method_name: :dig, args: [constant(:a), constant(:b)])).to be_nil
    end

    it "folds keys to a Tuple of Constant<Symbol> for a closed shape (v0.0.7)" do
      expect(dispatch(receiver: shape, method_name: :keys))
        .to eq(Rigor::Type::Combinator.tuple_of(constant(:a), constant(:b)))
    end

    it "folds values to a Tuple of per-key entry types for a closed shape (v0.0.7)" do
      expect(dispatch(receiver: shape, method_name: :values))
        .to eq(Rigor::Type::Combinator.tuple_of(constant(1), constant("two")))
    end

    it "folds count to Constant<size> for a closed shape (v0.0.7)" do
      expect(dispatch(receiver: shape, method_name: :count)).to eq(constant(2))
    end

    it "folds empty? to Constant<false> for a non-empty closed shape (v0.0.7)" do
      expect(dispatch(receiver: shape, method_name: :empty?)).to eq(constant(false))
    end

    it "folds empty? to Constant<true> for an empty closed shape (v0.0.7)" do
      empty_shape = Rigor::Type::Combinator.hash_shape_of({})
      expect(dispatch(receiver: empty_shape, method_name: :empty?)).to eq(constant(true))
    end

    it "folds any? to Constant<true> for a non-empty closed shape (v0.0.7)" do
      expect(dispatch(receiver: shape, method_name: :any?)).to eq(constant(true))
    end

    it "folds to_a to a per-entry Tuple of 2-Tuples (v0.0.7)" do
      result = dispatch(receiver: shape, method_name: :to_a)
      expect(result).to be_a(Rigor::Type::Tuple)
      expect(result.elements.map { |e| e.elements.map(&:value) })
        .to eq([[:a, 1], [:b, "two"]])
    end

    it "folds to_h to the receiver shape itself" do
      expect(dispatch(receiver: shape, method_name: :to_h)).to eq(shape)
    end

    it "folds first to a 2-Tuple of (first key, first value) (v0.0.7)" do
      expect(dispatch(receiver: shape, method_name: :first))
        .to eq(Rigor::Type::Combinator.tuple_of(constant(:a), constant(1)))
    end

    it "folds first to Constant[nil] for an empty closed shape (v0.0.7)" do
      empty = Rigor::Type::Combinator.hash_shape_of({})
      expect(dispatch(receiver: empty, method_name: :first)).to eq(constant(nil))
    end

    it "folds flatten to a per-position [k_1, v_1, k_2, v_2, …] Tuple (v0.0.7)" do
      expect(dispatch(receiver: shape, method_name: :flatten))
        .to eq(Rigor::Type::Combinator.tuple_of(constant(:a), constant(1), constant(:b), constant("two")))
    end

    it "folds compact to drop Constant[nil] entries (v0.0.7)" do
      with_nil = hash_shape(a: constant(1), b: constant(nil), c: constant(3))
      expect(dispatch(receiver: with_nil, method_name: :compact))
        .to eq(hash_shape(a: constant(1), c: constant(3)))
    end

    it "declines compact when a value is non-Constant (no decidable nil set)" do
      mixed = hash_shape(a: constant(1), b: Rigor::Type::Combinator.nominal_of("Integer"))
      expect(dispatch(receiver: mixed, method_name: :compact)).to be_nil
    end

    it "folds invert to a HashShape with values as keys when values are Symbols" do
      symbol_valued = hash_shape(a: constant(:one), b: constant(:two))
      result = dispatch(receiver: symbol_valued, method_name: :invert)
      expect(result).to eq(hash_shape(one: constant(:a), two: constant(:b)))
    end

    it "declines invert when values are Integers (HashShape keys must be Symbol or String)" do
      expect(dispatch(receiver: shape, method_name: :invert)).to be_nil
    end

    it "declines invert on duplicate values" do
      dup = hash_shape(a: constant(:x), b: constant(:x))
      expect(dispatch(receiver: dup, method_name: :invert)).to be_nil
    end

    it "folds merge of two closed HashShapes" do
      other = hash_shape(c: constant(true))
      result = dispatch(receiver: shape, method_name: :merge, args: [other])
      expect(result).to eq(hash_shape(a: constant(1), b: constant("two"), c: constant(true)))
    end

    it "right-hand entries override left-hand entries on key collision in merge" do
      override = hash_shape(a: constant(99))
      result = dispatch(receiver: shape, method_name: :merge, args: [override])
      expect(result).to eq(hash_shape(a: constant(99), b: constant("two")))
    end

    it "falls through for unrecognised method names" do
      expect(dispatch(receiver: shape, method_name: :weird_method)).to be_nil
    end
  end

  describe "Tuple#dig (Slice 5 phase 2 sub-phase 2)" do
    it "resolves a single-arg dig identically to []" do
      t = tuple(constant(10), constant(20))
      expect(dispatch(receiver: t, method_name: :dig, args: [constant(0)])).to eq(constant(10))
    end

    it "returns Constant[nil] for an out-of-range single-arg dig" do
      t = tuple(constant(10), constant(20))
      expect(dispatch(receiver: t, method_name: :dig, args: [constant(5)])).to eq(constant(nil))
    end

    it "chains Tuple -> HashShape lookups" do
      inner = hash_shape(name: constant("Alice"))
      t = tuple(inner, constant(42))
      expect(
        dispatch(receiver: t, method_name: :dig, args: [constant(0), constant(:name)])
      ).to eq(constant("Alice"))
    end

    it "returns Constant[nil] when a chain step misses on the inner HashShape" do
      inner = hash_shape(name: constant("Alice"))
      t = tuple(inner)
      expect(
        dispatch(receiver: t, method_name: :dig, args: [constant(0), constant(:missing)])
      ).to eq(constant(nil))
    end

    it "short-circuits on a Constant[nil] member of the chain" do
      t = tuple(constant(nil), constant(42))
      expect(
        dispatch(receiver: t, method_name: :dig, args: [constant(0), constant(:any)])
      ).to eq(constant(nil))
    end

    it "falls through when an intermediate is a non-shape, non-nil Constant" do
      t = tuple(constant(1))
      expect(
        dispatch(receiver: t, method_name: :dig, args: [constant(0), constant(:k)])
      ).to be_nil
    end

    it "falls through when the first arg is non-static" do
      t = tuple(constant(1), constant(2))
      dyn = Rigor::Type::Combinator.untyped
      expect(dispatch(receiver: t, method_name: :dig, args: [dyn])).to be_nil
    end
  end

  describe "HashShape#dig (Slice 5 phase 2 sub-phase 2)" do
    it "chains HashShape -> HashShape lookups" do
      inner = hash_shape(zip: constant("00000"))
      shape = hash_shape(addr: inner)
      expect(
        dispatch(receiver: shape, method_name: :dig, args: [constant(:addr), constant(:zip)])
      ).to eq(constant("00000"))
    end

    it "chains HashShape -> Tuple lookups" do
      inner = tuple(constant("a"), constant("b"))
      shape = hash_shape(letters: inner)
      expect(
        dispatch(receiver: shape, method_name: :dig, args: [constant(:letters), constant(1)])
      ).to eq(constant("b"))
    end

    it "returns Constant[nil] for a missing top-level key in a multi-arg dig" do
      shape = hash_shape(a: constant(1))
      expect(
        dispatch(receiver: shape, method_name: :dig, args: [constant(:missing), constant(:k)])
      ).to eq(constant(nil))
    end

    it "short-circuits on a nil intermediate" do
      shape = hash_shape(addr: constant(nil))
      expect(
        dispatch(receiver: shape, method_name: :dig, args: [constant(:addr), constant(:zip)])
      ).to eq(constant(nil))
    end
  end

  describe "HashShape#values_at (Slice 5 phase 2 sub-phase 2)" do
    let(:shape) { hash_shape(a: constant(1), b: constant("two")) }

    it "returns a Tuple of per-key values for static keys" do
      result = dispatch(receiver: shape, method_name: :values_at, args: [constant(:a), constant(:b)])
      expect(result).to be_a(Rigor::Type::Tuple)
      expect(result.elements).to eq([constant(1), constant("two")])
    end

    it "fills missing keys with Constant[nil]" do
      result = dispatch(receiver: shape, method_name: :values_at, args: [constant(:a), constant(:missing)])
      expect(result.elements).to eq([constant(1), constant(nil)])
    end

    it "supports a single-key call" do
      result = dispatch(receiver: shape, method_name: :values_at, args: [constant(:a)])
      expect(result.elements).to eq([constant(1)])
    end

    it "falls through when any argument is non-static" do
      dyn = Rigor::Type::Combinator.untyped
      expect(
        dispatch(receiver: shape, method_name: :values_at, args: [constant(:a), dyn])
      ).to be_nil
    end

    it "falls through when called with no arguments" do
      expect(dispatch(receiver: shape, method_name: :values_at, args: [])).to be_nil
    end
  end

  describe "HashShape#none? (no-arg, no-block)" do
    it "folds none? to Constant<true> for an empty closed shape" do
      empty = Rigor::Type::Combinator.hash_shape_of({})
      expect(dispatch(receiver: empty, method_name: :none?)).to eq(constant(true))
    end

    it "folds none? to Constant<false> for a non-empty closed shape" do
      shape = hash_shape(a: constant(1), b: constant("two"))
      expect(dispatch(receiver: shape, method_name: :none?)).to eq(constant(false))
    end

    it "falls through for open shapes" do
      open_shape = Rigor::Type::Combinator.hash_shape_of({ a: constant(1) }, extra_keys: :open)
      expect(dispatch(receiver: open_shape, method_name: :none?)).to be_nil
    end

    it "falls through when called with arguments" do
      shape = hash_shape(a: constant(1))
      expect(dispatch(receiver: shape, method_name: :none?, args: [constant(:a)])).to be_nil
    end
  end

  describe "HashShape#slice (Slice 5 phase 2)" do
    let(:shape) { hash_shape(a: constant(1), b: constant("two"), c: constant(true)) }

    it "returns a sub-HashShape containing only the specified keys" do
      result = dispatch(receiver: shape, method_name: :slice, args: [constant(:a), constant(:c)])
      expect(result).to eq(hash_shape(a: constant(1), c: constant(true)))
    end

    it "omits keys not present in the shape" do
      result = dispatch(receiver: shape, method_name: :slice, args: [constant(:a), constant(:missing)])
      expect(result).to eq(hash_shape(a: constant(1)))
    end

    it "supports string keys" do
      string_shape = hash_shape("x" => constant(1), "y" => constant(2))
      result = dispatch(receiver: string_shape, method_name: :slice, args: [constant("x")])
      expect(result).to eq(hash_shape("x" => constant(1)))
    end

    it "falls through for open shapes" do
      open_shape = Rigor::Type::Combinator.hash_shape_of({ a: constant(1) }, extra_keys: :open)
      expect(dispatch(receiver: open_shape, method_name: :slice, args: [constant(:a)])).to be_nil
    end

    it "falls through when any argument is non-static" do
      dyn = Rigor::Type::Combinator.untyped
      expect(dispatch(receiver: shape, method_name: :slice, args: [constant(:a), dyn])).to be_nil
    end

    it "falls through when called with no arguments" do
      expect(dispatch(receiver: shape, method_name: :slice, args: [])).to be_nil
    end

    it "returns keys in argument order, matching Ruby's Hash#slice semantics" do
      # Ruby's Hash#slice follows argument order, not receiver insertion order:
      # { a:, b:, c: }.slice(:c, :a) => { c:, a: }
      result = dispatch(receiver: shape, method_name: :slice, args: [constant(:c), constant(:a)])
      expect(result.pairs.keys).to eq(%i[c a])
    end
  end

  describe "HashShape#except (Slice 5 phase 2)" do
    let(:shape) { hash_shape(a: constant(1), b: constant("two"), c: constant(true)) }

    it "returns a sub-HashShape with the specified keys removed" do
      result = dispatch(receiver: shape, method_name: :except, args: [constant(:a)])
      expect(result).to eq(hash_shape(b: constant("two"), c: constant(true)))
    end

    it "ignores keys not present in the shape" do
      result = dispatch(receiver: shape, method_name: :except, args: [constant(:a), constant(:missing)])
      expect(result).to eq(hash_shape(b: constant("two"), c: constant(true)))
    end

    it "supports string keys" do
      string_shape = hash_shape("x" => constant(1), "y" => constant(2))
      result = dispatch(receiver: string_shape, method_name: :except, args: [constant("x")])
      expect(result).to eq(hash_shape("y" => constant(2)))
    end

    it "falls through for open shapes" do
      open_shape = Rigor::Type::Combinator.hash_shape_of({ a: constant(1) }, extra_keys: :open)
      expect(dispatch(receiver: open_shape, method_name: :except, args: [constant(:a)])).to be_nil
    end

    it "falls through when any argument is non-static" do
      dyn = Rigor::Type::Combinator.untyped
      expect(dispatch(receiver: shape, method_name: :except, args: [constant(:a), dyn])).to be_nil
    end

    it "falls through when called with no arguments" do
      expect(dispatch(receiver: shape, method_name: :except, args: [])).to be_nil
    end
  end

  describe "HashShape#has_key? / #key? / #member? / #include? (Slice 5 phase 2)" do
    let(:shape) { hash_shape(a: constant(1), b: constant("two")) }

    it "folds has_key? to Constant<true> for a known key" do
      expect(dispatch(receiver: shape, method_name: :has_key?, args: [constant(:a)])).to eq(constant(true))
    end

    it "folds has_key? to Constant<false> for a missing key" do
      expect(dispatch(receiver: shape, method_name: :has_key?, args: [constant(:missing)])).to eq(constant(false))
    end

    it "folds key? identically to has_key?" do
      expect(dispatch(receiver: shape, method_name: :key?, args: [constant(:b)])).to eq(constant(true))
      expect(dispatch(receiver: shape, method_name: :key?, args: [constant(:missing)])).to eq(constant(false))
    end

    it "folds member? identically to has_key?" do
      expect(dispatch(receiver: shape, method_name: :member?, args: [constant(:a)])).to eq(constant(true))
      expect(dispatch(receiver: shape, method_name: :member?, args: [constant(:missing)])).to eq(constant(false))
    end

    it "folds include? identically to has_key?" do
      expect(dispatch(receiver: shape, method_name: :include?, args: [constant(:a)])).to eq(constant(true))
      expect(dispatch(receiver: shape, method_name: :include?, args: [constant(:missing)])).to eq(constant(false))
    end

    it "supports string keys" do
      string_shape = hash_shape("k" => constant(42))
      present = dispatch(receiver: string_shape, method_name: :has_key?, args: [constant("k")])
      absent  = dispatch(receiver: string_shape, method_name: :has_key?, args: [constant("missing")])
      expect(present).to eq(constant(true))
      expect(absent).to eq(constant(false))
    end

    it "falls through for open shapes" do
      open_shape = Rigor::Type::Combinator.hash_shape_of({ a: constant(1) }, extra_keys: :open)
      expect(dispatch(receiver: open_shape, method_name: :has_key?, args: [constant(:a)])).to be_nil
    end

    it "falls through when the argument is non-static" do
      dyn = Rigor::Type::Combinator.untyped
      expect(dispatch(receiver: shape, method_name: :has_key?, args: [dyn])).to be_nil
    end

    it "falls through when the argument is not a Symbol or String" do
      expect(dispatch(receiver: shape, method_name: :has_key?, args: [constant(1)])).to be_nil
    end
  end

  describe "non-shape receivers" do
    it "returns nil for any non-Tuple/HashShape receiver (excluding the size tier below)" do
      expect(dispatch(receiver: constant(1), method_name: :first)).to be_nil
      nominal = Rigor::Type::Combinator.nominal_of(Array)
      expect(dispatch(receiver: nominal, method_name: :first)).to be_nil
    end
  end

  describe "Nominal#size / #length / #bytesize on container types" do
    def nominal(name) = Rigor::Type::Combinator.nominal_of(name)
    def non_negative_int = Rigor::Type::Combinator.non_negative_int

    it "tightens Array#size / #length / #count to non_negative_int" do
      %i[size length count].each do |sel|
        expect(dispatch(receiver: nominal("Array"), method_name: sel)).to eq(non_negative_int)
      end
    end

    it "tightens String#length / #size / #bytesize to non_negative_int" do
      %i[length size bytesize].each do |sel|
        expect(dispatch(receiver: nominal("String"), method_name: sel)).to eq(non_negative_int)
      end
    end

    it "tightens Hash / Set / Range #size to non_negative_int" do
      %w[Hash Set Range].each do |klass|
        expect(dispatch(receiver: nominal(klass), method_name: :size)).to eq(non_negative_int)
      end
    end

    it "declines for arity-bearing calls (size with an argument)" do
      expect(
        dispatch(receiver: nominal("Array"), method_name: :size, args: [constant(1)])
      ).to be_nil
    end

    it "declines for unrelated nominals" do
      expect(dispatch(receiver: nominal("Integer"), method_name: :size)).to be_nil
      expect(dispatch(receiver: nominal("Foo"), method_name: :length)).to be_nil
    end

    it "declines for non-size/length selectors on container nominals" do
      expect(dispatch(receiver: nominal("Array"), method_name: :first)).to be_nil
    end
  end

  describe "Refined<String> projections (v0.1.1 Track 1 slice 2)" do
    def universal_int = Rigor::Type::Combinator.universal_int

    context "with a decimal-int-string receiver" do
      let(:receiver) { Rigor::Type::Combinator.decimal_int_string }

      it "narrows `to_i` to universal-int (signed: `\"-7\".to_i == -7`)" do
        # The decimal-int-string predicate `/\A-?\d+\z/` admits a
        # leading sign, so a `"-7"` inhabitant parses to a negative
        # Integer — the result is a plain (signed) Integer, NOT
        # non-negative-int. `String#to_i` is total, so the projection
        # stays sound.
        expect(dispatch(receiver: receiver, method_name: :to_i)).to eq(universal_int)
      end

      it "narrows `to_int` to universal-int (signed)" do
        expect(dispatch(receiver: receiver, method_name: :to_int)).to eq(universal_int)
      end

      it "preserves the refinement across `#downcase` / `#upcase` (digit-only is case-invariant)" do
        expect(dispatch(receiver: receiver, method_name: :downcase)).to eq(receiver)
        expect(dispatch(receiver: receiver, method_name: :upcase)).to eq(receiver)
      end
    end

    context "with a numeric-string receiver" do
      let(:receiver) { Rigor::Type::Combinator.numeric_string }

      it "declines `to_i` / `to_int` — the full numeric-literal grammar is not non-negative-int" do
        # `"1.5".to_i` truncates, `"-3".to_i` is negative, `"2i"` is
        # not an Integer at all, so projecting to non-negative-int
        # would be unsound; the projection falls through to RBS Integer.
        expect(dispatch(receiver: receiver, method_name: :to_i)).to be_nil
        expect(dispatch(receiver: receiver, method_name: :to_int)).to be_nil
      end

      it "preserves the refinement across `#downcase` but drops to base String on `#upcase`" do
        # downcasing a numeric literal stays a valid literal (hex
        # digits / `0X` / `E` lowercase fine); upcasing breaks the
        # lowercase-only rational / imaginary suffixes (`"1r"` →
        # `"1R"`), so the refinement soundly drops to plain String.
        expect(dispatch(receiver: receiver, method_name: :downcase)).to eq(receiver)
        expect(dispatch(receiver: receiver, method_name: :upcase)).to eq(Rigor::Type::Combinator.nominal_of("String"))
      end
    end

    it "declines for `to_i` on non-digit refinements (lowercase/uppercase strings parse as 0)" do
      [Rigor::Type::Combinator.lowercase_string, Rigor::Type::Combinator.uppercase_string].each do |t|
        expect(dispatch(receiver: t, method_name: :to_i)).to be_nil
      end
    end

    it "declines for `to_i` with an explicit base argument (slice 2 covers no-arg only)" do
      receiver = Rigor::Type::Combinator.decimal_int_string
      expect(dispatch(receiver: receiver, method_name: :to_i, args: [constant(10)])).to be_nil
    end
  end

  describe "IntegerRange#to_s precision (v0.1.1 Track 1 slice 5b)" do
    let(:non_negative) { Rigor::Type::Combinator.non_negative_int }
    let(:positive) { Rigor::Type::Combinator.positive_int }
    let(:bounded_non_negative) { Rigor::Type::Combinator.integer_range(0, 99) }
    let(:negative) { Rigor::Type::Combinator.negative_int }
    let(:signed) { Rigor::Type::Combinator.integer_range(Rigor::Type::IntegerRange::NEG_INFINITY, 5) }

    it "narrows non-negative-int#to_s (no args) to decimal-int-string" do
      expect(dispatch(receiver: non_negative, method_name: :to_s))
        .to eq(Rigor::Type::Combinator.decimal_int_string)
    end

    it "narrows positive-int#to_s to decimal-int-string" do
      expect(dispatch(receiver: positive, method_name: :to_s))
        .to eq(Rigor::Type::Combinator.decimal_int_string)
    end

    it "narrows bounded non-negative range #to_s to decimal-int-string" do
      expect(dispatch(receiver: bounded_non_negative, method_name: :to_s))
        .to eq(Rigor::Type::Combinator.decimal_int_string)
    end

    it "narrows non-negative-int#to_s(16) to hex-int-string" do
      expect(dispatch(receiver: non_negative, method_name: :to_s, args: [constant(16)]))
        .to eq(Rigor::Type::Combinator.hex_int_string)
    end

    it "narrows non-negative-int#to_s(8) to octal-int-string" do
      expect(dispatch(receiver: non_negative, method_name: :to_s, args: [constant(8)]))
        .to eq(Rigor::Type::Combinator.octal_int_string)
    end

    it "declines for unsupported bases (binary, custom alphabets)" do
      [2, 7, 36].each do |b|
        expect(dispatch(receiver: non_negative, method_name: :to_s, args: [constant(b)])).to be_nil
      end
    end

    it "declines on signed ranges (the result could carry a leading `-`)" do
      expect(dispatch(receiver: negative, method_name: :to_s)).to be_nil
      expect(dispatch(receiver: signed, method_name: :to_s)).to be_nil
    end

    it "declines when the base argument is not a Constant<Integer>" do
      nominal_int = Rigor::Type::Combinator.nominal_of("Integer")
      expect(dispatch(receiver: non_negative, method_name: :to_s, args: [nominal_int])).to be_nil
    end

    it "declines for non-`to_s` selectors on IntegerRange receivers" do
      expect(dispatch(receiver: non_negative, method_name: :inspect)).to be_nil
    end
  end

  describe "HashShape mid/low-priority handlers (coverage uplift)" do
    let(:two) { hash_shape(a: constant(1), b: constant(2)) }
    let(:one) { hash_shape(a: constant(1)) }
    let(:empty) { hash_shape({}) }

    describe "one?" do
      it "folds to true for a single-pair shape" do
        expect(dispatch(receiver: one, method_name: :one?)).to eq(constant(true))
      end

      it "folds to false for a two-pair or empty shape" do
        expect(dispatch(receiver: two, method_name: :one?)).to eq(constant(false))
        expect(dispatch(receiver: empty, method_name: :one?)).to eq(constant(false))
      end
    end

    describe "entries / to_hash aliases" do
      it "treats entries as to_a" do
        expect(dispatch(receiver: one, method_name: :entries))
          .to eq(dispatch(receiver: one, method_name: :to_a))
      end

      it "treats to_hash as to_h (the receiver shape)" do
        expect(dispatch(receiver: two, method_name: :to_hash)).to eq(two)
      end
    end

    describe "deconstruct_keys" do
      it "returns the receiver shape unchanged" do
        expect(dispatch(receiver: two, method_name: :deconstruct_keys, args: [constant(nil)])).to eq(two)
      end
    end

    describe "fetch_values" do
      it "lifts present keys to a Tuple of values" do
        expect(dispatch(receiver: two, method_name: :fetch_values, args: [constant(:a), constant(:b)]))
          .to eq(tuple(constant(1), constant(2)))
      end

      it "declines when a requested key is missing (KeyError at runtime)" do
        expect(dispatch(receiver: two, method_name: :fetch_values, args: [constant(:a), constant(:z)]))
          .to be_nil
      end
    end

    describe "assoc" do
      it "returns Tuple[key, value] for a known key" do
        expect(dispatch(receiver: two, method_name: :assoc, args: [constant(:b)]))
          .to eq(tuple(constant(:b), constant(2)))
      end

      it "returns Constant[nil] for a missing key" do
        expect(dispatch(receiver: two, method_name: :assoc, args: [constant(:z)]))
          .to eq(constant(nil))
      end
    end

    describe "key (reverse lookup)" do
      it "returns the first matching key" do
        expect(dispatch(receiver: two, method_name: :key, args: [constant(2)])).to eq(constant(:b))
      end

      it "returns Constant[nil] when no value matches" do
        expect(dispatch(receiver: two, method_name: :key, args: [constant(99)])).to eq(constant(nil))
      end
    end

    describe "rassoc (reverse of assoc)" do
      it "returns Tuple[key, value] for the first matching value" do
        expect(dispatch(receiver: two, method_name: :rassoc, args: [constant(2)]))
          .to eq(tuple(constant(:b), constant(2)))
      end

      it "returns Constant[nil] when no value matches" do
        expect(dispatch(receiver: two, method_name: :rassoc, args: [constant(99)]))
          .to eq(constant(nil))
      end
    end

    describe "has_value? / value?" do
      it "folds to true when a value is present" do
        expect(dispatch(receiver: two, method_name: :has_value?, args: [constant(1)])).to eq(constant(true))
        expect(dispatch(receiver: two, method_name: :value?, args: [constant(2)])).to eq(constant(true))
      end

      it "folds to false when no value matches" do
        expect(dispatch(receiver: two, method_name: :has_value?, args: [constant(9)])).to eq(constant(false))
      end
    end

    describe "default / default_proc" do
      it "folds to Constant[nil] for a literal shape" do
        expect(dispatch(receiver: two, method_name: :default)).to eq(constant(nil))
        expect(dispatch(receiver: two, method_name: :default_proc)).to eq(constant(nil))
      end
    end

    describe "containment comparison" do
      it "folds < (proper subset)" do
        expect(dispatch(receiver: one, method_name: :<, args: [two])).to eq(constant(true))
        expect(dispatch(receiver: two, method_name: :<, args: [two])).to eq(constant(false))
      end

      it "folds <= (subset)" do
        expect(dispatch(receiver: two, method_name: :<=, args: [two])).to eq(constant(true))
      end

      it "folds > / >= (superset)" do
        expect(dispatch(receiver: two, method_name: :>, args: [one])).to eq(constant(true))
        expect(dispatch(receiver: two, method_name: :>=, args: [two])).to eq(constant(true))
      end

      it "folds to false when a pair value differs" do
        mismatched = hash_shape(a: constant(99))
        expect(dispatch(receiver: mismatched, method_name: :<=, args: [two])).to eq(constant(false))
      end
    end
  end

  describe "non-empty-string binary operator propagation" do
    let(:non_empty_str) { Rigor::Type::Combinator.non_empty_string }
    let(:nominal_string) { Rigor::Type::Combinator.nominal_of("String") }
    let(:positive_int) { Rigor::Type::Combinator.positive_int }
    let(:non_negative_int) { Rigor::Type::Combinator.non_negative_int }

    describe "non-empty-string receiver + any-string arg → non-empty-string" do
      it "non-empty-string + Nominal[String] → non-empty-string" do
        expect(dispatch(receiver: non_empty_str, method_name: :+, args: [nominal_string])).to eq(non_empty_str)
      end

      it "non-empty-string + non-empty-string → non-empty-string" do
        expect(dispatch(receiver: non_empty_str, method_name: :+, args: [non_empty_str])).to eq(non_empty_str)
      end

      it "non-empty-string + Constant[String] → non-empty-string" do
        expect(dispatch(receiver: non_empty_str, method_name: :+, args: [constant("hi")])).to eq(non_empty_str)
      end
    end

    describe "Nominal[String] / Refined[String] receiver + non-empty-string arg → non-empty-string" do
      it "Nominal[String] + non-empty-string → non-empty-string" do
        expect(dispatch(receiver: nominal_string, method_name: :+, args: [non_empty_str])).to eq(non_empty_str)
      end

      it "lowercase-string + non-empty-string → non-empty-string" do
        lowercase = Rigor::Type::Combinator.lowercase_string
        expect(dispatch(receiver: lowercase, method_name: :+, args: [non_empty_str])).to eq(non_empty_str)
      end

      it "Nominal[String] + Nominal[String] → falls through (nil)" do
        expect(dispatch(receiver: nominal_string, method_name: :+, args: [nominal_string])).to be_nil
      end
    end

    describe "non-empty-string receiver * multiplier" do
      it "non-empty-string * Constant[0] → Constant[\"\"]" do
        expect(dispatch(receiver: non_empty_str, method_name: :*, args: [constant(0)])).to eq(constant(""))
      end

      it "non-empty-string * Constant[3] → non-empty-string" do
        expect(dispatch(receiver: non_empty_str, method_name: :*, args: [constant(3)])).to eq(non_empty_str)
      end

      it "non-empty-string * positive-int → non-empty-string" do
        expect(dispatch(receiver: non_empty_str, method_name: :*, args: [positive_int])).to eq(non_empty_str)
      end

      it "non-empty-string * non-negative-int → falls through (could be 0)" do
        expect(dispatch(receiver: non_empty_str, method_name: :*, args: [non_negative_int])).to be_nil
      end

      it "non-empty-string * Nominal[Integer] → falls through" do
        expect(dispatch(receiver: non_empty_str, method_name: :*,
                        args: [Rigor::Type::Combinator.nominal_of("Integer")])).to be_nil
      end
    end

    describe "Nominal[String] * Constant[0] → Constant[\"\"]" do
      it "any String * 0 is always empty" do
        expect(dispatch(receiver: nominal_string, method_name: :*, args: [constant(0)])).to eq(constant(""))
      end

      it "Nominal[String] * positive-int falls through (receiver may be empty)" do
        expect(dispatch(receiver: nominal_string, method_name: :*, args: [positive_int])).to be_nil
      end
    end

    describe "non-empty-string preserving unary methods" do
      %i[upcase downcase capitalize swapcase reverse].each do |sel|
        it "non-empty-string.#{sel} → non-empty-string" do
          expect(dispatch(receiver: non_empty_str, method_name: sel)).to eq(non_empty_str)
        end

        it "non-empty-string.#{sel}(arg) falls through (no-arg only)" do
          expect(dispatch(receiver: non_empty_str, method_name: sel, args: [nominal_string])).to be_nil
        end
      end

      it "non-empty-string.strip falls through (strip may empty a whitespace-only string)" do
        expect(dispatch(receiver: non_empty_str, method_name: :strip)).to be_nil
      end
    end
  end

  describe "non-zero-int / positive-int propagation through Integer operations" do
    let(:non_zero) { Rigor::Type::Combinator.non_zero_int }
    let(:positive_int) { Rigor::Type::Combinator.positive_int }
    let(:non_negative_int) { Rigor::Type::Combinator.non_negative_int }
    let(:nominal_integer) { Rigor::Type::Combinator.nominal_of("Integer") }

    describe "non-zero-int unary methods" do
      it "non-zero-int.abs → positive-int (|n| >= 1 for n != 0)" do
        expect(dispatch(receiver: non_zero, method_name: :abs)).to eq(positive_int)
      end

      it "non-zero-int.magnitude → positive-int" do
        expect(dispatch(receiver: non_zero, method_name: :magnitude)).to eq(positive_int)
      end

      it "non-zero-int.-@ → non-zero-int (negation of non-zero is non-zero)" do
        expect(dispatch(receiver: non_zero, method_name: :-@)).to eq(non_zero)
      end

      it "non-zero-int.+@ → non-zero-int (unary plus is identity)" do
        expect(dispatch(receiver: non_zero, method_name: :+@)).to eq(non_zero)
      end

      it "non-zero-int.to_i → non-zero-int (identity)" do
        expect(dispatch(receiver: non_zero, method_name: :to_i)).to eq(non_zero)
      end

      it "non-zero-int.to_int → non-zero-int (identity)" do
        expect(dispatch(receiver: non_zero, method_name: :to_int)).to eq(non_zero)
      end

      it "non-zero-int.zero? → Constant[false]" do
        expect(dispatch(receiver: non_zero, method_name: :zero?)).to eq(constant(false))
      end

      it "non-zero-int.succ falls through (pred/succ may cross zero)" do
        expect(dispatch(receiver: non_zero, method_name: :succ)).to be_nil
      end
    end

    describe "non-zero-int * non-zero-int → non-zero-int" do
      it "non-zero-int * non-zero-int stays non-zero-int" do
        expect(dispatch(receiver: non_zero, method_name: :*, args: [non_zero])).to eq(non_zero)
      end

      it "non-zero-int * positive-int → non-zero-int" do
        expect(dispatch(receiver: non_zero, method_name: :*, args: [positive_int])).to eq(non_zero)
      end

      it "non-zero-int * Constant[3] → non-zero-int" do
        expect(dispatch(receiver: non_zero, method_name: :*, args: [constant(3)])).to eq(non_zero)
      end

      it "non-zero-int * Constant[-2] → non-zero-int" do
        expect(dispatch(receiver: non_zero, method_name: :*, args: [constant(-2)])).to eq(non_zero)
      end

      it "non-zero-int * Nominal[Integer] falls through (receiver×0 could be zero)" do
        expect(dispatch(receiver: non_zero, method_name: :*, args: [nominal_integer])).to be_nil
      end

      it "non-zero-int * Constant[0] → Constant[0] (any n * 0 = 0)" do
        expect(dispatch(receiver: non_zero, method_name: :*, args: [constant(0)])).to eq(constant(0))
      end
    end

    describe "Nominal[Integer] * Constant[0] → Constant[0]" do
      it "any Integer * 0 is always 0" do
        expect(dispatch(receiver: nominal_integer, method_name: :*, args: [constant(0)])).to eq(constant(0))
      end

      it "Nominal[Integer] * positive-int falls through" do
        expect(dispatch(receiver: nominal_integer, method_name: :*, args: [positive_int])).to be_nil
      end
    end
  end

  describe "flatten (B6)" do
    def nominal(name) = Rigor::Type::Combinator.nominal_of(name)

    def array_of(*type_args)
      Rigor::Type::Combinator.nominal_of("Array", type_args: type_args)
    end

    describe "Tuple receiver" do
      it "flattens a tuple-of-tuples into a single Tuple" do
        recv = tuple(tuple(constant(1), constant(2)), tuple(constant(3), constant(4)))
        expect(dispatch(receiver: recv, method_name: :flatten))
          .to eq(tuple(constant(1), constant(2), constant(3), constant(4)))
      end

      it "flattens deep nesting fully with no depth argument" do
        recv = tuple(constant(1), tuple(constant(2), tuple(constant(3))))
        expect(dispatch(receiver: recv, method_name: :flatten))
          .to eq(tuple(constant(1), constant(2), constant(3)))
      end

      it "bounds the flatten to a Constant[Integer] depth argument" do
        recv = tuple(constant(1), tuple(constant(2), tuple(constant(3))))
        expect(dispatch(receiver: recv, method_name: :flatten, args: [constant(1)]))
          .to eq(tuple(constant(1), constant(2), tuple(constant(3))))
      end

      it "treats flatten(0) as an identity copy" do
        recv = tuple(tuple(constant(1)))
        expect(dispatch(receiver: recv, method_name: :flatten, args: [constant(0)]))
          .to eq(tuple(tuple(constant(1))))
      end

      it "passes non-Tuple elements through unchanged" do
        recv = tuple(constant(1), array_of(nominal("Integer")))
        expect(dispatch(receiver: recv, method_name: :flatten))
          .to eq(tuple(constant(1), array_of(nominal("Integer"))))
      end

      it "declines on a non-static depth argument" do
        recv = tuple(tuple(constant(1)))
        expect(dispatch(receiver: recv, method_name: :flatten, args: [nominal("Integer")])).to be_nil
      end
    end

    describe "Array[T] nominal receiver" do
      it "joins one nesting level: Array[Array[Integer]] → Array[Integer]" do
        recv = array_of(array_of(nominal("Integer")))
        expect(dispatch(receiver: recv, method_name: :flatten)).to eq(array_of(nominal("Integer")))
      end

      it "returns Array[T] unchanged for a non-nested element type" do
        recv = array_of(nominal("Integer"))
        expect(dispatch(receiver: recv, method_name: :flatten)).to eq(array_of(nominal("Integer")))
      end

      it "declines for a bare Array with no type argument" do
        recv = nominal("Array")
        expect(dispatch(receiver: recv, method_name: :flatten)).to be_nil
      end

      it "declines on a non-static depth argument" do
        recv = array_of(array_of(nominal("Integer")))
        expect(dispatch(receiver: recv, method_name: :flatten, args: [nominal("Integer")])).to be_nil
      end
    end
  end

  describe "compact (T2)" do
    def nominal(name) = Rigor::Type::Combinator.nominal_of(name)

    def array_of(*type_args)
      Rigor::Type::Combinator.nominal_of("Array", type_args: type_args)
    end

    it "strips the nil constituent: Array[Node?] → Array[Node]" do
      nilable = Rigor::Type::Combinator.union(nominal("Node"), nominal("NilClass"))
      recv = array_of(nilable)
      expect(dispatch(receiver: recv, method_name: :compact)).to eq(array_of(nominal("Node")))
    end

    it "strips a Constant[nil] constituent" do
      nilable = Rigor::Type::Combinator.union(constant(1), constant(nil))
      recv = array_of(nilable)
      expect(dispatch(receiver: recv, method_name: :compact)).to eq(array_of(constant(1)))
    end

    it "declines (returns nil) for an Array[T] with no nil constituent" do
      recv = array_of(nominal("Integer"))
      expect(dispatch(receiver: recv, method_name: :compact)).to be_nil
    end

    it "declines for a bare Array with no type argument" do
      expect(dispatch(receiver: nominal("Array"), method_name: :compact)).to be_nil
    end

    it "declines when an argument is supplied" do
      recv = array_of(Rigor::Type::Combinator.union(nominal("Node"), nominal("NilClass")))
      expect(dispatch(receiver: recv, method_name: :compact, args: [constant(1)])).to be_nil
    end
  end

  describe "ADR-76 WD2 / ADR-78 WD3 — pure self-returners preserve the HashShape carrier" do
    let(:t) { tuple(constant(1), constant(2), constant(3)) }
    let(:h) { hash_shape(reason: constant("boom")) }

    %i[freeze dup clone itself].each do |m|
      it "returns the HashShape unchanged for `hash.#{m}`" do
        expect(dispatch(receiver: h, method_name: m)).to eq(h)
      end

      # Tuple preservation is deliberately deferred (it re-surfaces
      # reflexive always-truthy over-folds; see the HASH_SHAPE_HANDLERS
      # note + ADR-78 carry-over), so the Tuple path still falls through.
      it "still falls through (nil) for `tuple.#{m}` — Tuple preservation deferred" do
        expect(dispatch(receiver: t, method_name: m)).to be_nil
      end
    end

    it "folds element access through a frozen HashShape (the MESSAGES[reason] gap)" do
      frozen = dispatch(receiver: h, method_name: :freeze)
      expect(dispatch(receiver: frozen, method_name: :[], args: [constant(:reason)])).to eq(constant("boom"))
    end
  end
end
