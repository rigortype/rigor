# frozen_string_literal: true

require "spec_helper"
require "prism"

RSpec.describe Rigor::Inference::Narrowing do
  let(:scope) { Rigor::Scope.empty }

  def integer_one
    Rigor::Type::Combinator.constant_of(1)
  end

  def constant_nil
    Rigor::Type::Combinator.constant_of(nil)
  end

  def constant_false
    Rigor::Type::Combinator.constant_of(false)
  end

  def integer_nominal
    Rigor::Type::Combinator.nominal_of("Integer")
  end

  def string_nominal
    Rigor::Type::Combinator.nominal_of("String")
  end

  def nilclass_nominal
    Rigor::Type::Combinator.nominal_of("NilClass")
  end

  def parse_program(source, locals: %i[x y])
    Prism.parse(source, scopes: [locals]).value
  end

  def parse_predicate(source, locals: %i[x y])
    program = parse_program(source, locals: locals)
    program.statements.body.first
  end

  describe ".narrow_truthy" do
    it "rejects Constant[nil]" do
      expect(described_class.narrow_truthy(constant_nil)).to eq(Rigor::Type::Combinator.bot)
    end

    it "rejects Constant[false]" do
      expect(described_class.narrow_truthy(constant_false)).to eq(Rigor::Type::Combinator.bot)
    end

    it "preserves truthy Constant values" do
      expect(described_class.narrow_truthy(integer_one)).to eq(integer_one)
    end

    it "preserves a non-falsey Nominal" do
      expect(described_class.narrow_truthy(integer_nominal)).to eq(integer_nominal)
    end

    it "rejects Nominal[NilClass]" do
      expect(described_class.narrow_truthy(nilclass_nominal)).to eq(Rigor::Type::Combinator.bot)
    end

    it "drops the falsey members of a union" do
      union = Rigor::Type::Combinator.union(integer_nominal, constant_nil, constant_false)
      expect(described_class.narrow_truthy(union)).to eq(integer_nominal)
    end

    it "preserves Singleton, Tuple, and HashShape (always truthy)" do
      singleton = Rigor::Type::Combinator.singleton_of("Integer")
      tuple = Rigor::Type::Combinator.tuple_of(integer_one)
      shape = Rigor::Type::Combinator.hash_shape_of(a: integer_one)

      expect(described_class.narrow_truthy(singleton)).to eq(singleton)
      expect(described_class.narrow_truthy(tuple)).to eq(tuple)
      expect(described_class.narrow_truthy(shape)).to eq(shape)
    end

    it "leaves Dynamic and Top conservative" do
      dynamic = Rigor::Type::Combinator.untyped
      top = Rigor::Type::Combinator.top
      expect(described_class.narrow_truthy(dynamic)).to eq(dynamic)
      expect(described_class.narrow_truthy(top)).to eq(top)
    end
  end

  describe ".narrow_falsey" do
    it "rejects truthy Constant values" do
      expect(described_class.narrow_falsey(integer_one)).to eq(Rigor::Type::Combinator.bot)
    end

    it "preserves Constant[nil]" do
      expect(described_class.narrow_falsey(constant_nil)).to eq(constant_nil)
    end

    it "rejects Singleton, Tuple, and HashShape" do
      singleton = Rigor::Type::Combinator.singleton_of("Integer")
      tuple = Rigor::Type::Combinator.tuple_of(integer_one)
      shape = Rigor::Type::Combinator.hash_shape_of(a: integer_one)

      expect(described_class.narrow_falsey(singleton)).to eq(Rigor::Type::Combinator.bot)
      expect(described_class.narrow_falsey(tuple)).to eq(Rigor::Type::Combinator.bot)
      expect(described_class.narrow_falsey(shape)).to eq(Rigor::Type::Combinator.bot)
    end

    it "narrows a union to its falsey members" do
      union = Rigor::Type::Combinator.union(integer_nominal, constant_nil, string_nominal)
      expect(described_class.narrow_falsey(union)).to eq(constant_nil)
    end

    it "leaves Dynamic and Top conservative" do
      dynamic = Rigor::Type::Combinator.untyped
      top = Rigor::Type::Combinator.top
      expect(described_class.narrow_falsey(dynamic)).to eq(dynamic)
      expect(described_class.narrow_falsey(top)).to eq(top)
    end
  end

  describe ".narrow_nil" do
    it "narrows Dynamic to Constant[nil]" do
      expect(described_class.narrow_nil(Rigor::Type::Combinator.untyped)).to eq(constant_nil)
    end

    it "preserves Constant[nil]" do
      expect(described_class.narrow_nil(constant_nil)).to eq(constant_nil)
    end

    it "rejects non-nil Nominal" do
      expect(described_class.narrow_nil(integer_nominal)).to eq(Rigor::Type::Combinator.bot)
    end

    it "extracts the nil member from a union" do
      union = Rigor::Type::Combinator.union(integer_nominal, constant_nil)
      expect(described_class.narrow_nil(union)).to eq(constant_nil)
    end
  end

  describe ".narrow_non_nil" do
    it "drops nil members from a union" do
      union = Rigor::Type::Combinator.union(integer_nominal, constant_nil)
      expect(described_class.narrow_non_nil(union)).to eq(integer_nominal)
    end

    it "rejects Constant[nil]" do
      expect(described_class.narrow_non_nil(constant_nil)).to eq(Rigor::Type::Combinator.bot)
    end

    it "preserves Dynamic" do
      dynamic = Rigor::Type::Combinator.untyped
      expect(described_class.narrow_non_nil(dynamic)).to eq(dynamic)
    end
  end

  describe ".predicate_scopes" do
    let(:union_int_nil) { Rigor::Type::Combinator.union(integer_nominal, constant_nil) }

    it "returns the entry scope twice when the predicate has no rule" do
      pred = parse_predicate("foo()")
      truthy, falsey = described_class.predicate_scopes(pred, scope)
      expect(truthy).to eq(scope)
      expect(falsey).to eq(scope)
    end

    it "returns the entry scope twice when the predicate is nil" do
      truthy, falsey = described_class.predicate_scopes(nil, scope)
      expect(truthy).to eq(scope)
      expect(falsey).to eq(scope)
    end

    it "narrows a local-variable read on truthiness" do
      bound = scope.with_local(:x, union_int_nil)
      pred = parse_predicate("x")
      truthy, falsey = described_class.predicate_scopes(pred, bound)
      expect(truthy.local(:x)).to eq(integer_nominal)
      expect(falsey.local(:x)).to eq(constant_nil)
    end

    it "narrows on x.nil?" do
      bound = scope.with_local(:x, union_int_nil)
      pred = parse_predicate("x.nil?")
      truthy, falsey = described_class.predicate_scopes(pred, bound)
      expect(truthy.local(:x)).to eq(constant_nil)
      expect(falsey.local(:x)).to eq(integer_nominal)
    end

    it "swaps truthy/falsey for !x" do
      bound = scope.with_local(:x, union_int_nil)
      pred = parse_predicate("!x")
      truthy, falsey = described_class.predicate_scopes(pred, bound)
      expect(truthy.local(:x)).to eq(constant_nil)
      expect(falsey.local(:x)).to eq(integer_nominal)
    end

    it "passes through parenthesised predicates" do
      bound = scope.with_local(:x, union_int_nil)
      pred = parse_predicate("(x)")
      truthy, falsey = described_class.predicate_scopes(pred, bound)
      expect(truthy.local(:x)).to eq(integer_nominal)
      expect(falsey.local(:x)).to eq(constant_nil)
    end

    it "narrows two locals through a && b" do
      union_str_nil = Rigor::Type::Combinator.union(string_nominal, constant_nil)
      bound = scope
              .with_local(:x, union_int_nil)
              .with_local(:y, union_str_nil)
      pred = parse_predicate("x && y")
      truthy, falsey = described_class.predicate_scopes(pred, bound)
      expect(truthy.local(:x)).to eq(integer_nominal)
      expect(truthy.local(:y)).to eq(string_nominal)
      # Falsey edge unions the LHS-falsey scope (y untouched) with
      # the LHS-truthy/RHS-falsey scope (x narrowed, y narrowed).
      expect(falsey.local(:x)).to eq(union_int_nil)
      expect(falsey.local(:y)).to eq(union_str_nil)
    end

    it "narrows two locals through a || b" do
      union_str_nil = Rigor::Type::Combinator.union(string_nominal, constant_nil)
      bound = scope
              .with_local(:x, union_int_nil)
              .with_local(:y, union_str_nil)
      pred = parse_predicate("x || y")
      truthy, falsey = described_class.predicate_scopes(pred, bound)
      # Truthy edge unions LHS-truthy (x narrowed, y untouched) with
      # LHS-falsey/RHS-truthy (x = nil, y narrowed).
      expect(truthy.local(:x)).to eq(union_int_nil)
      expect(truthy.local(:y)).to eq(union_str_nil)
      # Falsey edge: both are nil.
      expect(falsey.local(:x)).to eq(constant_nil)
      expect(falsey.local(:y)).to eq(constant_nil)
    end

    it "narrows nested predicates: !(x.nil?)" do
      bound = scope.with_local(:x, union_int_nil)
      pred = parse_predicate("!(x.nil?)")
      truthy, falsey = described_class.predicate_scopes(pred, bound)
      expect(truthy.local(:x)).to eq(integer_nominal)
      expect(falsey.local(:x)).to eq(constant_nil)
    end

    it "leaves locals unchanged when no rule applies" do
      bound = scope.with_local(:x, union_int_nil)
      pred = parse_predicate("foo(x)")
      truthy, falsey = described_class.predicate_scopes(pred, bound)
      expect(truthy.local(:x)).to eq(union_int_nil)
      expect(falsey.local(:x)).to eq(union_int_nil)
    end

    it "leaves the scope unchanged when the local is unbound" do
      pred = parse_predicate("y")
      truthy, falsey = described_class.predicate_scopes(pred, scope)
      expect(truthy).to eq(scope)
      expect(falsey).to eq(scope)
    end
  end
end
