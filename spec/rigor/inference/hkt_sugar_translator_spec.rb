# frozen_string_literal: true

require "spec_helper"
require "rbs"
require "rigor/inference/hkt_sugar_translator"

RSpec.describe Rigor::Inference::HktSugarTranslator do
  subject(:translator) { described_class.new(uri: :"Concerto::box", params_set: Set[:T]) }

  def rbs_type(source)
    RBS::Parser.parse_type(source, variables: %i[T U])
  end

  describe "#translate" do
    it "maps a bound type parameter to a Param node" do
      expect(translator.translate(rbs_type("T"))).to eq(Rigor::Inference::HktBody::Param.new(name: :T))
    end

    it "maps a recursive reference to the alias under translation to an AppRef" do
      node = translator.translate(rbs_type("Concerto::box[T]"))
      expect(node).to be_a(Rigor::Inference::HktBody::AppRef)
      expect(translator.recursive).to be(true)
    end

    # A bare `Concerto::box` (no `[...]`) is malformed for a parameterized alias. Building
    # `AppRef.new(args: [])` from it raises inside `HktBody` (issue #776's second crash path); the
    # translator declines it to a leaf and stays non-recursive instead.
    it "declines a self-reference with no type arguments to a leaf" do
      node = translator.translate(rbs_type("Concerto::box"))
      expect(node).to be_a(Rigor::Inference::HktBody::TypeLeaf)
      expect(translator.recursive).to be(false)
    end

    # Regression: issue #776. Every arm below reaches #fallback_to_type_leaf, which used to pass a
    # `name_scope:` keyword RbsTypeTranslator.translate does not declare. Any alias reaching one of
    # these arms during the shared hkt_registry build raised `ArgumentError: unknown keyword:
    # :name_scope`, and `rigor check` surfaced it as one bogus "internal analyzer error" per file.
    describe "subterms with no HKT body node degrade to a concrete type leaf" do
      it "folds a tuple to a Tuple leaf, keeping the concrete member" do
        node = translator.translate(rbs_type("[T, ::Integer]"))
        expect(node).to be_a(Rigor::Inference::HktBody::TypeLeaf)
        expect(node.type).to be_a(Rigor::Type::Tuple)
        # `T` erases (type_vars: {} in the fallback — known gap, pre-#776), `::Integer` survives.
        expect(node.type.describe).to eq("[Dynamic[top], Integer]")
      end

      it "folds a record to a HashShape leaf, keeping the concrete value" do
        node = translator.translate(rbs_type("{ id: ::Integer }"))
        expect(node).to be_a(Rigor::Inference::HktBody::TypeLeaf)
        expect(node.type).to be_a(Rigor::Type::HashShape)
        expect(node.type.describe).to eq("{ id: Integer }")
      end

      it "degrades an interface to a dynamic leaf" do
        node = translator.translate(rbs_type("::_ToS"))
        expect(node).to be_a(Rigor::Inference::HktBody::TypeLeaf)
        expect(node.type).to be_a(Rigor::Type::Dynamic)
      end

      it "degrades an unbound type variable to a dynamic leaf" do
        node = translator.translate(rbs_type("U"))
        expect(node).to be_a(Rigor::Inference::HktBody::TypeLeaf)
        expect(node.type).to be_a(Rigor::Type::Dynamic)
      end

      it "degrades a non-recursive generic alias to a dynamic leaf" do
        node = translator.translate(rbs_type("::Other::thing[T]"))
        expect(node).to be_a(Rigor::Inference::HktBody::TypeLeaf)
        expect(node.type).to be_a(Rigor::Type::Dynamic)
        expect(translator.recursive).to be(false)
      end

      it "carries a fallback arm through a union without raising" do
        node = translator.translate(rbs_type("T | [T, T] | Concerto::box[T]"))
        expect(node).to be_a(Rigor::Inference::HktBody::Union)
        expect(node.arms[1]).to be_a(Rigor::Inference::HktBody::TypeLeaf)
        expect(node.arms[1].type).to be_a(Rigor::Type::Tuple)
        expect(translator.recursive).to be(true)
      end
    end
  end
end
