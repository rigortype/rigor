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

    # ADR-57 slice 3 — a destructured slot that flow typed as optional (`X | nil`) is softened to its non-nil
    # constituent, because the nil is almost always excluded by a correlated invariant the per-slot flow cannot see (the
    # canonical haml `parse_tag` case).
    it "softens an optional `X | nil` slot to its non-nil constituent" do
      node = parse_multi_write("a, b = pair")
      optional = Rigor::Type::Combinator.union(constant("x"), constant(nil))
      result = described_class.bind(node, tuple(constant(1), optional))
      expect(result[:b]).to eq(constant("x"))
    end

    it "leaves a bare `nil` slot as Constant[nil] (nothing to soften)" do
      node = parse_multi_write("a, b = pair")
      result = described_class.bind(node, tuple(constant(1), constant(nil)))
      expect(result[:b]).to eq(constant(nil))
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

  # Issue #1093. Every decline below is paired with a neighbour that still decomposes, so a construction
  # error that widens everything to `Dynamic[top]` cannot pass the declines on its own.
  describe ".bind_marked over an Array[T] right-hand side" do
    let(:integer) { Rigor::Type::Combinator.nominal_of("Integer") }
    let(:string) { Rigor::Type::Combinator.nominal_of("String") }
    let(:dyn) { Rigor::Type::Combinator.untyped }

    def array_of(element)
      Rigor::Type::Combinator.nominal_of("Array", type_args: [element])
    end

    it "binds each fixed slot to T and a named rest to Array[T], marking only the fixed slots" do
      result = described_class.bind_marked(parse_multi_write("x, *y, z = ints"), array_of(integer))
      expect(result.types).to eq(x: integer, y: array_of(integer), z: integer)
      expect(result.optimistic).to contain_exactly(:x, :z)
    end

    it "binds the rest-free and leading-rest forms consistently" do
      pair = described_class.bind_marked(parse_multi_write("a, b = ints"), array_of(integer))
      expect(pair.types).to eq(a: integer, b: integer)
      expect(pair.optimistic).to contain_exactly(:a, :b)

      leading = described_class.bind_marked(parse_multi_write("*a, b = ints"), array_of(integer))
      expect(leading.types).to eq(a: array_of(integer), b: integer)
      expect(leading.optimistic).to contain_exactly(:b)
    end

    it "decomposes through a Difference base (non-empty-array[T] after an empty? guard)" do
      non_empty = Rigor::Type::Combinator.non_empty_array(integer)
      expect(non_empty).to be_a(Rigor::Type::Difference)
      result = described_class.bind_marked(parse_multi_write("first, *rest = ints"), non_empty)
      expect(result.types).to eq(first: integer, rest: array_of(integer))
    end

    it "recurses into nested targets with T as the new right-hand side, inheriting the mark" do
      element = tuple(integer, string)
      result = described_class.bind_marked(parse_multi_write("(p, q), r = pairs"), array_of(element))
      expect(result.types).to eq(p: integer, q: string, r: element)
      expect(result.optimistic).to contain_exactly(:p, :q, :r)
    end

    it "marks the names under an optimistic parent slot even when the slot itself is a Tuple" do
      node = Prism.parse("foo { |(g, h)| g }").value.statements.body.first.block.parameters.parameters.requireds.first
      result = described_class.bind_marked(node, tuple(integer, string), optimistic: true)
      expect(result.types).to eq(g: integer, h: string)
      expect(result.optimistic).to contain_exactly(:g, :h)
    end

    it "keeps Dynamic[top] per slot for raw Array, Array[untyped] and Dynamic[Array[T]]" do
      node = parse_multi_write("a, *r = xs")
      [
        Rigor::Type::Combinator.nominal_of("Array"),
        array_of(dyn),
        Rigor::Type::Combinator.dynamic(array_of(integer))
      ].each do |carrier|
        result = described_class.bind_marked(node, carrier)
        expect(result.types).to eq(a: dyn, r: dyn), "for #{carrier.describe}"
        expect(result.optimistic).to be_empty
      end
    end

    it "leaves Tuple decomposition unmarked" do
      result = described_class.bind_marked(parse_multi_write("a, b = [1, 2]"), tuple(constant(1), constant(2)))
      expect(result.types).to eq(a: constant(1), b: constant(2))
      expect(result.optimistic).to be_empty
    end

    it "records the mark on the scope through Result#apply_to" do
      result = described_class.bind_marked(parse_multi_write("a, *r = ints"), array_of(integer))
      scope = result.apply_to(Rigor::Scope.empty)
      expect(scope.local(:a)).to eq(integer)
      expect(scope.optimistic_local(:a)).to eq(Rigor::Inference::OptimisticOrigin::IMPLICITLY_RETURNS_NIL)
      expect(scope.optimistic_local(:r)).to be_nil
    end
  end
end
