# frozen_string_literal: true

require "prism"

RSpec.describe Rigor::Inference::BlockParameterBinder do
  def parse_block(source)
    program = Prism.parse(source).value
    call = program.statements.body.first
    call.block
  end

  def integer_nominal
    Rigor::Type::Combinator.nominal_of("Integer")
  end

  def string_nominal
    Rigor::Type::Combinator.nominal_of("String")
  end

  def untyped
    Rigor::Type::Combinator.untyped
  end

  describe "#bind" do
    it "returns an empty hash when the block has no parameters" do
      block = parse_block("foo { 1 }")
      bindings = described_class.new(expected_param_types: []).bind(block)
      expect(bindings).to eq({})
    end

    it "binds a single required positional to the matching expected type" do
      block = parse_block("foo { |x| x }")
      bindings = described_class.new(expected_param_types: [integer_nominal]).bind(block)
      expect(bindings).to eq(x: integer_nominal)
    end

    it "binds multiple required positionals in order" do
      block = parse_block("foo { |a, b| a }")
      bindings = described_class.new(
        expected_param_types: [integer_nominal, string_nominal]
      ).bind(block)
      expect(bindings).to eq(a: integer_nominal, b: string_nominal)
    end

    it "defaults a required positional to Dynamic[Top] when the array is shorter" do
      block = parse_block("foo { |a, b| a }")
      bindings = described_class.new(expected_param_types: [integer_nominal]).bind(block)
      expect(bindings[:a]).to eq(integer_nominal)
      expect(bindings[:b]).to eq(untyped)
    end

    it "defaults every parameter to Dynamic[Top] when no expected types are given" do
      block = parse_block("foo { |a, b| a }")
      bindings = described_class.new.bind(block)
      expect(bindings).to eq(a: untyped, b: untyped)
    end

    it "binds optional positionals" do
      block = parse_block("foo { |a, b = 1| a }")
      bindings = described_class.new(
        expected_param_types: [integer_nominal, string_nominal]
      ).bind(block)
      expect(bindings).to eq(a: integer_nominal, b: string_nominal)
    end

    it "binds the rest parameter as Array[Dynamic[Top]] regardless of expected types" do
      block = parse_block("foo { |a, *rest| a }")
      bindings = described_class.new(
        expected_param_types: [integer_nominal]
      ).bind(block)
      expect(bindings[:a]).to eq(integer_nominal)
      array_type = Rigor::Type::Combinator.nominal_of("Array", type_args: [untyped])
      expect(bindings[:rest]).to eq(array_type)
    end

    it "binds keyword parameters as Dynamic[Top] (no RBS introspection in sub-phase 1)" do
      block = parse_block("foo { |a, k:, m: 0| a }")
      bindings = described_class.new(expected_param_types: [integer_nominal]).bind(block)
      expect(bindings[:a]).to eq(integer_nominal)
      expect(bindings[:k]).to eq(untyped)
      expect(bindings[:m]).to eq(untyped)
    end

    it "binds the keyword-rest parameter as Hash[Symbol, Dynamic[Top]]" do
      block = parse_block("foo { |**opts| 1 }")
      bindings = described_class.new.bind(block)
      symbol_nominal = Rigor::Type::Combinator.nominal_of("Symbol")
      expected = Rigor::Type::Combinator.nominal_of(
        "Hash",
        type_args: [symbol_nominal, untyped]
      )
      expect(bindings[:opts]).to eq(expected)
    end

    it "binds the explicit block parameter as Nominal[Proc]" do
      block = parse_block("foo { |a, &blk| a }")
      bindings = described_class.new(expected_param_types: [integer_nominal]).bind(block)
      expect(bindings[:blk]).to eq(Rigor::Type::Combinator.nominal_of(Proc))
    end

    it "binds MultiTargetNode block parameters with a non-Tuple slot to Dynamic[Top]" do
      # When the slot expected type is not a Tuple, MultiTargetBinder
      # falls back to Dynamic[Top] for every inner local. The outer
      # `c` still binds to its slot type.
      block = parse_block("foo { |(a, b), c| c }")
      bindings = described_class.new(
        expected_param_types: [integer_nominal, string_nominal]
      ).bind(block)
      dyn = Rigor::Type::Combinator.untyped
      expect(bindings).to eq(a: dyn, b: dyn, c: string_nominal)
    end

    it "binds trailing positionals" do
      block = parse_block("foo { |a, b, c| a }")
      bindings = described_class.new(
        expected_param_types: [integer_nominal, string_nominal, integer_nominal]
      ).bind(block)
      expect(bindings).to eq(a: integer_nominal, b: string_nominal, c: integer_nominal)
    end

    it "binds numbered-block parameters from NumberedParametersNode" do
      # `_1` is implicit; Slice 6 phase C sub-phase 2 binds it from
      # the per-position expected_param_types array, just like an
      # explicit `|x|` would.
      block = parse_block("foo { _1.succ }")
      expect(block.parameters).to be_a(Prism::NumberedParametersNode)
      bindings = described_class.new(expected_param_types: [integer_nominal]).bind(block)
      expect(bindings).to eq(_1: integer_nominal)
    end

    it "binds multiple numbered-block parameters up to the body's maximum" do
      block = parse_block("foo { _1 + _2 }")
      bindings = described_class.new(
        expected_param_types: [integer_nominal, integer_nominal]
      ).bind(block)
      expect(bindings).to eq(_1: integer_nominal, _2: integer_nominal)
    end

    it "defaults missing numbered slots to Dynamic[Top]" do
      block = parse_block("foo { _1 + _2 }")
      bindings = described_class.new(expected_param_types: [integer_nominal]).bind(block)
      expect(bindings[:_1]).to eq(integer_nominal)
      expect(bindings[:_2]).to eq(Rigor::Type::Combinator.untyped)
    end

    it "destructures MultiTargetNode block parameters element-wise from a Tuple" do
      block = parse_block("foo { |(a, b), c| a }")
      tuple = Rigor::Type::Combinator.tuple_of(integer_nominal, string_nominal)
      bindings = described_class.new(
        expected_param_types: [tuple, integer_nominal]
      ).bind(block)
      expect(bindings).to eq(a: integer_nominal, b: string_nominal, c: integer_nominal)
    end

    it "falls back to Dynamic[Top] for MultiTargetNode slots when the slot is not a Tuple" do
      block = parse_block("foo { |(a, b)| a }")
      bindings = described_class.new(expected_param_types: [integer_nominal]).bind(block)
      dyn = Rigor::Type::Combinator.untyped
      expect(bindings).to eq(a: dyn, b: dyn)
    end
  end
end
