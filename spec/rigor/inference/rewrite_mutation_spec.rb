# frozen_string_literal: true

require "spec_helper"

require "rigor/inference/mutation_widening"
require "rigor/type"

# Unit coverage for {Rigor::Inference::RewriteMutation} as {Rigor::Inference::MutationWidening.widen_for_mutator}
# reaches it. The end-to-end pairs live in `unknown_store_mutator_widening_spec.rb`.
RSpec.describe Rigor::Inference::RewriteMutation do
  def constant(value) = Rigor::Type::Combinator.constant_of(value)
  def nominal(name, *args) = Rigor::Type::Combinator.nominal_of(name, type_args: args)
  def untyped = Rigor::Type::Combinator.untyped
  def union(*types) = Rigor::Type::Combinator.union(*types)
  def widen(type, name, **) = Rigor::Inference::MutationWidening.widen_for_mutator(type, name, **)

  describe ".arm" do
    it "joins the gradual arm into the positions the mutator rewrites and nowhere else" do
      hash = nominal("Hash", nominal("Symbol"), nominal("Integer"))
      expect(described_class.arm(hash, :transform_values!))
        .to eq(nominal("Hash", nominal("Symbol"), union(nominal("Integer"), untyped)))
      expect(described_class.arm(hash, :transform_keys!))
        .to eq(nominal("Hash", union(nominal("Symbol"), untyped), nominal("Integer")))
      expect(described_class.arm(hash, :merge!))
        .to eq(nominal("Hash", union(nominal("Symbol"), untyped), union(nominal("Integer"), untyped)))
    end

    it "leaves a name it does not list, and a name listed for the other class, untouched" do
      array = nominal("Array", nominal("Integer"))
      expect(described_class.arm(array, :sort!)).to equal(array)
      expect(described_class.arm(array, :transform_values!)).to equal(array)
      expect(described_class.arm(nominal("Hash", nominal("Symbol"), nominal("Integer")), :map!))
        .to eq(nominal("Hash", nominal("Symbol"), nominal("Integer")))
    end
  end

  describe "through the straight-line widening" do
    it "keeps a literal's pinning beside the arm, where a slot-rewriting store erases it" do
      tuple = Rigor::Type::Combinator.tuple_of(constant(:multi))
      expect(widen(tuple, :map!)).to eq(nominal("Array", union(constant(:multi), untyped)))
      expect(widen(tuple, :[]=).type_args.first.describe).not_to include(":multi")
    end

    it "gives an empty-witness refinement the arm and keeps its witness under `map!`" do
      non_empty = Rigor::Type::Combinator.non_empty_array(nominal("String"))
      widened = widen(non_empty, :map!)
      expect(widened).to be_a(Rigor::Type::Difference)
      expect(widened.removes_empty_witness?).to be(true)
      expect(widened.base).to eq(nominal("Array", union(nominal("String"), untyped)))
    end

    it "retracts the witness under `flatten!`, which can empty the receiver, and still arms the base" do
      non_empty = Rigor::Type::Combinator.non_empty_array(nominal("String"))
      expect(widen(non_empty, :flatten!)).to eq(nominal("Array", union(nominal("String"), untyped)))
    end

    it "arms a re-opened carrier's proven side, which an adder's re-join keeps precise" do
      counter = nominal("Hash", untyped, nominal("Integer"))
      expect(widen(counter, :transform_values!)).to eq(nominal("Hash", untyped, union(nominal("Integer"), untyped)))
      expect(widen(counter, :[]=, arg_types: [constant(:x), constant(1)]).type_args.last).to eq(nominal("Integer"))
    end

    # The #561 boundary: a precise nominal is a declaration's claim, and RBS's own `map!` keeps `Elem`.
    it "declines a precise nominal" do
      expect(widen(nominal("Array", nominal("String")), :map!)).to be_nil
      expect(widen(nominal("Hash", nominal("Symbol"), nominal("Integer")), :transform_values!)).to be_nil
    end

    it "declines a carrier whose rewritten position already carries the arm" do
      expect(widen(nominal("Array", union(constant(1), untyped)), :map!)).to be_nil
    end
  end
end
