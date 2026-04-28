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

  describe "#join" do
    let(:integer_one) { Rigor::Type::Combinator.constant_of(1) }
    let(:integer_two) { Rigor::Type::Combinator.constant_of(2) }
    let(:string_a) { Rigor::Type::Combinator.constant_of("a") }

    it "returns an empty scope when joining two empty scopes" do
      joined = scope.join(scope)

      expect(joined.locals).to eq({})
    end

    it "preserves a local that is bound to the same type in both branches" do
      a = scope.with_local(:x, integer_one)
      b = scope.with_local(:x, integer_one)

      joined = a.join(b)

      expect(joined.local(:x)).to eq(integer_one)
    end

    it "unions the types of locals bound in both branches" do
      a = scope.with_local(:x, integer_one)
      b = scope.with_local(:x, integer_two)

      joined = a.join(b)
      expected = Rigor::Type::Combinator.union(integer_one, integer_two)

      expect(joined.local(:x)).to eq(expected)
    end

    it "drops locals that are bound in only one branch" do
      a = scope.with_local(:x, integer_one)
      b = scope.with_local(:y, string_a)

      joined = a.join(b)

      expect(joined.local(:x)).to be_nil
      expect(joined.local(:y)).to be_nil
      expect(joined.locals).to eq({})
    end

    it "is symmetric" do
      a = scope.with_local(:x, integer_one)
      b = scope.with_local(:x, integer_two)

      expect(a.join(b)).to eq(b.join(a))
    end

    it "returns a new scope (immutability)" do
      a = scope.with_local(:x, integer_one)
      b = scope.with_local(:x, integer_two)

      joined = a.join(b)

      expect(joined).not_to equal(a)
      expect(joined).not_to equal(b)
      expect(a.local(:x)).to eq(integer_one)
      expect(b.local(:x)).to eq(integer_two)
    end

    it "raises ArgumentError when the other argument is not a Scope" do
      expect { scope.join(:nope) }.to raise_error(ArgumentError, /requires a Rigor::Scope/)
    end

    it "raises ArgumentError when the environments differ" do
      other_environment = Rigor::Environment.new
      other = described_class.empty(environment: other_environment)

      expect { scope.join(other) }.to raise_error(ArgumentError, /same Environment/)
    end
  end
end
