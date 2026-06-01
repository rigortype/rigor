# frozen_string_literal: true

require "spec_helper"
require "rigor/source/literals"

RSpec.describe Rigor::Source::Literals do
  def call(source)
    Prism.parse(source).value.statements.body.first
  end

  describe ".symbol_or_string" do
    it "returns the Symbol named by a literal SymbolNode" do
      node = call("foo(:bar)").arguments.arguments.first
      expect(described_class.symbol_or_string(node)).to eq(:bar)
    end

    it "returns the Symbol named by a literal StringNode" do
      node = call('foo("bar")').arguments.arguments.first
      expect(described_class.symbol_or_string(node)).to eq(:bar)
    end

    it "returns nil for a non-literal node" do
      node = call("foo(bar)").arguments.arguments.first
      expect(described_class.symbol_or_string(node)).to be_nil
    end

    it "returns nil for nil" do
      expect(described_class.symbol_or_string(nil)).to be_nil
    end
  end

  describe ".symbol_arguments" do
    it "collects every literal Symbol/String argument in order" do
      node = call('foo(:a, "b", bar, :c)')
      expect(described_class.symbol_arguments(node)).to eq(%i[a b c])
    end

    it "returns [] when the call has no arguments" do
      expect(described_class.symbol_arguments(call("foo"))).to eq([])
    end

    it "returns [] for nil" do
      expect(described_class.symbol_arguments(nil)).to eq([])
    end
  end

  describe ".symbol_arg" do
    it "returns the literal at the given positional index" do
      node = call("foo(:a, :b)")
      expect(described_class.symbol_arg(node, 1)).to eq(:b)
    end

    it "returns nil when the index is out of range" do
      expect(described_class.symbol_arg(call("foo(:a)"), 5)).to be_nil
    end

    it "returns nil when the argument at the index is not a literal" do
      expect(described_class.symbol_arg(call("foo(bar)"), 0)).to be_nil
    end

    it "returns nil when the call has no arguments" do
      expect(described_class.symbol_arg(call("foo"), 0)).to be_nil
    end

    it "returns nil for nil" do
      expect(described_class.symbol_arg(nil, 0)).to be_nil
    end
  end
end
