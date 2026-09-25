# frozen_string_literal: true

require "prism"

RSpec.describe Rigor::Inference::DefReturnTyper do
  def parse_def(source)
    Prism.parse(source).value.statements.body.first
  end

  let(:scope_index) { {} }
  let(:empty_scope) { Rigor::Scope.empty }

  describe ".body_last_expression" do
    it "returns the last statement of a StatementsNode body" do
      def_node = parse_def("def foo; 1; 2; end")
      last = described_class.body_last_expression(def_node.body)
      expect(last).to be_a(Prism::IntegerNode)
      expect(last.value).to eq(2)
    end
  end

  describe ".call" do
    it "returns nil for an empty body" do
      def_node = parse_def("def foo; end")
      expect(described_class.call(def_node, scope_index)).to be_nil
    end

    it "returns nil when no scope is found for the last expression" do
      def_node = parse_def("def foo; x = 1; end")
      expect(described_class.call(def_node, scope_index)).to be_nil
    end

    it "returns nil when scope.type_of raises (fail-soft)" do
      def_node = parse_def("def foo; unknown_method; end")
      result = described_class.call(def_node, scope_index)
      expect(result).to be_nil
    end

    it "returns the inferred type for a simple method body" do
      def_node = parse_def("def foo; 1; end")
      int_type = Rigor::Type::Combinator.constant_of(1)
      scope = instance_double(Rigor::Scope, type_of: int_type)
      indexed = { def_node.body => scope }
      expect(described_class.call(def_node, indexed)).to eq(int_type)
    end

    it "unions the last expression with explicit return values" do
      def_node = parse_def("def foo; return 1; 2; end")
      last_expr = described_class.body_last_expression(def_node.body)
      int_type = Rigor::Type::Combinator.constant_of(1)
      scope = instance_double(Rigor::Scope, type_of: int_type)
      return_node = def_node.body.body.first
      indexed = { last_expr => scope, return_node => scope }
      expected = Rigor::Type::Combinator.union(int_type, int_type)
      expect(described_class.call(def_node, indexed)).to eq(expected)
    end
  end

  describe "return barriers" do
    # A bare `return` types as `nil` without a scope, so the count of collected types is the count of `return`s the
    # walk credited to the method.
    def collected_returns(source)
      out = []
      described_class.collect_return_types(parse_def(source).body, scope_index, out)
      out
    end

    it "does not recurse into a lambda literal (the inner return has no scope, so nothing is collected)" do
      source = <<~RUBY
        def outer
          inner = -> { return 1 }
          return 2
        end
      RUBY
      expect(collected_returns(source).size).to eq(0)
    end

    # Issue #1382 — a block `return` exits the enclosing method (control-flow-analysis.md § "Non-local exits").
    it "credits a `return` inside an ordinary block to the method" do
      expect(collected_returns("def m; [1].each { return }; 2; end").size).to eq(1)
    end

    it "credits a `return` inside a `proc` block, which only widens the type" do
      expect(collected_returns("def m; proc { return }; 2; end").size).to eq(1)
    end

    it "credits a `return` in a block nested inside another block" do
      expect(collected_returns("def m; [1].each { |x| [x].map { return } }; 2; end").size).to eq(1)
    end

    [
      "-> { return }",
      "lambda { return }",
      "define_method(:x) { return }",
      "self.define_method(:x) { return }",
      "define_singleton_method(:x) { return }",
      "send(:define_method, :x) { return }",
      "public_send(:lambda) { return }",
      "Kernel.lambda { return }",
      "klass.define_method(:x) { return }",
      "self.class.define_method(:x) { return }",
      "mod.define_singleton_method(:x) { return }",
      "klass.__send__(:define_method, :x) { return }",
      "def inner; return; end"
    ].each do |barrier|
      it "does not credit a `return` inside `#{barrier}`" do
        expect(collected_returns("def m; #{barrier}; 2; end")).to be_empty
      end
    end

    it "credits a `return` inside a `lambda` block on a receiver that is not `Kernel`" do
      expect(collected_returns("def m(obj); obj.lambda { return }; 2; end").size).to eq(1)
    end

    it "still credits a `return` in a barrier call's arguments" do
      expect(collected_returns("def m(f); define_method(f ? :x : (return)) { 1 }; 2; end").size).to eq(1)
    end
  end

  describe "private helpers" do
    describe ".union_with_explicit_returns" do
      it "returns the last_type when there are no explicit returns" do
        body = parse_def("def foo; 1; end").body
        result = described_class.union_with_explicit_returns(body, :int_type, scope_index)
        expect(result).to eq(:int_type)
      end

      it "unions last_type with collected return types" do
        source = <<~RUBY
          def foo
            return 1
            2
          end
        RUBY
        body = parse_def(source).body
        return_node = body.body.first
        ret_type = Rigor::Type::Combinator.constant_of(1)
        return_scope = instance_double(Rigor::Scope, type_of: ret_type)
        last_type = Rigor::Type::Combinator.constant_of(2)
        indexed = { return_node => return_scope }
        result = described_class.union_with_explicit_returns(body, last_type, indexed)
        expect(result).to eq(Rigor::Type::Combinator.union(last_type, ret_type))
      end
    end

    describe ".collect_return_types" do
      it "collects the type of a single-value return" do
        source = "def foo; return 1; end"
        body = parse_def(source).body
        ret_type = Rigor::Type::Combinator.constant_of(1)
        scope = instance_double(Rigor::Scope, type_of: ret_type)
        return_node = body.body.first
        indexed = { return_node => scope }
        out = []
        described_class.collect_return_types(body, indexed, out)
        expect(out.size).to eq(1)
        expect(out.first).to eq(ret_type)
      end

      it "collects nil for bare 'return'" do
        source = "def foo; return; end"
        body = parse_def(source).body
        out = []
        described_class.collect_return_types(body, scope_index, out)
        expect(out.size).to eq(1)
        expect(out.first).to be_a(Rigor::Type::Constant)
        expect(out.first.value).to be_nil
      end
    end

    describe ".body_last_expression" do
      it "extracts the last statement from a StatementsNode" do
        body = parse_def("def foo; 1; 2; end").body
        result = described_class.body_last_expression(body)
        expect(result).to be_a(Prism::IntegerNode)
        expect(result.value).to eq(2)
      end

      it "recurses through a BeginNode body to its inner last statement" do
        # The inline def-rescue form parses with a BeginNode *body* directly (an explicit `begin…end` nests under a
        # StatementsNode instead), so this is what exercises the recursive `Prism::BeginNode` arm — and the exact-value
        # assertion pins the unwrap rather than merely non-nil.
        body = parse_def("def foo; 1; rescue; 2; end").body
        expect(body).to be_a(Prism::BeginNode)
        result = described_class.body_last_expression(body)
        expect(result).to be_a(Prism::IntegerNode)
        expect(result.value).to eq(1)
      end
    end

    describe ".safe_type_of" do
      it "returns the type when scope.type_of succeeds" do
        scope = instance_double(Rigor::Scope, type_of: :some_type)
        node = instance_double(Prism::Node)
        expect(described_class.safe_type_of(scope, node)).to eq(:some_type)
      end

      it "returns nil when scope.type_of raises" do
        scope = instance_double(Rigor::Scope)
        allow(scope).to receive(:type_of).and_raise(StandardError)
        node = instance_double(Prism::Node)
        expect(described_class.safe_type_of(scope, node)).to be_nil
      end
    end

    describe ".type_return_node" do
      it "adds nil constant for bare 'return' (no arguments)" do
        source = "def foo; return; 1; end"
        def_node = parse_def(source)
        return_node = def_node.body.body.first
        out = []
        described_class.type_return_node(return_node, scope_index, out)
        expect(out.size).to eq(1)
        expect(out.first).to be_a(Rigor::Type::Constant)
        expect(out.first.value).to be_nil
      end
    end
  end
end
