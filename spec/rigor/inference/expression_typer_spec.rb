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
      first = scope.type_of(node)
      second = scope.type_of(node)
      expect(first).to eq(second)
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

  describe "fallback tracer" do
    let(:tracer) { Rigor::Inference::FallbackTracer.new }

    it "records nothing when no fallback occurs" do
      scope.type_of(parse_expression("42"), tracer: tracer)
      expect(tracer).to be_empty
    end

    it "records a Prism-family fallback for unrecognised Prism nodes" do
      node = parse_expression("foo()")
      type = scope.type_of(node, tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer.size).to eq(1)
      event = tracer.events.first
      expect(event.node_class).to eq(node.class)
      expect(event.family).to eq(:prism)
      expect(event.inner_type).to equal(Rigor::Type::Combinator.untyped)
      expect(event.location).not_to be_nil
    end

    it "records a virtual-family fallback for unknown synthetic nodes" do
      unknown_node_class = Class.new do
        include Rigor::AST::Node

        def initialize
          freeze
        end
      end
      type = scope.type_of(unknown_node_class.new, tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer.size).to eq(1)
      event = tracer.events.first
      expect(event.family).to eq(:virtual)
      expect(event.location).to be_nil
    end

    it "records nested fallbacks discovered while traversing children" do
      # ArrayNode is recognised in slice 1; its element CallNode is not.
      node = parse_expression("[foo(), 1]")
      scope.type_of(node, tracer: tracer)
      expect(tracer.kinds).to include(Prism::CallNode)
    end

    it "does not change the type returned regardless of tracer presence" do
      node = parse_expression("foo()")
      with_tracer = scope.type_of(node, tracer: tracer)
      without_tracer = scope.type_of(node)
      expect(with_tracer).to eq(without_tracer)
    end

    it "leaves recognised TypeNode synthetic nodes untraced" do
      type_node = Rigor::AST::TypeNode.new(Rigor::Type::Combinator.constant_of(1))
      scope.type_of(type_node, tracer: tracer)
      expect(tracer).to be_empty
    end
  end

  describe "method dispatch (Slice 2)" do
    it "folds Constant Integer + Constant Integer into Constant" do
      type = scope.type_of(parse_expression("1 + 2"))

      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(3)
    end

    it "folds nested arithmetic expressions" do
      type = scope.type_of(parse_expression("(1 + 2) * 3"))

      expect(type.value).to eq(9)
    end

    it "folds string concatenation between Constant Strings" do
      type = scope.type_of(parse_expression('"foo" + "bar"'))

      expect(type.value).to eq("foobar")
    end

    it "folds symbol equality into Constant boolean" do
      type = scope.type_of(parse_expression(":a == :a"))

      expect(type.value).to be(true)
    end

    it "falls back to Dynamic[Top] for calls with no receiver" do
      tracer = Rigor::Inference::FallbackTracer.new
      node = parse_expression("foo()")
      type = scope.type_of(node, tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer.kinds).to include(Prism::CallNode)
    end

    it "falls back to Dynamic[Top] for receivers the dispatcher cannot fold" do
      tracer = Rigor::Inference::FallbackTracer.new
      node = parse_expression("[1, 2].map")
      type = scope.type_of(node, tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer.kinds).to include(Prism::CallNode)
    end

    it "falls back when an argument is not a Constant" do
      tracer = Rigor::Inference::FallbackTracer.new
      node = parse_expression("1 + bar()")
      type = scope.type_of(node, tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer.kinds).to include(Prism::CallNode)
    end

    it "treats ArgumentsNode as a non-value position (Dynamic[Top], no fallback)" do
      tracer = Rigor::Inference::FallbackTracer.new
      call_node = parse_expression("foo(1, 2)")
      arguments_node = call_node.arguments

      type = scope.type_of(arguments_node, tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer).to be_empty
    end
  end

  describe "constant resolution (Slice 2 strengthening)" do
    it "resolves a registered Slice 1 built-in via ConstantReadNode" do
      type = scope.type_of(parse_expression("Integer"))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Integer")
    end

    it "resolves Slice 2 built-ins like Hash and StandardError" do
      hash_type = scope.type_of(parse_expression("Hash"))
      err_type = scope.type_of(parse_expression("StandardError"))

      expect(hash_type.class_name).to eq("Hash")
      expect(err_type.class_name).to eq("StandardError")
    end

    it "falls back to Dynamic[Top] for unknown ConstantReadNode names" do
      tracer = Rigor::Inference::FallbackTracer.new
      type = scope.type_of(parse_expression("Foo"), tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer.kinds).to include(Prism::ConstantReadNode)
    end

    it "resolves a top-level ConstantPathNode (`::Integer`)" do
      type = scope.type_of(parse_expression("::Integer"))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Integer")
    end

    it "falls back to Dynamic[Top] for unregistered ConstantPathNode" do
      tracer = Rigor::Inference::FallbackTracer.new
      type = scope.type_of(parse_expression("Foo::Bar"), tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer.kinds).to include(Prism::ConstantPathNode)
    end

    it "types ConstantWriteNode as the rvalue's type" do
      type = scope.type_of(parse_expression("FOO = 42"))

      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(42)
    end
  end

  describe "containers and definitions (Slice 2 strengthening)" do
    it "types HashNode as Nominal[Hash]" do
      type = scope.type_of(parse_expression("{ a: 1, b: 2 }"))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Hash")
    end

    it "types InterpolatedStringNode as Nominal[String]" do
      type = scope.type_of(parse_expression("\"foo \#{42}\""))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("String")
    end

    it "types InterpolatedSymbolNode as Nominal[Symbol]" do
      type = scope.type_of(parse_expression(":\"foo\#{42}\""))

      expect(type).to be_a(Rigor::Type::Nominal)
      expect(type.class_name).to eq("Symbol")
    end

    it "types DefNode as Constant<Symbol> of the method name" do
      type = scope.type_of(parse_expression("def my_method; end"))

      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(:my_method)
    end

    it "propagates ClassNode body to the last expression's type" do
      type = scope.type_of(parse_expression("class Foo; 42; end"))

      expect(type).to be_a(Rigor::Type::Constant)
      expect(type.value).to eq(42)
    end

    it "types an empty class as Constant<nil>" do
      type = scope.type_of(parse_expression("class Foo; end"))

      expect(type.value).to be_nil
    end

    it "propagates ModuleNode body to the last expression's type" do
      type = scope.type_of(parse_expression("module Foo; :ok; end"))

      expect(type.value).to eq(:ok)
    end

    it "types AliasMethodNode/UndefNode as Constant<nil>" do
      alias_type = scope.type_of(parse_expression("alias new_name old_name"))
      undef_type = scope.type_of(parse_expression("undef foo"))

      expect(alias_type.value).to be_nil
      expect(undef_type.value).to be_nil
    end
  end

  describe "variables and self (Slice 2 strengthening)" do
    let(:tracer) { Rigor::Inference::FallbackTracer.new }

    it "silently types SelfNode as Dynamic[Top]" do
      type = scope.type_of(parse_expression("self"), tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer).to be_empty
    end

    it "silently types InstanceVariableReadNode as Dynamic[Top]" do
      type = scope.type_of(parse_expression("@x"), tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer).to be_empty
    end

    it "types InstanceVariableWriteNode as the rvalue type" do
      type = scope.type_of(parse_expression("@x = 7"), tracer: tracer)

      expect(type.value).to eq(7)
      expect(tracer).to be_empty
    end

    it "silently types ClassVariableReadNode as Dynamic[Top]" do
      type = scope.type_of(parse_expression("@@x"), tracer: tracer)

      expect(type).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer).to be_empty
    end

    it "types InstanceVariableOrWriteNode as the rvalue type" do
      type = scope.type_of(parse_expression("@x ||= 7"), tracer: tracer)

      expect(type.value).to eq(7)
      expect(tracer).to be_empty
    end
  end

  describe "parameter and block positions (Slice 2 strengthening)" do
    let(:tracer) { Rigor::Inference::FallbackTracer.new }

    it "silently types ParametersNode and its parameter children as Dynamic[Top]" do
      def_node = parse_expression("def foo(a, b: 1, *c, **d, &e); end")
      params = def_node.parameters

      expect(scope.type_of(params, tracer: tracer)).to equal(Rigor::Type::Combinator.untyped)
      params.requireds.each do |param|
        expect(scope.type_of(param, tracer: tracer)).to equal(Rigor::Type::Combinator.untyped)
      end
      expect(tracer).to be_empty
    end

    it "silently types BlockNode/BlockParametersNode/BlockArgumentNode as Dynamic[Top]" do
      call_node = parse_expression("foo(&blk) { |x| x }")
      block_node = call_node.block

      expect(scope.type_of(block_node, tracer: tracer)).to equal(Rigor::Type::Combinator.untyped)
      expect(scope.type_of(block_node.parameters, tracer: tracer)).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer).to be_empty
    end
  end

  describe "control flow (Slice 3 phase 1)" do
    let(:tracer) { Rigor::Inference::FallbackTracer.new }

    it "types IfNode as the union of its then-branch and else-branch" do
      type = scope.type_of(parse_expression("if cond; 1; else; 2; end"))
      expected = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(1),
        Rigor::Type::Combinator.constant_of(2)
      )

      expect(type).to eq(expected)
    end

    it "includes Constant<nil> in the IfNode union when there is no else branch" do
      type = scope.type_of(parse_expression("if cond; 1; end"))
      expected = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(1),
        Rigor::Type::Combinator.constant_of(nil)
      )

      expect(type).to eq(expected)
    end

    it "unions through elsif chains" do
      type = scope.type_of(parse_expression("if a; 1; elsif b; 2; else; 3; end"))
      expected = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(1),
        Rigor::Type::Combinator.constant_of(2),
        Rigor::Type::Combinator.constant_of(3)
      )

      expect(type).to eq(expected)
    end

    it "types UnlessNode using its else_clause field" do
      type = scope.type_of(parse_expression("unless cond; 1; else; 2; end"))
      expected = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(1),
        Rigor::Type::Combinator.constant_of(2)
      )

      expect(type).to eq(expected)
    end

    it "types AndNode as the union of its operands" do
      type = scope.type_of(parse_expression("1 && 2"))
      expected = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(1),
        Rigor::Type::Combinator.constant_of(2)
      )

      expect(type).to eq(expected)
    end

    it "types OrNode as the union of its operands" do
      type = scope.type_of(parse_expression("1 || 2"))
      expected = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(1),
        Rigor::Type::Combinator.constant_of(2)
      )

      expect(type).to eq(expected)
    end

    it "types CaseNode as the union of every when body and the else clause" do
      source = "case x; when 1; :a; when 2; :b; else; :c; end"
      type = scope.type_of(parse_expression(source))
      expected = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(:a),
        Rigor::Type::Combinator.constant_of(:b),
        Rigor::Type::Combinator.constant_of(:c)
      )

      expect(type).to eq(expected)
    end

    it "types BeginNode/RescueNode as the union of the body and rescue chain" do
      source = "begin; 1; rescue ArgumentError; 2; rescue; 3; end"
      type = scope.type_of(parse_expression(source))
      expected = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(1),
        Rigor::Type::Combinator.constant_of(2),
        Rigor::Type::Combinator.constant_of(3)
      )

      expect(type).to eq(expected)
    end

    it "uses the else clause as the begin's primary value when no exception fires" do
      source = "begin; 1; rescue; 2; else; :ok; end"
      type = scope.type_of(parse_expression(source))
      expected = Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.constant_of(:ok),
        Rigor::Type::Combinator.constant_of(2)
      )

      expect(type).to eq(expected)
    end

    it "types `expr rescue fallback` as the union of both expressions" do
      type = scope.type_of(parse_expression("foo rescue 42"))

      expect(type.describe).to include("42")
    end

    it "types ReturnNode/BreakNode/NextNode/RetryNode as Bot" do
      bot = Rigor::Type::Combinator.bot

      expect(scope.type_of(parse_expression("return 1"))).to equal(bot)
      expect(scope.type_of(parse_expression("loop { break 1 }").block.body.body.first)).to equal(bot)
      expect(scope.type_of(parse_expression("loop { next 1 }").block.body.body.first)).to equal(bot)
    end

    it "collapses Bot under union (return inside an if branch is absorbed)" do
      type = scope.type_of(parse_expression("if cond; return; else; 7; end"))

      expect(type).to eq(Rigor::Type::Combinator.constant_of(7))
    end

    it "types YieldNode as Dynamic[Top]" do
      def_node = parse_expression("def foo; yield(1); end")
      yield_node = def_node.body.body.first

      expect(scope.type_of(yield_node, tracer: tracer)).to equal(Rigor::Type::Combinator.untyped)
      expect(tracer).to be_empty
    end

    it "types WhileNode and UntilNode as Constant<nil>" do
      while_type = scope.type_of(parse_expression("while cond; 1; end"))
      until_type = scope.type_of(parse_expression("until cond; 1; end"))

      expect(while_type.value).to be_nil
      expect(until_type.value).to be_nil
    end

    it "types LambdaNode as Nominal[Proc]" do
      type = scope.type_of(parse_expression("-> { 42 }"))

      expect(type.class_name).to eq("Proc")
    end

    it "types RangeNode as Nominal[Range]" do
      type = scope.type_of(parse_expression("(1..10)"))

      expect(type.class_name).to eq("Range")
    end

    it "types RegularExpressionNode as Nominal[Regexp]" do
      type = scope.type_of(parse_expression("/foo/"))

      expect(type.class_name).to eq("Regexp")
    end
  end
end
