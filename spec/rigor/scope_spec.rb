# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rigor::Scope do
  let(:scope) { described_class.empty }

  describe ".empty" do
    it "uses the default environment" do
      expect(scope.environment).to equal(Rigor::Environment.default)
    end

    it "starts with no local bindings" do
      expect(scope.local(:x)).to be_nil
    end

    it "is frozen" do
      expect(scope).to be_frozen
    end
  end

  describe "#with_local" do
    it "returns a new scope with the binding added" do
      type = Rigor::Type::Combinator.constant_of(1)
      next_scope = scope.with_local(:x, type)
      expect(next_scope).not_to equal(scope)
      expect(next_scope.local(:x)).to equal(type)
    end

    it "leaves the receiver unchanged" do
      type = Rigor::Type::Combinator.constant_of(1)
      scope.with_local(:x, type)
      expect(scope.local(:x)).to be_nil
    end

    it "freezes the new scope" do
      next_scope = scope.with_local(:x, Rigor::Type::Combinator.constant_of(1))
      expect(next_scope).to be_frozen
    end
  end

  describe "structural equality" do
    it "is reflexive" do
      a = scope.with_local(:x, Rigor::Type::Combinator.constant_of(1))
      b = scope.with_local(:x, Rigor::Type::Combinator.constant_of(1))
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
    end

    it "differs when bindings differ" do
      a = scope.with_local(:x, Rigor::Type::Combinator.constant_of(1))
      b = scope.with_local(:x, Rigor::Type::Combinator.constant_of(2))
      expect(a).not_to eq(b)
    end
  end
end

RSpec.describe Rigor::Environment::ClassRegistry do
  let(:registry) { described_class.default }

  it "recognises slice 1 built-ins" do
    %w[Integer Float String Symbol NilClass TrueClass FalseClass Object BasicObject].each do |name|
      klass = Object.const_get(name)
      expect(registry.registered?(klass)).to be true
      expect(registry.nominal_for(klass).class_name).to eq(name)
    end
  end

  it "rejects classes it does not know" do
    expect(registry.registered?(Hash)).to be false
    expect { registry.nominal_for(Hash) }.to raise_error(KeyError)
  end
end
