# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::SetFolding do
  def set_singleton = Rigor::Type::Combinator.singleton_of("Set")
  def c(value)      = Rigor::Type::Combinator.constant_of(value)

  def tuple(*elements)
    Rigor::Type::Tuple.new(elements)
  end

  # The element joins a `Dynamic[top]` floor (see `SetFolding.typed_set`).
  def typed_set_of(element)
    Rigor::Type::Combinator.nominal_of(
      "Set", type_args: [Rigor::Type::Combinator.union(element, Rigor::Type::Combinator.untyped)]
    )
  end

  def fold(method_name, *arg_types)
    described_class.try_dispatch(cc(
                                   receiver: set_singleton,
                                   method_name: method_name,
                                   args: arg_types
                                 ))
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

    it "types a non-Constant argument by element rather than folding (#2278)" do
      result = fold(:[], c(:a), Rigor::Type::Combinator.nominal_of("Symbol"))
      expect(result).to eq(typed_set_of(Rigor::Type::Combinator.nominal_of("Symbol")))
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

    it "types a tuple with a non-Constant element by element rather than folding (#2278)" do
      non_const = Rigor::Type::Combinator.nominal_of("Integer")
      arg = tuple(c(1), non_const)
      expect(fold(:new, arg)).to eq(typed_set_of(non_const))
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
      result = described_class.try_dispatch(cc(
                                              receiver: c("Set"),
                                              method_name: :[],
                                              args: []
                                            ))
      expect(result).to be_nil
    end

    it "declines for a wrong singleton class" do
      result = described_class.try_dispatch(cc(
                                              receiver: Rigor::Type::Combinator.singleton_of("Array"),
                                              method_name: :[],
                                              args: [c(:a)]
                                            ))
      expect(result).to be_nil
    end

    it "declines for an unsupported method" do
      expect(fold(:nope, c(:a))).to be_nil
    end
  end

  # The block decline has two independent sources, each pinned apart: the dispatcher's block type (a caller with no
  # call node) and the call node's own block (a caller with no block type). A block maps the elements, so the
  # argument's are not the set's.
  describe "Set.new with a block (#2278)" do
    let(:constants) { tuple(c(1), c(2)) }

    it "declines on the block type alone" do
      result = described_class.try_dispatch(cc(receiver: set_singleton, method_name: :new, args: [constants],
                                               block_type: Rigor::Type::Combinator.nominal_of("String")))
      expect(result).to be_nil
    end

    it "declines on the call node's block alone" do
      node = Prism.parse("Set.new([1, 2]) { |v| v.to_s }").value.statements.body.first
      result = described_class.try_dispatch(cc(receiver: set_singleton, method_name: :new, args: [constants],
                                               call_node: node))
      expect(result).to be_nil
    end

    it "still folds without a block" do
      expect(fold(:new, constants)).to be_a(Rigor::Type::Constant)
    end
  end
end
