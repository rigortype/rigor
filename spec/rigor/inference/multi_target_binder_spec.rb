# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe Rigor::Inference::MultiTargetBinder do
  def constant(value)
    Rigor::Type::Combinator.constant_of(value)
  end

  def tuple(*elements)
    Rigor::Type::Combinator.tuple_of(*elements)
  end

  def parse_multi_write(source)
    ast = Prism.parse(source).value
    ast.statements.body.first
  end

  describe ".bind" do
    it "binds two targets element-wise from a Tuple rhs" do
      node = parse_multi_write("a, b = [1, 2]")
      result = described_class.bind(node, tuple(constant(1), constant(2)))
      expect(result).to eq(a: constant(1), b: constant(2))
    end

    it "fills extra fronts with Constant[nil] when the tuple is shorter" do
      node = parse_multi_write("a, b, c = [1, 2]")
      result = described_class.bind(node, tuple(constant(1), constant(2)))
      expect(result).to eq(a: constant(1), b: constant(2), c: constant(nil))
    end

    it "ignores extra elements when the tuple is longer" do
      node = parse_multi_write("a, b = [1, 2, 3]")
      result = described_class.bind(node, tuple(constant(1), constant(2), constant(3)))
      expect(result).to eq(a: constant(1), b: constant(2))
    end

    it "binds the rest target as a Tuple of middle elements" do
      node = parse_multi_write("a, *r, c = [1, 2, 3, 4]")
      result = described_class.bind(
        node,
        tuple(constant(1), constant(2), constant(3), constant(4))
      )
      expect(result[:a]).to eq(constant(1))
      expect(result[:c]).to eq(constant(4))
      expect(result[:r]).to eq(tuple(constant(2), constant(3)))
    end

    it "binds the rest as Tuple[] when the source has no surplus elements" do
      node = parse_multi_write("a, *r, c = [1, 2]")
      result = described_class.bind(node, tuple(constant(1), constant(2)))
      expect(result[:a]).to eq(constant(1))
      expect(result[:c]).to eq(constant(2))
      expect(result[:r]).to eq(tuple)
    end

    it "binds a leading rest" do
      node = parse_multi_write("*r, b = [1, 2, 3]")
      result = described_class.bind(node, tuple(constant(1), constant(2), constant(3)))
      expect(result[:r]).to eq(tuple(constant(1), constant(2)))
      expect(result[:b]).to eq(constant(3))
    end

    it "binds a trailing rest" do
      node = parse_multi_write("a, *r = [1, 2, 3]")
      result = described_class.bind(node, tuple(constant(1), constant(2), constant(3)))
      expect(result[:a]).to eq(constant(1))
      expect(result[:r]).to eq(tuple(constant(2), constant(3)))
    end

    it "skips an anonymous splat (`*`)" do
      node = parse_multi_write("a, *, c = [1, 2, 3, 4]")
      result = described_class.bind(
        node,
        tuple(constant(1), constant(2), constant(3), constant(4))
      )
      expect(result).to eq(a: constant(1), c: constant(4))
    end

    it "recurses into nested MultiTargetNodes" do
      node = parse_multi_write("a, (b, c) = [1, [2, 3]]")
      result = described_class.bind(
        node,
        tuple(constant(1), tuple(constant(2), constant(3)))
      )
      expect(result).to eq(a: constant(1), b: constant(2), c: constant(3))
    end

    it "falls back to Dynamic[Top] for every slot when the rhs is not a Tuple" do
      node = parse_multi_write("a, b = foo")
      dyn = Rigor::Type::Combinator.untyped
      nominal = Rigor::Type::Combinator.nominal_of("Object")
      result = described_class.bind(node, nominal)
      expect(result).to eq(a: dyn, b: dyn)
    end

    it "skips non-local targets (instance variables, constants, ...)" do
      node = parse_multi_write("@x, b = [1, 2]")
      result = described_class.bind(node, tuple(constant(1), constant(2)))
      expect(result).to eq(b: constant(2))
    end
  end
end
