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

    it "falls through for non-static keys" do
      dyn = Rigor::Type::Combinator.untyped
      expect(dispatch(receiver: shape, method_name: :[], args: [dyn])).to be_nil
    end

    it "falls through for non-Symbol/String keys" do
      expect(dispatch(receiver: shape, method_name: :[], args: [constant(1)])).to be_nil
    end

    it "falls through for multi-arg dig" do
      expect(dispatch(receiver: shape, method_name: :dig, args: [constant(:a), constant(:b)])).to be_nil
    end

    it "falls through for methods outside the catalogue" do
      expect(dispatch(receiver: shape, method_name: :keys)).to be_nil
    end
  end

  describe "non-shape receivers" do
    it "returns nil for any non-Tuple/HashShape receiver" do
      expect(dispatch(receiver: constant(1), method_name: :first)).to be_nil
      nominal = Rigor::Type::Combinator.nominal_of(Array)
      expect(dispatch(receiver: nominal, method_name: :first)).to be_nil
    end
  end
end
