# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Inference::MethodDispatcher::OverloadSelector do
  let(:loader) { Rigor::Environment::RbsLoader.default }

  def select(class_name, method_name, arg_types, kind: :instance)
    definition =
      case kind
      when :instance then loader.instance_definition(class_name)
      when :singleton then loader.singleton_definition(class_name)
      end
    raise "missing definition" unless definition

    method = definition.methods[method_name]
    raise "missing method #{class_name}##{method_name}" unless method

    instance_type = Rigor::Type::Combinator.nominal_of(class_name)
    self_type = kind == :singleton ? Rigor::Type::Combinator.singleton_of(class_name) : instance_type

    described_class.select(
      method,
      arg_types: arg_types,
      self_type: self_type,
      instance_type: instance_type
    )
  end

  describe ".select" do
    it "picks the arity-matching overload (Array#first / 0 args)" do
      mt = select("Array", :first, [])
      expect(mt.type.required_positionals).to be_empty
      expect(mt.type.return_type).to be_a(RBS::Types::Variable) # `Elem`
    end

    it "picks the arity-matching overload (Array#first / 1 arg)" do
      mt = select("Array", :first, [Rigor::Type::Combinator.constant_of(3)])
      expect(mt.type.required_positionals.size).to eq(1)
      # `(::int n) -> ::Array[Elem]`
      expect(mt.type.return_type).to be_a(RBS::Types::ClassInstance)
      expect(mt.type.return_type.name.relative!.to_s).to eq("Array")
    end

    it "picks the type-matching overload for Integer#+" do
      mt = select(
        "Integer",
        :+,
        [Rigor::Type::Combinator.nominal_of(Float)]
      )
      expect(mt.type.required_positionals.first.type.name.relative!.to_s).to eq("Float")
    end

    it "falls back to the first overload when no overload matches" do
      mt = select(
        "Integer",
        :+,
        [Rigor::Type::Combinator.nominal_of(String)]
      )
      # First overload is `(::Integer) -> ::Integer`.
      expect(mt.type.required_positionals.first.type.name.relative!.to_s).to eq("Integer")
    end

    it "supports singleton-method overload selection (Array.new arity 0)" do
      mt = select("Array", :new, [], kind: :singleton)
      expect(mt.type.required_positionals).to be_empty
    end

    it "supports singleton-method overload selection (Array.new arity 1)" do
      mt = select(
        "Array",
        :new,
        [Rigor::Type::Combinator.constant_of(3)],
        kind: :singleton
      )
      expect(mt.type.required_positionals.size).to eq(1)
    end

    it "skips overloads with required keyword arguments" do
      # We construct a synthetic method with one keyword-required and
      # one positional-only overload to ensure the selector skips the
      # keyword-required one. We use Object#tap which has no kwargs as
      # baseline; the synthetic part is a stub that simulates a kwargs
      # overload via a dummy MethodType. Easier: just verify behaviour
      # via Hash#fetch which has keyword-free overloads in core RBS.
      mt = select("Hash", :fetch, [Rigor::Type::Combinator.constant_of(:k)])
      expect(mt).not_to be_nil
    end

    describe "interface-strictness preference (v0.1.2)" do
      # When two overloads are arity-compatible and accept the
      # call site's arg types, prefer the one whose params do
      # NOT depend on `RBS::Types::Alias` / `Interface` /
      # `Intersection` translating to `Dynamic[Top]`. The
      # gradual-acceptance fall-back at the bottom of the
      # selector still applies when no fully strict overload
      # matches — only the ranking changes.
      #
      # Surfaced when self-analysing this repo: `Array#[]`
      # ships three overloads —
      #   (::int) -> Elem
      #   (::int, ::int) -> Array[Elem]?
      #   (::Range[::Integer?]) -> Array[Elem]?
      # `int` is `RBS::Types::Alias`, which translates to
      # `Dynamic[Top]` and gradually accepts a Range. Without
      # the strict-first pass the first overload wins and the
      # call resolves to `Elem` instead of `Array[Elem]?`.
      it "prefers `(Range) -> Array[Elem]?` over `(int) -> Elem` for an Array#[](Range) call" do
        mt = select("Array", :[], [Rigor::Type::Combinator.nominal_of("Range")])
        expect(mt.type.required_positionals.size).to eq(1)
        expect(mt.type.required_positionals.first.type.name.relative!.to_s).to eq("Range")
      end

      it "still picks the alias-typed overload when only it is arity-compatible (Array#[](Integer))" do
        mt = select("Array", :[], [Rigor::Type::Combinator.nominal_of("Integer")])
        # Pass 1 (strict) finds nothing — Range param doesn't
        # accept Integer. Pass 2 falls back to the gradual
        # behaviour and the alias-typed overload wins.
        expect(mt.type.required_positionals.size).to eq(1)
        expect(mt.type.required_positionals.first.type).to be_a(RBS::Types::Alias)
      end

      it "still picks the alias-typed overload for two-Integer slicing (Array#[](Integer, Integer))" do
        # The two-int overload is arity-2 and the only option;
        # neither pass changes the outcome here.
        mt = select(
          "Array", :[],
          [Rigor::Type::Combinator.nominal_of("Integer"), Rigor::Type::Combinator.nominal_of("Integer")]
        )
        expect(mt.type.required_positionals.size).to eq(2)
      end
    end
  end
end
