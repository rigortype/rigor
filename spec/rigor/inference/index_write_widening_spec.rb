# frozen_string_literal: true

require "spec_helper"
require "prism"

require "rigor/inference/index_write_widening"
require "rigor/scope"
require "rigor/type"

# `h[k] ||= v` and its `&&=` / `+=` siblings are not `[]=` CallNodes, so they bypassed
# {Rigor::Inference::MutationWidening.widen_after_call} entirely and a literal-shape binding survived a
# mutation that invalidated it. The straight-line consumer is `StatementEvaluator`; the cross-method
# one is `ScopeIndexer`'s class-ivar pre-pass. Both are exercised end-to-end by
# `spec/integration/fixtures/index_write_mutation_widening.rb`; this file pins the primitive.
RSpec.describe Rigor::Inference::IndexWriteWidening do
  describe ".index_write?" do
    def parse_last(source)
      Prism.parse(source).value.statements.body.last
    end

    it "recognises the three write forms" do
      expect(described_class.index_write?(parse_last("h[:a] ||= 1\n"))).to be true
      expect(described_class.index_write?(parse_last("h[:a] &&= 1\n"))).to be true
      expect(described_class.index_write?(parse_last("h[:a] += 1\n"))).to be true
    end

    it "declines a plain `[]=` CallNode (already covered by widen_after_call) and an index READ" do
      expect(described_class.index_write?(parse_last("h[:a] = 1\n"))).to be false
      expect(described_class.index_write?(parse_last("h[:a]\n"))).to be false
    end
  end

  describe ".widen" do
    def parse_first(source)
      Prism.parse(source).value.statements.body.last
    end

    let(:scope) { Rigor::Scope.empty.with_local(:h, Rigor::Type::HashShape.new) }

    it "widens the receiver of an IndexOrWriteNode, which is not a `[]=` CallNode" do
      node = parse_first("h = {}\nh[:a] ||= 1\n")
      expect(node).to be_a(Prism::IndexOrWriteNode)
      widened = described_class.widen(node: node, current_scope: scope).local(:h)
      expect(widened).to be_a(Rigor::Type::Nominal)
      expect(widened.class_name).to eq("Hash")
    end

    it "widens an IndexAndWriteNode receiver" do
      node = parse_first("h = {}\nh[:a] &&= 1\n")
      expect(node).to be_a(Prism::IndexAndWriteNode)
      expect(described_class.widen(node: node, current_scope: scope).local(:h))
        .to be_a(Rigor::Type::Nominal)
    end

    it "widens an IndexOperatorWriteNode receiver" do
      node = parse_first("h = {}\nh[:a] += 1\n")
      expect(node).to be_a(Prism::IndexOperatorWriteNode)
      expect(described_class.widen(node: node, current_scope: scope).local(:h))
        .to be_a(Rigor::Type::Nominal)
    end

    it "leaves an Array-typed local alone when the binding carries no literal shape" do
      nominal = Rigor::Type::Combinator.nominal_of("Hash")
      unshaped = Rigor::Scope.empty.with_local(:h, nominal)
      node = parse_first("h = {}\nh[:a] ||= 1\n")
      expect(described_class.widen(node: node, current_scope: unshaped).local(:h))
        .to eq(nominal)
    end

    it "declines when the write has no receiver variable to widen" do
      node = parse_first("foo[:a] ||= 1\n")
      expect(described_class.widen(node: node, current_scope: scope).local(:h))
        .to be_a(Rigor::Type::HashShape)
    end
  end
end
