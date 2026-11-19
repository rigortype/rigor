# frozen_string_literal: true

require "spec_helper"

# The static-refinement tier asked directly, on plain data. The table's own entries are
# `spec/rigor/builtins/static_return_refinements_spec.rb`'s; these examples pin how the tier picks the owner the
# receiver honours and how it answers a union.
RSpec.describe Rigor::Inference::MethodDispatcher::StaticRefinement do
  let(:environment) { Rigor::Environment.default }
  let(:string) { Rigor::Type::Combinator.nominal_of("String") }
  let(:strings) { Rigor::Type::Combinator.nominal_of("Array", type_args: [string]) }
  let(:from_zero) { Rigor::Type::Combinator.constant_of(0..) }

  def dispatch(receiver, method_name, args = [])
    described_class.try_dispatch(
      cc(receiver: receiver, method_name: method_name, args: args, environment: environment)
    )
  end

  def union(*members) = Rigor::Type::Combinator.union(*members)

  describe "a Kernel-owned entry" do
    it "answers for an instance of any class, and for the Kernel module object" do
      expect(dispatch(Rigor::Type::Combinator.nominal_of("Foo"), :__dir__).describe).to eq("non-empty-string?")
      expect(dispatch(Rigor::Type::Combinator.singleton_of("Kernel"), :__dir__).describe).to eq("non-empty-string?")
    end

    it "declines BasicObject, which does not include Kernel" do
      expect(dispatch(Rigor::Type::Combinator.nominal_of("BasicObject"), :__dir__)).to be_nil
    end

    it "declines a receiver that names no class" do
      expect(dispatch(Rigor::Type::Combinator.constant_of(1), :__dir__)).to be_nil
    end
  end

  describe "an entry owned by one class" do
    it "answers for that class, with the declared nil removed" do
      expect(dispatch(strings, :[], [from_zero])).to eq(strings)
      expect(dispatch(string, :[], [from_zero])).to eq(string)
    end

    it "reads a Tuple receiver as Array" do
      expect(dispatch(Rigor::Type::Combinator.tuple_of, :[], [from_zero]).describe).to eq("Array[Dynamic[top]]")
    end
  end

  describe "a union receiver" do
    it "answers member by member when every member is refined" do
      expect(dispatch(union(strings, string), :[], [from_zero])).to eq(union(strings, string))
    end

    it "declines when the table declines a member the tier found an owner for" do
      raw_array = Rigor::Type::Combinator.nominal_of("Array")

      expect(dispatch(union(raw_array, string), :[], [from_zero])).to be_nil
    end

    it "offers a Tuple member to ShapeDispatch before taking the table's projection" do
      one = Rigor::Type::Combinator.tuple_of(Rigor::Type::Combinator.constant_of(1))

      expect(dispatch(union(strings, one), :slice, [from_zero])).to eq(union(strings, one))
    end
  end
end
