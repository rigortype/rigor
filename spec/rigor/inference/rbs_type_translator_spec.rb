# frozen_string_literal: true

require "spec_helper"
require "rbs"

RSpec.describe Rigor::Inference::RbsTypeTranslator do
  def parse_rbs(source)
    RBS::Parser.parse_type(source)
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

    it "drops type arguments from generic class instances (Slice 4 phase 1)" do
      type = described_class.translate(parse_rbs("::Array[::Integer]"))
      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Array")
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

    it "degrades tuples and records to Array and Hash nominals" do
      tuple = described_class.translate(parse_rbs("[::Integer, ::String]"))
      expect(tuple).to be_a(Rigor::Type::Nominal)
      expect(tuple.class_name).to eq("Array")

      record = described_class.translate(parse_rbs("{ a: ::Integer }"))
      expect(record).to be_a(Rigor::Type::Nominal)
      expect(record.class_name).to eq("Hash")
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
