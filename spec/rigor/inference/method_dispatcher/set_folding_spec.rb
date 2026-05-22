# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::SetFolding do
  def set_singleton = Rigor::Type::Combinator.singleton_of("Set")
  def c(value)      = Rigor::Type::Combinator.constant_of(value)

  def tuple(*elements)
    Rigor::Type::Tuple.new(elements)
  end

  def fold(method_name, *arg_types)
    described_class.try_dispatch(
      receiver: set_singleton,
      method_name: method_name,
      args: arg_types
    )
  end

  # ── Set[] — variadic bracket constructor ──────────────────────────────

  describe "Set[]" do
    it "folds an empty bracket call to Constant[Set.new]" do
      result = fold(:[])
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value).to eq(Set.new)
    end

    it "folds Set[:a, :b, :c] to a frozen Constant[Set]" do
      result = fold(:[], c(:a), c(:b), c(:c))
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value).to eq(Set[:a, :b, :c])
    end

    it "de-duplicates elements (Set semantics)" do
      result = fold(:[], c(1), c(1), c(2))
      expect(result.value).to eq(Set[1, 2])
    end

    it "carries mixed-type constants" do
      result = fold(:[], c("hello"), c(42), c(:sym))
      expect(result.value).to eq(Set["hello", 42, :sym])
    end

    it "declines when any argument is non-Constant" do
      expect(fold(:[], c(:a), Rigor::Type::Combinator.nominal_of("Symbol"))).to be_nil
    end
  end

  # ── Set.new — zero-arg and tuple forms ──────────────────────────────

  describe "Set.new" do
    it "folds a zero-argument Set.new to Constant[Set.new]" do
      result = fold(:new)
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value).to eq(Set.new)
    end

    it "folds Set.new(tuple_of_constants) to the correct Constant[Set]" do
      arg = tuple(c(1), c(2), c(3))
      result = fold(:new, arg)
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value).to eq(Set.new([1, 2, 3]))
    end

    it "folds an empty Tuple argument to an empty Set" do
      result = fold(:new, tuple)
      expect(result).to be_a(Rigor::Type::Constant)
      expect(result.value).to eq(Set.new)
    end

    it "declines when the tuple contains a non-Constant element" do
      non_const = Rigor::Type::Combinator.nominal_of("Integer")
      arg = tuple(c(1), non_const)
      expect(fold(:new, arg)).to be_nil
    end

    it "declines when the single argument is not a Tuple" do
      expect(fold(:new, Rigor::Type::Combinator.nominal_of("Array"))).to be_nil
    end

    it "declines when more than one argument is given" do
      expect(fold(:new, tuple(c(1)), c(:extra))).to be_nil
    end
  end

  # ── Receiver / method guarding ────────────────────────────────────────

  describe "dispatch guards" do
    it "declines for a non-Singleton receiver" do
      result = described_class.try_dispatch(
        receiver: c("Set"),
        method_name: :[],
        args: []
      )
      expect(result).to be_nil
    end

    it "declines for a wrong singleton class" do
      result = described_class.try_dispatch(
        receiver: Rigor::Type::Combinator.singleton_of("Array"),
        method_name: :[],
        args: [c(:a)]
      )
      expect(result).to be_nil
    end

    it "declines for an unsupported method" do
      expect(fold(:nope, c(:a))).to be_nil
    end
  end
end
