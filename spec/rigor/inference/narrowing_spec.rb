# frozen_string_literal: true

require "spec_helper"
require "prism"
require "tmpdir"

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

  def with_rbs_hierarchy_env
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "hierarchy.rbs"), <<~RBS)
        module NarrowingFixture
          class Parent
          end

          class Child < Parent
          end
        end
      RBS
      yield Rigor::Environment.for_project(signature_paths: [dir])
    end
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

  describe ".narrow_equal and .narrow_not_equal" do
    it "narrows a finite String literal union to the compared literal" do
      literal_a = Rigor::Type::Combinator.constant_of("a")
      literal_b = Rigor::Type::Combinator.constant_of("b")
      union = Rigor::Type::Combinator.union(literal_a, literal_b)

      expect(described_class.narrow_equal(union, literal_a)).to eq(literal_a)
      expect(described_class.narrow_not_equal(union, literal_a)).to eq(literal_b)
    end

    it "does not manufacture a String literal from broad String" do
      literal = Rigor::Type::Combinator.constant_of("a")
      expect(described_class.narrow_equal(string_nominal, literal)).to eq(string_nominal)
      expect(described_class.narrow_not_equal(string_nominal, literal)).to eq(string_nominal)
    end

    it "extracts nil from a mixed domain without requiring a finite literal set" do
      union = Rigor::Type::Combinator.union(integer_nominal, constant_nil)
      expect(described_class.narrow_equal(union, constant_nil)).to eq(constant_nil)
      expect(described_class.narrow_not_equal(union, constant_nil)).to eq(integer_nominal)
    end

    it "refuses Float literal narrowing" do
      one = Rigor::Type::Combinator.constant_of(1.0)
      two = Rigor::Type::Combinator.constant_of(2.0)
      union = Rigor::Type::Combinator.union(one, two)
      expect(described_class.narrow_equal(union, one)).to eq(union)
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

    it "narrows equality against a literal inside a finite domain" do
      literal_a = Rigor::Type::Combinator.constant_of("a")
      literal_b = Rigor::Type::Combinator.constant_of("b")
      union = Rigor::Type::Combinator.union(literal_a, literal_b)
      bound = scope.with_local(:x, union)
      pred = parse_predicate('x == "a"')

      truthy, falsey = described_class.predicate_scopes(pred, bound)

      expect(truthy.local(:x)).to eq(literal_a)
      expect(falsey.local(:x)).to eq(literal_b)
      expect(truthy.local_facts(:x, bucket: :local_binding).first.payload).to eq(literal_a)
    end

    it "narrows inequality against a literal inside a finite domain" do
      literal_a = Rigor::Type::Combinator.constant_of("a")
      literal_b = Rigor::Type::Combinator.constant_of("b")
      union = Rigor::Type::Combinator.union(literal_a, literal_b)
      bound = scope.with_local(:x, union)
      pred = parse_predicate('x != "a"')

      truthy, falsey = described_class.predicate_scopes(pred, bound)

      expect(truthy.local(:x)).to eq(literal_b)
      expect(falsey.local(:x)).to eq(literal_a)
    end

    it "records a relational fact without narrowing Dynamic[Top]" do
      literal = Rigor::Type::Combinator.constant_of("a")
      bound = scope.with_local(:x, Rigor::Type::Combinator.untyped)
      pred = parse_predicate('x == "a"')

      truthy, falsey = described_class.predicate_scopes(pred, bound)

      expect(truthy.local(:x)).to eq(Rigor::Type::Combinator.untyped)
      expect(falsey.local(:x)).to eq(Rigor::Type::Combinator.untyped)
      expect(truthy.local_facts(:x, bucket: :relational).first.payload).to eq(literal)
    end

    it "narrows nil equality from a mixed domain" do
      bound = scope.with_local(:x, union_int_nil)
      pred = parse_predicate("x == nil")

      truthy, falsey = described_class.predicate_scopes(pred, bound)

      expect(truthy.local(:x)).to eq(constant_nil)
      expect(falsey.local(:x)).to eq(integer_nominal)
    end

    it "also recognises literal == local" do
      literal_a = Rigor::Type::Combinator.constant_of("a")
      literal_b = Rigor::Type::Combinator.constant_of("b")
      bound = scope.with_local(:x, Rigor::Type::Combinator.union(literal_a, literal_b))
      pred = parse_predicate('"a" == x')

      truthy, falsey = described_class.predicate_scopes(pred, bound)

      expect(truthy.local(:x)).to eq(literal_a)
      expect(falsey.local(:x)).to eq(literal_b)
    end
  end

  describe ".narrow_class (Slice 6 phase 2 sub-phase 1)" do
    let(:numeric_nominal) { Rigor::Type::Combinator.nominal_of("Numeric") }

    it "preserves Constant[v] when v.class is the asked class" do
      expect(described_class.narrow_class(integer_one, "Integer")).to eq(integer_one)
    end

    it "preserves Constant[v] when v.class is a subclass of the asked class" do
      # Integer < Numeric; `1.is_a?(Numeric)` is true.
      expect(described_class.narrow_class(integer_one, "Numeric")).to eq(integer_one)
    end

    it "rejects Constant[v] when v.class is unrelated to the asked class" do
      expect(described_class.narrow_class(integer_one, "String")).to eq(Rigor::Type::Combinator.bot)
    end

    it "preserves Nominal[C] when C matches the asked class" do
      expect(described_class.narrow_class(integer_nominal, "Integer")).to eq(integer_nominal)
    end

    it "preserves Nominal[Integer] under is_a?(Numeric)" do
      expect(described_class.narrow_class(integer_nominal, "Numeric")).to eq(integer_nominal)
    end

    it "narrows Nominal[Numeric] under is_a?(Integer) DOWN to Nominal[Integer]" do
      expect(described_class.narrow_class(numeric_nominal, "Integer")).to eq(integer_nominal)
    end

    it "rejects Nominal[String] under is_a?(Integer)" do
      expect(described_class.narrow_class(string_nominal, "Integer")).to eq(Rigor::Type::Combinator.bot)
    end

    it "narrows Union element-wise, dropping disjoint members" do
      union = Rigor::Type::Combinator.union(integer_nominal, string_nominal)
      result = described_class.narrow_class(union, "Integer")
      expect(result).to eq(integer_nominal)
    end

    it "narrows Top to Nominal[asked class]" do
      expect(described_class.narrow_class(Rigor::Type::Combinator.top, "Integer")).to eq(integer_nominal)
    end

    it "narrows Dynamic[Top] to Nominal[asked class]" do
      expect(described_class.narrow_class(Rigor::Type::Combinator.untyped, "Integer")).to eq(integer_nominal)
    end

    it "preserves Tuple under is_a?(Array)" do
      tuple = Rigor::Type::Combinator.tuple_of(integer_nominal)
      expect(described_class.narrow_class(tuple, "Array")).to eq(tuple)
    end

    it "rejects Tuple under is_a?(Hash)" do
      tuple = Rigor::Type::Combinator.tuple_of(integer_nominal)
      expect(described_class.narrow_class(tuple, "Hash")).to eq(Rigor::Type::Combinator.bot)
    end

    it "uses exact equality under instance_of?" do
      # `Integer.new(...).instance_of?(Numeric)` is FALSE in Ruby
      # (instance_of? is exact, not inclusive of subclasses).
      expect(described_class.narrow_class(integer_nominal, "Numeric", exact: true)).to eq(Rigor::Type::Combinator.bot)
    end

    it "preserves Nominal[C] under instance_of?(C) when names match exactly" do
      expect(described_class.narrow_class(integer_nominal, "Integer", exact: true)).to eq(integer_nominal)
    end

    it "leaves the type unchanged when the asked class is unknown to the host Ruby" do
      # `Foo::Bar` is not defined in the test environment, so the
      # ordering check returns `:unknown` and we stay conservative.
      expect(described_class.narrow_class(integer_nominal, "Foo::Bar")).to eq(integer_nominal)
    end

    it "uses the analyzer environment for RBS-only hierarchy lookups" do
      with_rbs_hierarchy_env do |env|
        child = Rigor::Type::Combinator.nominal_of("NarrowingFixture::Child")
        parent = Rigor::Type::Combinator.nominal_of("NarrowingFixture::Parent")

        expect(described_class.narrow_class(child, "NarrowingFixture::Parent", environment: env)).to eq(child)
        expect(described_class.narrow_class(parent, "NarrowingFixture::Child", environment: env)).to eq(
          Rigor::Type::Combinator.nominal_of("NarrowingFixture::Child")
        )
      end
    end
  end

  describe ".narrow_not_class (Slice 6 phase 2 sub-phase 1)" do
    it "rejects Constant whose class is the asked class (or its subclass)" do
      expect(described_class.narrow_not_class(integer_one, "Integer")).to eq(Rigor::Type::Combinator.bot)
      expect(described_class.narrow_not_class(integer_one, "Numeric")).to eq(Rigor::Type::Combinator.bot)
    end

    it "preserves Constant whose class is unrelated to the asked class" do
      expect(described_class.narrow_not_class(integer_one, "String")).to eq(integer_one)
    end

    it "rejects Nominal that already matches the asked class" do
      expect(described_class.narrow_not_class(integer_nominal, "Integer")).to eq(Rigor::Type::Combinator.bot)
    end

    it "preserves Nominal[Numeric] under !is_a?(Integer)" do
      # The narrower cannot prove a Numeric is NOT an Integer, so it
      # stays conservative and preserves the type.
      numeric = Rigor::Type::Combinator.nominal_of("Numeric")
      expect(described_class.narrow_not_class(numeric, "Integer")).to eq(numeric)
    end

    it "removes only the matching union member" do
      union = Rigor::Type::Combinator.union(integer_nominal, string_nominal)
      result = described_class.narrow_not_class(union, "Integer")
      expect(result).to eq(string_nominal)
    end

    it "preserves Constant under instance_of? when v.class is a subclass of the asked class but not equal" do
      # `1.instance_of?(Numeric)` is FALSE, so the falsey edge KEEPS
      # Constant[1] (it does not satisfy the predicate, so it
      # belongs to the not-class fragment).
      expect(described_class.narrow_not_class(integer_one, "Numeric", exact: true)).to eq(integer_one)
    end
  end

  describe "class-membership predicate narrowing through predicate_scopes" do
    let(:union_int_str) { Rigor::Type::Combinator.union(integer_nominal, string_nominal) }

    it "narrows x.is_a?(Integer) on a Union[Integer, String]" do
      bound = scope.with_local(:x, union_int_str)
      pred = parse_predicate("x.is_a?(Integer)")
      truthy, falsey = described_class.predicate_scopes(pred, bound)
      expect(truthy.local(:x)).to eq(integer_nominal)
      expect(falsey.local(:x)).to eq(string_nominal)
    end

    it "treats kind_of? identically to is_a?" do
      bound = scope.with_local(:x, union_int_str)
      pred = parse_predicate("x.kind_of?(String)")
      truthy, falsey = described_class.predicate_scopes(pred, bound)
      expect(truthy.local(:x)).to eq(string_nominal)
      expect(falsey.local(:x)).to eq(integer_nominal)
    end

    it "uses exact matching for instance_of?" do
      numeric = Rigor::Type::Combinator.nominal_of("Numeric")
      bound = scope.with_local(:x, numeric)
      # `Numeric#instance_of?(Numeric)` could be true (a literal
      # Numeric instance) but `instance_of?(Integer)` requires the
      # class to be exactly Integer. Under exact matching the
      # truthy edge therefore collapses (we cannot prove it is
      # Integer-exact from a Nominal[Numeric] alone).
      pred = parse_predicate("x.instance_of?(Integer)")
      truthy, falsey = described_class.predicate_scopes(pred, bound)
      expect(truthy.local(:x)).to eq(Rigor::Type::Combinator.bot)
      expect(falsey.local(:x)).to eq(numeric)
    end

    it "narrows nested constants like x.is_a?(::String)" do
      bound = scope.with_local(:x, union_int_str)
      pred = parse_predicate("x.is_a?(::String)")
      truthy, _falsey = described_class.predicate_scopes(pred, bound)
      expect(truthy.local(:x)).to eq(string_nominal)
    end

    it "falls through when the receiver is not a local" do
      pred = parse_predicate("foo.is_a?(Integer)")
      truthy, falsey = described_class.predicate_scopes(pred, scope)
      expect(truthy).to eq(scope)
      expect(falsey).to eq(scope)
    end

    it "falls through when the argument is not a static constant" do
      bound = scope.with_local(:x, union_int_str)
      bound = bound.with_local(:y, integer_nominal)
      pred = parse_predicate("x.is_a?(y)")
      truthy, falsey = described_class.predicate_scopes(pred, bound)
      expect(truthy.local(:x)).to eq(union_int_str)
      expect(falsey.local(:x)).to eq(union_int_str)
    end

    it "composes with the unary `!` inverter" do
      bound = scope.with_local(:x, union_int_str)
      pred = parse_predicate("!x.is_a?(Integer)")
      truthy, falsey = described_class.predicate_scopes(pred, bound)
      # `!x.is_a?(Integer)` is true exactly when x is not an Integer,
      # so the truthy edge is the falsey edge of `x.is_a?(Integer)`.
      expect(truthy.local(:x)).to eq(string_nominal)
      expect(falsey.local(:x)).to eq(integer_nominal)
    end

    describe "case-equality (===) narrowing (Slice 7 phase 4)" do
      it "Class === local narrows like is_a?" do
        bound = scope.with_local(:x, union_int_str)
        pred = parse_predicate("Integer === x")
        truthy, falsey = described_class.predicate_scopes(pred, bound)
        expect(truthy.local(:x)).to eq(integer_nominal)
        expect(falsey.local(:x)).to eq(string_nominal)
      end

      it "Regexp literal === local narrows the truthy edge to String" do
        bound = scope.with_local(:x, union_int_str)
        pred = parse_predicate("/foo/ === x")
        truthy, falsey = described_class.predicate_scopes(pred, bound)
        expect(truthy.local(:x)).to eq(string_nominal)
        # Falsey edge keeps the entry type — Regexp#=== returns
        # false for non-Strings AND non-matching Strings.
        expect(falsey.local(:x)).to eq(union_int_str)
      end

      it "Integer-endpoint Range literal === local narrows to Numeric on the truthy edge" do
        bound = scope.with_local(:x, union_int_str)
        pred = parse_predicate("(1..10) === x")
        truthy, _falsey = described_class.predicate_scopes(pred, bound)
        # x must be Numeric on the truthy edge; the Integer member
        # of the union survives, String is dropped.
        expect(truthy.local(:x)).to eq(integer_nominal)
      end

      it "falls through (no narrowing) when the LHS argument is not a local read" do
        pred = parse_predicate("Integer === foo")
        truthy, falsey = described_class.predicate_scopes(pred, scope)
        expect(truthy).to eq(scope)
        expect(falsey).to eq(scope)
      end
    end
  end

  describe ".narrow_integer_comparison (Slice 6 phase D — range narrowing)" do
    def positive_int = Rigor::Type::Combinator.positive_int
    def non_negative_int = Rigor::Type::Combinator.non_negative_int
    def negative_int = Rigor::Type::Combinator.negative_int
    def non_positive_int = Rigor::Type::Combinator.non_positive_int

    describe "Nominal[Integer] receivers" do
      it "narrows `x > 0` to positive_int" do
        expect(described_class.narrow_integer_comparison(integer_nominal, :>, 0)).to eq(positive_int)
      end

      it "narrows `x >= 0` to non_negative_int" do
        expect(described_class.narrow_integer_comparison(integer_nominal, :>=, 0)).to eq(non_negative_int)
      end

      it "narrows `x < 0` to negative_int" do
        expect(described_class.narrow_integer_comparison(integer_nominal, :<, 0)).to eq(negative_int)
      end

      it "narrows `x <= 0` to non_positive_int" do
        expect(described_class.narrow_integer_comparison(integer_nominal, :<=, 0)).to eq(non_positive_int)
      end
    end

    describe "IntegerRange receivers" do
      it "intersects with the comparison half-line" do
        range = Rigor::Type::Combinator.integer_range(-5, 5)
        expect(described_class.narrow_integer_comparison(range, :>, 0))
          .to eq(Rigor::Type::Combinator.integer_range(1, 5))
      end

      it "is a no-op when the range is already on the satisfying side" do
        range = Rigor::Type::Combinator.integer_range(1, 10)
        expect(described_class.narrow_integer_comparison(range, :>, 0)).to eq(range)
      end

      it "collapses to Bot when the intersection is empty" do
        range = Rigor::Type::Combinator.integer_range(-10, -1)
        expect(described_class.narrow_integer_comparison(range, :>, 0))
          .to be_a(Rigor::Type::Bot)
      end

      it "collapses a single-point intersection to Constant" do
        # int<-1, 1> & (>= 1) = int<1, 1> -> Constant[1]
        range = Rigor::Type::Combinator.integer_range(-1, 1)
        expect(described_class.narrow_integer_comparison(range, :>=, 1))
          .to eq(Rigor::Type::Combinator.constant_of(1))
      end
    end

    describe "Constant receivers" do
      it "preserves a Constant that satisfies the comparison" do
        c = Rigor::Type::Combinator.constant_of(5)
        expect(described_class.narrow_integer_comparison(c, :>, 0)).to eq(c)
      end

      it "drops a Constant that does not satisfy the comparison" do
        c = Rigor::Type::Combinator.constant_of(-3)
        expect(described_class.narrow_integer_comparison(c, :>, 0))
          .to be_a(Rigor::Type::Bot)
      end

      it "leaves non-Integer Constants untouched (Bot rather than widen)" do
        # `Constant["foo"]` cannot satisfy `> 0`; collapses to Bot
        # rather than the analyser silently leaving a non-numeric
        # value on the truthy edge of an integer comparison.
        c = Rigor::Type::Combinator.constant_of("foo")
        expect(described_class.narrow_integer_comparison(c, :>, 0))
          .to be_a(Rigor::Type::Bot)
      end
    end

    describe "Union receivers" do
      it "narrows each member independently" do
        union = Rigor::Type::Combinator.union(
          Rigor::Type::Combinator.constant_of(-3),
          Rigor::Type::Combinator.constant_of(0),
          Rigor::Type::Combinator.constant_of(5)
        )
        result = described_class.narrow_integer_comparison(union, :>, 0)
        expect(result).to eq(Rigor::Type::Combinator.constant_of(5))
      end
    end

    describe "non-numeric receivers" do
      it "leaves Nominal[String] untouched" do
        expect(described_class.narrow_integer_comparison(string_nominal, :>, 0))
          .to eq(string_nominal)
      end
    end
  end

  describe "comparison predicate narrowing through predicate_scopes" do
    let(:integer_nominal_scope) { scope.with_local(:x, integer_nominal) }

    it "narrows `if x > 0` to positive_int / non_positive_int on each edge" do
      truthy, falsey = described_class.predicate_scopes(parse_predicate("x > 0"), integer_nominal_scope)
      expect(truthy.local(:x)).to eq(Rigor::Type::Combinator.positive_int)
      expect(falsey.local(:x)).to eq(Rigor::Type::Combinator.non_positive_int)
    end

    it "narrows `if x >= 0` to non_negative_int / negative_int" do
      truthy, falsey = described_class.predicate_scopes(parse_predicate("x >= 0"), integer_nominal_scope)
      expect(truthy.local(:x)).to eq(Rigor::Type::Combinator.non_negative_int)
      expect(falsey.local(:x)).to eq(Rigor::Type::Combinator.negative_int)
    end

    it "narrows the reversed form `0 < x` (literal-on-left)" do
      truthy, falsey = described_class.predicate_scopes(parse_predicate("0 < x"), integer_nominal_scope)
      expect(truthy.local(:x)).to eq(Rigor::Type::Combinator.positive_int)
      expect(falsey.local(:x)).to eq(Rigor::Type::Combinator.non_positive_int)
    end

    it "intersects with an existing IntegerRange bound" do
      bound = scope.with_local(:x, Rigor::Type::Combinator.integer_range(-10, 10))
      truthy, _falsey = described_class.predicate_scopes(parse_predicate("x > 5"), bound)
      expect(truthy.local(:x)).to eq(Rigor::Type::Combinator.integer_range(6, 10))
    end

    it "passes through unchanged when the local has no current type" do
      empty = scope
      truthy, falsey = described_class.predicate_scopes(parse_predicate("x > 0"), empty)
      expect(truthy).to eq(empty)
      expect(falsey).to eq(empty)
    end

    it "passes through unchanged when the bound is non-Integer" do
      truthy, falsey = described_class.predicate_scopes(parse_predicate("x > 'a'"), integer_nominal_scope)
      expect(truthy.local(:x)).to eq(integer_nominal)
      expect(falsey.local(:x)).to eq(integer_nominal)
    end
  end

  describe ".case_when_scopes (Slice 7 phase 5)" do
    let(:union_int_str) do
      Rigor::Type::Combinator.union(
        Rigor::Type::Combinator.nominal_of("Integer"),
        Rigor::Type::Combinator.nominal_of("String")
      )
    end

    let(:integer_nominal) { Rigor::Type::Combinator.nominal_of("Integer") }
    let(:string_nominal) { Rigor::Type::Combinator.nominal_of("String") }

    # Parses a `case` statement with `x` declared as a local
    # (via the existing `parse_program(locals:)` helper) so
    # Prism resolves the bare `x` subject as a
    # `LocalVariableReadNode` rather than the variable-call
    # `CallNode` that an unbound bare read parses to.
    def parse_case_of_x(case_source)
      parse_program(case_source).statements.body.first
    end

    it "narrows the body scope to the when-clause class" do
      bound = scope.with_local(:x, union_int_str)
      case_node = parse_case_of_x(<<~RUBY)
        case x
        when Integer then x
        when String then x
        end
      RUBY
      first_when = case_node.conditions.first
      body, _falsey = described_class.case_when_scopes(case_node.predicate, first_when.conditions, bound)
      expect(body.local(:x)).to eq(integer_nominal)
    end

    it "subtracts every prior matched class from the falsey edge so subsequent branches see the narrowed type" do
      bound = scope.with_local(:x, union_int_str)
      case_node = parse_case_of_x(<<~RUBY)
        case x
        when Integer then x
        when String then x
        end
      RUBY
      first_when = case_node.conditions.first
      _body, falsey = described_class.case_when_scopes(case_node.predicate, first_when.conditions, bound)
      expect(falsey.local(:x)).to eq(string_nominal)
    end

    it "unions multiple matchers in a single when clause on the truthy edge" do
      union_int_str_nil = Rigor::Type::Combinator.union(
        union_int_str,
        Rigor::Type::Combinator.nominal_of("NilClass")
      )
      bound = scope.with_local(:x, union_int_str_nil)
      case_node = parse_case_of_x(<<~RUBY)
        case x
        when Integer, String then x
        end
      RUBY
      first_when = case_node.conditions.first
      body, _falsey = described_class.case_when_scopes(case_node.predicate, first_when.conditions, bound)
      expect(body.local(:x)).to eq(union_int_str)
    end

    it "falls through with no narrowing when the subject is not a local read" do
      bound = scope.with_local(:x, union_int_str)
      case_node = parse_case_of_x(<<~RUBY)
        case x.length
        when 1 then 1
        end
      RUBY
      first_when = case_node.conditions.first
      body, falsey = described_class.case_when_scopes(case_node.predicate, first_when.conditions, bound)
      expect(body).to eq(bound)
      expect(falsey).to eq(bound)
    end
  end
end
