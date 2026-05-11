# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::TypeNode::NameScope do
  let(:noop_resolver) { Rigor::Plugin::TypeNodeResolver.new }

  it "stores the resolver, class_context, and type_alias_table" do
    scope = described_class.new(
      resolver: noop_resolver,
      class_context: "Foo::Bar",
      type_alias_table: { "Alias" => :placeholder }
    )
    expect(scope.resolver).to eq(noop_resolver)
    expect(scope.class_context).to eq("Foo::Bar")
    expect(scope.type_alias_table).to eq("Alias" => :placeholder)
  end

  it "defaults class_context to nil and type_alias_table to an empty Hash" do
    scope = described_class.new(resolver: noop_resolver)
    expect(scope.class_context).to be_nil
    expect(scope.type_alias_table).to eq({})
  end

  it "freezes class_context and type_alias_table" do
    scope = described_class.new(
      resolver: noop_resolver,
      class_context: "Foo",
      type_alias_table: { "K" => :v }
    )
    expect(scope.class_context).to be_frozen
    expect(scope.type_alias_table).to be_frozen
  end

  it "accepts any object responding to #resolve as the resolver" do
    stub = Class.new { def resolve(_node, _scope) = nil }.new
    expect(described_class.new(resolver: stub).resolver).to eq(stub)
  end

  it "rejects a resolver that does not respond to #resolve" do
    expect do
      described_class.new(resolver: Object.new)
    end.to raise_error(ArgumentError, /must respond to #resolve/)
  end

  it "rejects a non-String class_context" do
    expect do
      described_class.new(resolver: noop_resolver, class_context: :Foo)
    end.to raise_error(ArgumentError, /class_context must be nil or a String/)
  end

  it "rejects a non-Hash type_alias_table" do
    expect do
      described_class.new(resolver: noop_resolver, type_alias_table: [])
    end.to raise_error(ArgumentError, /type_alias_table must be a Hash/)
  end
end
