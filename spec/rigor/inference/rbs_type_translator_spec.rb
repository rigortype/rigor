# frozen_string_literal: true

require "spec_helper"
require "rbs"

RSpec.describe Rigor::Inference::RbsTypeTranslator do
  def parse_rbs(source, variables: [])
    RBS::Parser.parse_type(source, variables: variables)
  end

  describe ".translate" do
    it "maps base types to their lattice counterparts" do
      expect(described_class.translate(parse_rbs("top"))).to equal(Rigor::Type::Combinator.top)
      expect(described_class.translate(parse_rbs("bot"))).to equal(Rigor::Type::Combinator.bot)
      expect(described_class.translate(parse_rbs("untyped"))).to equal(Rigor::Type::Combinator.untyped)
      expect(described_class.translate(parse_rbs("nil")).value).to be_nil
      expect(described_class.translate(parse_rbs("void"))).to equal(Rigor::Type::Combinator.untyped)
    end

    it "translates a class instance to a Nominal" do
      type = described_class.translate(parse_rbs("::Integer"))
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Integer")
    end

    it "carries type arguments through generic class instances (Slice 4 phase 2d)" do
      type = described_class.translate(parse_rbs("::Array[::Integer]"))
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Array")
      expect(type.type_args).to eq([Rigor::Type::Combinator.nominal_of(Integer)])
      expect(type.describe).to eq("Array[Integer]")
    end

    it "translates Hash[K, V] preserving both type_args" do
      type = described_class.translate(parse_rbs("::Hash[::Symbol, ::Integer]"))
      expect(type.type_args).to eq(
        [
          Rigor::Type::Combinator.nominal_of(Symbol),
          Rigor::Type::Combinator.nominal_of(Integer)
        ]
      )
    end

    it "substitutes RBS type variables via the type_vars: map (Slice 4 phase 2d)" do
      var = parse_rbs("Elem", variables: [:Elem])
      type = described_class.translate(
        var,
        type_vars: { Elem: Rigor::Type::Combinator.nominal_of(Integer) }
      )
      expect(type).to eq(Rigor::Type::Combinator.nominal_of(Integer))
    end

    it "degrades unbound RBS type variables to Dynamic[Top]" do
      var = parse_rbs("Elem", variables: [:Elem])
      type = described_class.translate(var, type_vars: {})
      expect(type).to equal(Rigor::Type::Combinator.untyped)
    end

    it "substitutes variables nested inside a generic instantiation" do
      type = described_class.translate(
        parse_rbs("::Array[Elem]", variables: [:Elem]),
        type_vars: { Elem: Rigor::Type::Combinator.nominal_of(String) }
      )
      expect(type).to eq(
        Rigor::Type::Combinator.nominal_of(
          Array,
          type_args: [Rigor::Type::Combinator.nominal_of(String)]
        )
      )
    end

    it "translates Optional[T] into Union[T, Constant[nil]]" do
      type = described_class.translate(parse_rbs("::Integer?"))
      expect(type).to be_a(Rigor::Type::Union)
      members = type.members
      expect(members).to include(Rigor::Type::Combinator.constant_of(nil))
      expect(members.find { |m| m.is_a?(Rigor::Type::Nominal) }.class_name).to eq("Integer")
    end

    it "translates Union into a normalized union" do
      type = described_class.translate(parse_rbs("::Integer | ::String"))
      expect(type).to be_a(Rigor::Type::Union)
      class_names = type.members.map(&:class_name)
      expect(class_names).to contain_exactly("Integer", "String")
    end

    it "translates RBS literals into Constant" do
      type = described_class.translate(parse_rbs("42"))
      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(42)
    end

    it "translates `bool` into Union[Constant[true], Constant[false]]" do
      type = described_class.translate(parse_rbs("bool"))
      expect(type).to be_a(Rigor::Type::Union)
      values = type.members.map(&:value)
      expect(values).to contain_exactly(true, false)
    end

    it "uses self_type for `self` references when supplied" do
      self_type = Rigor::Type::Combinator.nominal_of("Foo")
      type = described_class.translate(parse_rbs("self"), self_type: self_type)
      expect(type).to equal(self_type)
    end

    it "degrades `self` to Dynamic[Top] without self_type" do
      type = described_class.translate(parse_rbs("self"))
      expect(type).to equal(Rigor::Type::Combinator.untyped)
    end

    it "propagates self_type through Optional and Union" do
      self_type = Rigor::Type::Combinator.nominal_of("Foo")
      type = described_class.translate(parse_rbs("self?"), self_type: self_type)
      expect(type).to be_a(Rigor::Type::Union)
      expect(type.members).to include(self_type)
      expect(type.members).to include(Rigor::Type::Combinator.constant_of(nil))
    end

    it "translates tuples to Rigor::Type::Tuple (Slice 5 phase 1)" do
      tuple = described_class.translate(parse_rbs("[::Integer, ::String]"))
      expect(tuple).to be_a(Rigor::Type::Tuple)
      expect(tuple.elements.size).to eq(2)
      expect(tuple.elements[0]).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
      expect(tuple.elements[1]).to eq(Rigor::Type::Combinator.nominal_of("String"))
    end

    it "translates records to Rigor::Type::HashShape (Slice 5 phase 1)" do
      record = described_class.translate(parse_rbs("{ a: ::Integer, b: ::String }"))
      expect(record).to be_a(Rigor::Type::HashShape)
      expect(record.pairs.keys).to eq(%i[a b])
      expect(record.pairs[:a]).to eq(Rigor::Type::Combinator.nominal_of("Integer"))
      expect(record.pairs[:b]).to eq(Rigor::Type::Combinator.nominal_of("String"))
    end

    it "degrades type variables to Dynamic[Top]" do
      var = RBS::Types::Variable.new(name: :T, location: nil)
      expect(described_class.translate(var)).to equal(Rigor::Type::Combinator.untyped)
    end

    describe "instance_type and singleton(...) (Slice 4 phase 2b)" do
      it "uses instance_type for `instance` references when supplied" do
        instance_type = Rigor::Type::Combinator.nominal_of("Foo")
        type = described_class.translate(parse_rbs("instance"), instance_type: instance_type)
        expect(type).to equal(instance_type)
      end

      it "degrades `instance` to Dynamic[Top] without instance_type" do
        type = described_class.translate(parse_rbs("instance"))
        expect(type).to equal(Rigor::Type::Combinator.untyped)
      end

      it "treats `self` and `instance` as separable substitutions" do
        self_type = Rigor::Type::Combinator.singleton_of("Foo")
        instance_type = Rigor::Type::Combinator.nominal_of("Foo")
        u = described_class.translate(
          parse_rbs("self | instance"),
          self_type: self_type,
          instance_type: instance_type
        )
        expect(u).to be_a(Rigor::Type::Union)
        expect(u.members).to include(self_type)
        expect(u.members).to include(instance_type)
      end

      it "translates singleton(::Integer) to Singleton[Integer]" do
        type = described_class.translate(parse_rbs("singleton(::Integer)"))
        expect(type).to be_a(Rigor::Type::Singleton)
        expect(type.class_name).to eq("Integer")
      end
    end
  end
end
