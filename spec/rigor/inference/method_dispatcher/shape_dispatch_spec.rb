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
    described_class.try_dispatch(receiver: receiver, method_name: method_name, args: args)
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
      expect(dispatch(receiver: t, method_name: :map)).to be_nil
      expect(dispatch(receiver: t, method_name: :reverse)).to be_nil
    end

    it "ignores arity mismatches by returning nil" do
      # `tuple.first(2)` is the Slice-4 RBS overload; we let RbsDispatch
      # handle it through the projection so the precise tier doesn't
      # accidentally claim ownership.
      expect(dispatch(receiver: t, method_name: :first, args: [constant(2)])).to be_nil
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

    it "falls through for methods outside the catalogue" do
      expect(dispatch(receiver: shape, method_name: :keys)).to be_nil
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
end
