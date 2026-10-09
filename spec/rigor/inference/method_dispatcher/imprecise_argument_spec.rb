# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::ImpreciseArgument do
  let(:untyped) { Rigor::Type::Combinator.untyped }
  let(:integer) { Rigor::Type::Combinator.nominal_of("Integer") }
  let(:string) { Rigor::Type::Combinator.nominal_of("String") }

  def union(*types) = Rigor::Type::Combinator.union(*types)
  def dynamic(type) = Rigor::Type::Combinator.dynamic(type)

  describe ".imprecise?" do
    it "holds for the bare carrier and a union with an untyped member" do
      expect(described_class.imprecise?(untyped)).to be(true)
      expect(described_class.imprecise?(union(integer, untyped))).to be(true)
    end

    it "holds for a Dynamic whose facet holds the carrier, at any depth (#1675)" do
      expect(described_class.imprecise?(dynamic(union(integer, untyped)))).to be(true)
      expect(described_class.imprecise?(union(string, dynamic(union(integer, untyped))))).to be(true)
    end

    it "does not hold for a Dynamic with a concrete facet or a precise type" do
      expect(described_class.imprecise?(dynamic(union(integer, string)))).to be(false)
      expect(described_class.imprecise?(union(integer, string))).to be(false)
      expect(described_class.imprecise?(integer)).to be(false)
    end
  end

  describe ".untyped_stand_ins" do
    it "is nil when no argument mixes the carrier with something precise" do
      expect(described_class.untyped_stand_ins([untyped, integer])).to be_nil
      expect(described_class.untyped_stand_ins([integer])).to be_nil
    end

    it "replaces each imprecise argument with the bare carrier and keeps the precise ones" do
      stand_ins = described_class.untyped_stand_ins([union(integer, untyped), string, dynamic(union(string, untyped))])
      expect(stand_ins).to eq([untyped, string, untyped])
    end
  end

  describe "end to end" do
    def type_of_last_call(source, name)
      env = Rigor::Environment.for_project(libraries: [], signature_paths: [])
      root = Prism.parse(source).value
      index = Rigor::Inference::ScopeIndexer.index(root, default_scope: Rigor::Scope.empty(environment: env))
      call = nil
      Rigor::Source::NodeWalker.each(root) { |n| call = n if n.is_a?(Prism::CallNode) && n.name == name }
      index[call].type_of(call)
    end

    it "no longer pins `Array#*(string) -> String` for a `Dynamic[Integer | untyped]` count" do
      source = "def f(arg, i)\n  n = arg ? [0].concat(arg)[i] : 1\n  [true] * n\nend\n"
      type = type_of_last_call(source, :*)
      expect(type).to be_a(Rigor::Type::Dynamic)
      expect(type.describe(:short)).to include("Array")
    end

    it "does not type `0 + (1 | untyped)` as a bare Integer" do
      type = type_of_last_call("def f(u, c)\n  w = c ? u : 1\n  0 + w\nend\n", :+)
      expect(type).to be_a(Rigor::Type::Dynamic)
      expect(type).not_to eq(Rigor::Type::Combinator.nominal_of("Integer"))
    end
  end
end
