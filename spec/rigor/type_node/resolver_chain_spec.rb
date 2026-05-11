# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::TypeNode::ResolverChain do
  def make_resolver(&block)
    Class.new(Rigor::Plugin::TypeNodeResolver) do
      define_method(:resolve) do |node, scope|
        block&.call(node, scope)
      end
    end.new
  end

  let(:node) { Rigor::TypeNode::Identifier.new(name: "Pick") }

  it "constructs from an Array of resolvers" do
    chain = described_class.new([make_resolver, make_resolver])
    expect(chain.resolvers.size).to eq(2)
    expect(chain).to be_frozen
  end

  it "rejects a non-Array argument" do
    expect do
      described_class.new(make_resolver)
    end.to raise_error(ArgumentError, /Array of resolvers/)
  end

  it "rejects entries that do not respond to #resolve" do
    expect do
      described_class.new([Object.new])
    end.to raise_error(ArgumentError, /responding to #resolve/)
  end

  it "returns the first non-nil resolve result and stops walking" do
    first  = make_resolver { |_node, _scope| nil }
    second = make_resolver { |_node, _scope| :second_won }
    third  = make_resolver { |_node, _scope| raise "must not be called" }

    chain = described_class.new([first, second, third])
    expect(chain.resolve(node, nil)).to eq(:second_won)
  end

  it "returns nil when every resolver declines" do
    a = make_resolver { |_node, _scope| nil }
    b = make_resolver { |_node, _scope| nil }
    chain = described_class.new([a, b])
    expect(chain.resolve(node, nil)).to be_nil
  end

  it "exposes EMPTY for the no-resolver case" do
    expect(described_class::EMPTY.resolve(node, nil)).to be_nil
    expect(described_class::EMPTY).to be_frozen
  end
end
