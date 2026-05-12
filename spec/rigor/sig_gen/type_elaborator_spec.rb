# frozen_string_literal: true

RSpec.describe Rigor::SigGen::TypeElaborator do
  let(:environment) { Rigor::Environment.default }

  def elaborate(type)
    described_class.elaborate(type, environment: environment)
  end

  it "fills `Array` (one type parameter) with `untyped`" do
    type = Rigor::Type::Combinator.nominal_of("Array")
    result = elaborate(type)

    expect(result.erase_to_rbs).to eq("Array[untyped]")
  end

  it "fills `Hash` (two type parameters) with two `untyped`s" do
    type = Rigor::Type::Combinator.nominal_of("Hash")
    result = elaborate(type)

    expect(result.erase_to_rbs).to eq("Hash[untyped, untyped]")
  end

  it "leaves non-generic classes (`String`, `Integer`) alone" do
    type = Rigor::Type::Combinator.nominal_of("String")
    result = elaborate(type)

    expect(result.erase_to_rbs).to eq("String")
  end

  it "leaves already-applied generic forms alone" do
    type = Rigor::Type::Combinator.nominal_of(
      "Array",
      type_args: [Rigor::Type::Combinator.nominal_of("Integer")]
    )
    result = elaborate(type)

    expect(result.erase_to_rbs).to eq("Array[Integer]")
  end

  it "elaborates members of a union" do
    type = Rigor::Type::Combinator.union(
      Rigor::Type::Combinator.nominal_of("Array"),
      Rigor::Type::Combinator.nominal_of("Hash")
    )
    result = elaborate(type)

    expect(result.erase_to_rbs).to eq("Array[untyped] | Hash[untyped, untyped]")
  end

  it "elaborates nested generic args" do
    inner = Rigor::Type::Combinator.nominal_of("Array")
    outer = Rigor::Type::Combinator.nominal_of("Array", type_args: [inner])
    result = elaborate(outer)

    expect(result.erase_to_rbs).to eq("Array[Array[untyped]]")
  end

  it "elaborates tuple elements" do
    tuple = Rigor::Type::Tuple.new([Rigor::Type::Combinator.nominal_of("Array")])
    result = elaborate(tuple)

    expect(result.erase_to_rbs).to eq("[Array[untyped]]")
  end

  it "passes unknown / unresolvable class names through unchanged" do
    type = Rigor::Type::Combinator.nominal_of("UnknownThing")
    result = elaborate(type)

    expect(result.erase_to_rbs).to eq("UnknownThing")
  end
end
