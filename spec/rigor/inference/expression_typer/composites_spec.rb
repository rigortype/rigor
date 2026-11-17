# frozen_string_literal: true

require "spec_helper"
require "prism"

# ADR-116 C4 — `ExpressionTyper::Composites` types the nodes whose answer is built from their children's types: hash,
# array, range and interpolation literals, and the pass-through nodes (parentheses, statements, `else`, `ensure`,
# `when` / `in`, a `class` body). The examples parse a snippet and call the entry with a real typer over a scope that
# binds the locals the snippet reads, which is the module's one callback (`typer.type_of`).
RSpec.describe Rigor::Inference::ExpressionTyper::Composites do
  let(:combinator) { Rigor::Type::Combinator }
  let(:integer) { combinator.nominal_of("Integer") }
  let(:string) { combinator.nominal_of("String") }
  let(:scope) { Rigor::Scope.empty.with_local(:n, integer).with_local(:s, string) }
  let(:typer) { Rigor::Inference::ExpressionTyper.new(scope: scope) }

  def node_of(source) = Prism.parse(source, scopes: [%i[n s]]).value.statements.body.first

  describe ".type_of_hash" do
    def hash_type(source) = described_class.type_of_hash(node_of(source), typer)

    it "types the empty literal as the empty HashShape" do
      expect(hash_type("{}").describe).to eq("{}")
    end

    it "pins a shape for symbol, string, integer and mixed literal keys" do
      expect(hash_type("{ a: 1, b: n }").describe).to eq("{ a: 1, b: Integer }")
      expect(hash_type('{ "k" => 1, 2 => :z }').describe).to eq('{ "k" => 1, 2 => :z }')
    end

    it "keeps the last value of a duplicate key, at the key's first position" do
      expect(hash_type("{ a: 1, b: 2, a: 3 }").describe).to eq("{ a: 3, b: 2 }")
    end

    it "keeps `nil` and `false` as real keys" do
      expect(hash_type("{ nil => 1, false => 2 }").pairs.keys).to eq([nil, false])
    end

    it "falls back to Hash[K, V] when a key is not a pinned literal" do
      expect(hash_type("{ n => 1, s => :a }").describe).to eq("Hash[Integer | String, 1 | :a]")
      expect(hash_type("{ \"a\#{n}\" => 1 }").describe).to eq("Hash[String, 1]")
    end

    it "joins what a `**splat` copies with Dynamic[top], and never keeps a shape over it" do
      other = Rigor::Scope.empty.with_local(:o, combinator.hash_shape_of({ a: combinator.constant_of(:z) }))
      type = described_class.type_of_hash(Prism.parse("{ **o, b: :y }", scopes: [[:o]]).value.statements.body.first,
                                          Rigor::Inference::ExpressionTyper.new(scope: other))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Hash")
      expect(type.type_args.map(&:describe)).to eq([":a | :b | Dynamic[top]", ":y | :z | Dynamic[top]"])
    end

    it "reads an anonymous or untyped splat as Dynamic[top] on both sides" do
      type = hash_type("{ **s }")

      expect(type.type_args.map(&:describe)).to eq(["Dynamic[top]", "Dynamic[top]"])
    end

    it "reads a `**nil` splat as copying nothing" do
      nil_scope = Rigor::Scope.empty.with_local(:o, combinator.constant_of(nil))
      node = Prism.parse("{ **o, b: 1 }", scopes: [[:o]]).value.statements.body.first
      type = described_class.type_of_hash(node, Rigor::Inference::ExpressionTyper.new(scope: nil_scope))

      expect(type.type_args.map(&:describe)).to eq([":b | Dynamic[top]", "1 | Dynamic[top]"])
    end
  end

  describe "interpolation" do
    it "types an interpolated string whose parts are all literal-string-compatible as literal-string" do
      node = node_of(%("a\#{"x"}b"))

      expect(described_class.type_of_interpolated_string(node, typer).describe).to eq("literal-string")
    end

    it "widens to Nominal[String] when a part is not literal-bearing" do
      expect(described_class.type_of_interpolated_string(node_of(%("a\#{n}")), typer).describe).to eq("String")
    end

    it "types an embedded statement as the type of its last statement" do
      embedded = node_of("\"\#{1; n}\"").parts.first

      expect(described_class.type_of_embedded_statements(embedded, typer)).to equal(integer)
    end
  end

  describe ".array_type_for" do
    it "types the empty literal as the empty Tuple and a plain literal as a Tuple of its elements" do
      expect(described_class.array_type_for(node_of("[]"), typer).describe).to eq("[]")
      expect(described_class.array_type_for(node_of("[1, n, s]"), typer).describe).to eq("[1, Integer, String]")
    end

    it "widens a splatted literal to Array of the union of its elements" do
      expect(described_class.array_type_for(node_of("[*n, s]"), typer).describe).to eq("Array[Dynamic[top] | String]")
    end
  end

  describe ".type_of_range" do
    def range_type(source) = described_class.type_of_range(node_of(source), typer)

    it "folds literal endpoints to a Constant Range, inclusive or exclusive" do
      expect(range_type("1..3").value).to eq(1..3)
      expect(range_type("1...3").value).to eq(1...3)
    end

    it "folds an endless and a beginless range" do
      expect(range_type("1..").value).to eq(1..)
      expect(range_type("..3").value).to eq(..3)
    end

    it "folds a string endpoint and an endpoint whose type is a Constant" do
      expect(range_type('"a".."c"').value).to eq("a".."c")
      constant = Rigor::Scope.empty.with_local(:n, combinator.constant_of(4))
      node = node_of("1..n")

      expect(described_class.type_of_range(node, Rigor::Inference::ExpressionTyper.new(scope: constant)).value)
        .to eq(1..4)
    end

    it "declines the fold for endpoints Ruby refuses to build a Range from" do
      expect(range_type('1.."a"').describe).to eq("Range[Integer | String]")
    end

    it "types a range over non-literal endpoints as Range of their element type" do
      expect(range_type("n..n").describe).to eq("Range[Integer]")
      expect(range_type("1..n").describe).to eq("Range[Integer]")
    end

    it "types a range no endpoint types as the bare Range" do
      untyped = Rigor::Scope.empty
      node = Prism.parse("a..b", scopes: [%i[a b]]).value.statements.body.first

      expect(described_class.type_of_range(node, Rigor::Inference::ExpressionTyper.new(scope: untyped)).describe)
        .to eq("Range")
    end
  end

  describe "pass-through nodes" do
    it "types parentheses as their body, and `()` as nil" do
      expect(described_class.parentheses_type_for(node_of("(n)"), typer)).to equal(integer)
      expect(described_class.parentheses_type_for(node_of("()"), typer).describe).to eq("nil")
    end

    it "types statements as the last one" do
      expect(described_class.type_of_statements_node(node_of("(1; s)").body, typer)).to equal(string)
    end

    it "types a program as its statements" do
      program = Prism.parse("n", scopes: [%i[n s]]).value

      expect(described_class.type_of_program(program, typer)).to equal(integer)
    end

    it "types `else`, `ensure` and a `when` clause as their statements, and an empty one as nil" do
      conditional = node_of("if n then 1 else s end")
      ensure_node = node_of("begin; 1; ensure; n; end").ensure_clause
      when_node = node_of("case n when 1 then s end").conditions.first

      expect(described_class.type_of_else(conditional.subsequent, typer)).to equal(string)
      expect(described_class.type_of_ensure(ensure_node, typer)).to equal(integer)
      expect(described_class.type_of_when_or_in(when_node, typer)).to equal(string)
      expect(described_class.statements_or_nil(nil, typer).describe).to eq("nil")
    end

    it "types a class body as its last expression, and an empty class as nil" do
      expect(described_class.type_of_class_or_module(node_of("class A; 1; end"), typer).describe).to eq("1")
      expect(described_class.type_of_class_or_module(node_of("class A; end"), typer).describe).to eq("nil")
    end

    it "types a shareable-constant wrapper and a `{ x: }` shorthand value as what they wrap" do
      wrapped = node_of("# shareable_constant_value: literal\nA = 1")
      shorthand = node_of("{ n: }").elements.first.value

      expect(wrapped).to be_a(Prism::ShareableConstantNode)
      expect(described_class.type_of_shareable_constant(wrapped, typer).describe).to eq("1")
      expect(described_class.type_of_implicit(shorthand, typer)).to equal(integer)
    end
  end
end
