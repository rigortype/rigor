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
  end

  describe "stack safety" do
    it "does not recurse into RETURN_BARRIER_NODES (def/lambda/block)" do
      source = <<~RUBY
        def outer
          inner = -> { return 1 }
          return 2
        end
      RUBY
      def_node = parse_def(source)
      returns = []
      described_class.collect_return_types(def_node.body, scope_index, returns)
      expect(returns.size).to eq(0)
    end
  end

  describe "private helpers" do
    describe ".body_last_expression" do
      it "extracts the last statement from a StatementsNode" do
        body = parse_def("def foo; 1; 2; end").body
        result = described_class.body_last_expression(body)
        expect(result).to be_a(Prism::IntegerNode)
        expect(result.value).to eq(2)
      end

      it "unwraps a BeginNode to its statements" do
        body = parse_def("def foo; begin; 1; rescue; 2; end; end").body
        result = described_class.body_last_expression(body)
        expect(result).not_to be_nil
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
