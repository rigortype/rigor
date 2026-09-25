# frozen_string_literal: true

require "spec_helper"

# Issue #1350 — which `Dynamic` facets overload selection reads member by member. Only a sealed member, whose runtime
# value is of exactly its class, is read; any other facet keeps the wrapper and master's reading.
RSpec.describe Rigor::Inference::MethodDispatcher::FacetDistribution do
  def nominal(name, *type_args) = Rigor::Type::Combinator.nominal_of(name, type_args: type_args)
  def constant(value) = Rigor::Type::Combinator.constant_of(value)
  def dynamic_of(*members) = Rigor::Type::Combinator.dynamic(Rigor::Type::Combinator.union(*members))

  describe ".facet_members" do
    %w[Integer Float Rational Complex Symbol].each do |name|
      it "reads a #{name} member, leaving the facet's nil out" do
        expect(described_class.facet_members(dynamic_of(nominal(name), constant(nil)))).to eq([nominal(name)])
      end
    end

    it "reads literal members" do
      expect(described_class.facet_members(dynamic_of(constant(:a), constant(:b))))
        .to contain_exactly(constant(:a), constant(:b))
      expect(described_class.facet_members(dynamic_of(constant("s"), constant(nil)))).to eq([constant("s")])
      expect(described_class.facet_members(dynamic_of(constant(true), constant(false))))
        .to contain_exactly(constant(true), constant(false))
    end

    it "keeps the wrapper for a member whose runtime value may be of a subclass" do
      [nominal("String"), nominal("Numeric"), nominal("Object"), nominal("Array"), nominal("Array", nominal("Integer")),
       nominal("TrueClass"), nominal("FalseClass")].each do |member|
        expect(described_class.facet_members(dynamic_of(member, constant(nil)))).to be_nil, member.describe
        expect(described_class.facet_members(dynamic_of(member, nominal("Integer")))).to be_nil, member.describe
      end
    end
  end
end
