# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe Rigor::Inference::ExpressionTyper do
  let(:scope) { Rigor::Scope.empty }

  def parse_expression(source, scopes: [])
    Prism.parse(source, scopes: scopes).value.statements.body.first
  end

  describe "literal nodes" do
    it "types integer literals as Constant<Integer>" do
      type = scope.type_of(parse_expression("42"))
      expect(type.describe).to eq("42")
      expect(type.erase_to_rbs).to eq("Integer")
    end

    it "types float literals as Constant<Float>" do
      type = scope.type_of(parse_expression("2.5"))
      expect(type.describe).to eq("2.5")
      expect(type.erase_to_rbs).to eq("Float")
    end

    it "types string literals as Constant<String>" do
      type = scope.type_of(parse_expression('"hi"'))
      expect(type.describe).to eq('"hi"')
      expect(type.erase_to_rbs).to eq("String")
    end

    it "types symbol literals as Constant<Symbol>" do
      type = scope.type_of(parse_expression(":foo"))
      expect(type.describe).to eq(":foo")
      expect(type.erase_to_rbs).to eq("Symbol")
    end

    it "types true/false/nil as their constant carriers" do
      expect(scope.type_of(parse_expression("true")).describe).to eq("true")
      expect(scope.type_of(parse_expression("false")).describe).to eq("false")
      expect(scope.type_of(parse_expression("nil")).describe).to eq("nil")
    end
  end

  describe "local variables" do
    it "fails soft to Dynamic[Top] for unbound reads" do
      node = parse_expression("x", scopes: [[:x]])
      type = scope.type_of(node)
      expect(type).to equal(Rigor::Type::Combinator.untyped)
    end

    it "looks up bound locals" do
      bound = scope.with_local(:x, Rigor::Type::Combinator.constant_of(1))
      node = parse_expression("x", scopes: [[:x]])
      type = bound.type_of(node)
      expect(type.describe).to eq("1")
    end

    it "types a write expression as the value's type" do
      type = scope.type_of(parse_expression("y = 7"))
      expect(type.describe).to eq("7")
    end

    it "does not mutate the receiver scope on a write expression" do
      _ = scope.type_of(parse_expression("y = 7"))
      expect(scope.local(:y)).to be_nil
    end
  end

  describe "shallow array literals" do
    it "types empty arrays as Array (slice 1 widening)" do
      type = scope.type_of(parse_expression("[]"))
      expect(type.describe).to eq("Array")
      expect(type.erase_to_rbs).to eq("Array")
    end

    it "types non-empty arrays as Array (slice 1 widening)" do
      type = scope.type_of(parse_expression('[1, "hi", :foo]'))
      expect(type.describe).to eq("Array")
    end
  end

  describe "fail-soft policy" do
    it "returns Dynamic[Top] for unrecognised nodes" do
      type = scope.type_of(parse_expression("foo()"))
      expect(type).to equal(Rigor::Type::Combinator.untyped)
    end

    it "never raises on supported Ruby surface" do
      %w[
        if true; 1; else; 2; end
        case 1; when Integer; :i; end
        def foo; 1; end
        Class.new
        @ivar
        $g
        ::Module
        1 + 2
      ].each do |source|
        node = parse_expression(source)
        expect { scope.type_of(node) }.not_to raise_error
      end
    end
  end

  describe "purity" do
    it "produces structurally equal results across calls" do
      node = parse_expression("[1, 2, 3]")
      expect(scope.type_of(node)).to eq(scope.type_of(node))
    end
  end

  describe "virtual nodes" do
    it "round-trips a TypeNode wrapping a Constant" do
      inner = Rigor::Type::Combinator.constant_of(42)
      type = scope.type_of(Rigor::AST::TypeNode.new(inner))
      expect(type).to eq(inner)
    end

    it "round-trips a TypeNode wrapping a Nominal" do
      inner = Rigor::Type::Combinator.nominal_of(String)
      type = scope.type_of(Rigor::AST::TypeNode.new(inner))
      expect(type).to eq(inner)
    end

    it "round-trips a TypeNode wrapping Dynamic[Top]" do
      inner = Rigor::Type::Combinator.untyped
      type = scope.type_of(Rigor::AST::TypeNode.new(inner))
      expect(type).to equal(inner)
    end

    it "does not wrap or annotate the inner type" do
      inner = Rigor::Type::Combinator.nominal_of(Integer)
      type = scope.type_of(Rigor::AST::TypeNode.new(inner))
      expect(type).not_to be_a(Rigor::Type::Dynamic)
    end

    it "fails soft on an unknown synthetic node" do
      unknown_node_class = Class.new do
        include Rigor::AST::Node
        def initialize
          freeze
        end
      end
      type = scope.type_of(unknown_node_class.new)
      expect(type).to equal(Rigor::Type::Combinator.untyped)
    end
  end
end
