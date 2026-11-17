# frozen_string_literal: true

require "spec_helper"
require "prism"

# ADR-116 C4 — {Rigor::Inference::Narrowing::PresencePredicates} on a parsed predicate and an empty `Scope` that binds
# the receiver: no runner, no environment beyond `Scope.empty`'s. `narrowing_spec.rb` and the `key_presence_*` specs
# pin the same predicates through `Narrowing.predicate_scopes`; these examples call the entries directly, so editing
# `presence_predicates.rb` selects this spec by the mirror rule.
#
# Mutation-proved: each guard line (a `return` modifier) of `presence_predicates.rb` was blanked in turn and an example
# here failed, except four that no input distinguishes:
#
# - `analyse_array_emptiness_predicate`'s `return nil if current.nil?` and `key_presence_scopes`'s: an unbound receiver
#   reads `nil`, which `narrow_to_non_empty_array` / `narrow_hash_key_present` return unchanged, so the next guard
#   (`equal?(current)`) declines it. Tried: an unbound local and an unbound instance variable.
# - `promote_hash_key`'s and `remove_hash_key`'s `return shape unless shape.pairs.key?(key)`: `HashShape` refuses an
#   optional key that is not in `pairs` (`ArgumentError`), so the `optional_key?` guard after it answers the same.
#   Tried: a closed and an open shape with an undeclared key (`:zz`), and a `Symbol` key against a String-keyed shape.
#
# The two `scope` arms of `key_presence_scopes`' `truthy.equal?(current) ? scope : ...` choices are not reached:
# `narrow_hash_key_present` and `narrow_hash_key_absent` change a shape under the same condition (the key is a declared
# optional key), so one edge unchanged means both are, and the `equal?` guard above has declined. Tried: a required key,
# an undeclared key, a union holding one shape, and a union holding none.
RSpec.describe Rigor::Inference::Narrowing::PresencePredicates do
  let(:combinator) { Rigor::Type::Combinator }
  let(:scope) { Rigor::Scope.empty }

  def call_node(source, locals: %i[a h k])
    Prism.parse(source, scopes: [locals]).value.statements.body.first
  end

  def integer_array = combinator.nominal_of("Array", type_args: [combinator.nominal_of("Integer")])
  def non_empty_integer_array = combinator.non_empty_array(combinator.nominal_of("Integer"))

  def shape(pairs = { a: combinator.nominal_of("Integer"), b: combinator.nominal_of("String") }, **)
    combinator.hash_shape_of(pairs, **)
  end

  def short(type) = type.describe(:short)

  # `[truthy local type, falsey local type]` of an analysed pair, as strings.
  def local_edges(pair, name = :a) = pair.map { |edge| short(edge.local(name)) }

  describe ".analyse_array_emptiness_predicate" do
    def emptiness(source, bound, name, **)
      described_class.analyse_array_emptiness_predicate(call_node(source, **), bound, name)
    end

    let(:bound) { scope.with_local(:a, integer_array) }

    it "narrows the falsey edge of `empty?` to a non-empty array" do
      expect(local_edges(emptiness("a.empty?", bound, :empty?))).to eq(["Array[Integer]", "non-empty-array[Integer]"])
    end

    it "narrows the truthy edge of `any?` to a non-empty array" do
      expect(local_edges(emptiness("a.any?", bound, :any?))).to eq(["non-empty-array[Integer]", "Array[Integer]"])
    end

    it "narrows the falsey edge of `none?` to a non-empty array" do
      expect(local_edges(emptiness("a.none?", bound, :none?))).to eq(["Array[Integer]", "non-empty-array[Integer]"])
    end

    it "declines a call with a block, a block argument or an argument" do
      expect(emptiness("a.any? { |x| x }", bound, :any?)).to be_nil
      expect(emptiness("a.any?(&:odd?)", bound, :any?)).to be_nil
      expect(emptiness("a.any?(1)", bound, :any?)).to be_nil
    end

    it "narrows an instance-variable receiver" do
      pair = emptiness("@a.empty?", scope.with_ivar(:@a, integer_array), :empty?)

      expect(pair.map { |edge| short(edge.ivar(:@a)) }).to eq(["Array[Integer]", "non-empty-array[Integer]"])
    end

    it "declines a receiver that is neither a local nor an instance variable" do
      expect(emptiness("a.b.empty?", bound, :empty?)).to be_nil
      expect(emptiness("A.empty?", bound, :empty?)).to be_nil
      expect(emptiness("empty?", bound, :empty?, locals: [])).to be_nil
    end

    it "declines a local or instance variable the scope does not bind" do
      expect(emptiness("a.empty?", scope, :empty?)).to be_nil
      expect(emptiness("@a.empty?", scope, :empty?)).to be_nil
    end

    it "declines a receiver that is not an Array" do
      %w[String Hash Integer].each do |name|
        expect(emptiness("a.empty?", scope.with_local(:a, combinator.nominal_of(name)), :empty?)).to be_nil
      end
    end

    it "declines a Dynamic receiver and a Tuple, which is already known-length" do
      expect(emptiness("a.empty?", scope.with_local(:a, combinator.untyped), :empty?)).to be_nil
      expect(emptiness("a.empty?", scope.with_local(:a, combinator.tuple_of(combinator.nominal_of("Integer"))),
                       :empty?))
        .to be_nil
    end

    it "narrows the Array member of a union and keeps the others" do
      union = combinator.union(integer_array, combinator.constant_of(nil))

      expect(local_edges(emptiness("a.empty?", scope.with_local(:a, union), :empty?)))
        .to eq(["Array[Integer]?", "non-empty-array[Integer]?"])
    end

    it "gives a bare Array an element type of top" do
      pair = emptiness("a.empty?", scope.with_local(:a, combinator.nominal_of("Array")), :empty?)

      expect(local_edges(pair)).to eq(["Array", "non-empty-array[top]"])
    end

    it "declines an array that is already non-empty, which the narrowing cannot tell apart from a non-array" do
      expect(emptiness("a.any?", scope.with_local(:a, non_empty_integer_array), :any?)).to be_nil
    end
  end

  describe ".analyse_key_presence_predicate" do
    def presence(source, bound, **)
      described_class.analyse_key_presence_predicate(call_node(source, **), bound)
    end

    let(:optional_shape) { shape(optional_keys: [:b]) }
    let(:bound) { scope.with_local(:h, optional_shape) }

    def hash_edges(pair, name = :h) = pair.map { |edge| short(edge.local(name)) }

    it "promotes an optional key on the truthy edge of `key?` and removes it on the falsey edge" do
      expect(hash_edges(presence("h.key?(:b)", bound))).to eq(["{ a: Integer, b: String }", "{ a: Integer }"])
    end

    it "treats `has_key?` as `key?`" do
      expect(hash_edges(presence("h.has_key?(:b)", bound))).to eq(["{ a: Integer, b: String }", "{ a: Integer }"])
    end

    it "reads a String key literally" do
      string_shape = shape({ "b" => combinator.nominal_of("String") }, optional_keys: ["b"])

      pair = presence('h.key?("b")', scope.with_local(:h, string_shape))

      expect(hash_edges(pair)).to eq(["{ \"b\" => String }", "{}"])
    end

    it "does not read a Symbol key as a String key" do
      string_shape = shape({ "b" => combinator.nominal_of("String") }, optional_keys: ["b"])

      expect(presence("h.key?(:b)", scope.with_local(:h, string_shape))).to be_nil
    end

    it "narrows an instance-variable receiver" do
      pair = presence("@h.key?(:b)", scope.with_ivar(:@h, optional_shape))

      expect(pair.map { |edge| short(edge.ivar(:@h)) }).to eq(["{ a: Integer, b: String }", "{ a: Integer }"])
    end

    it "narrows the shape members of a union and keeps the others" do
      union = combinator.union(optional_shape, combinator.constant_of(nil))

      pair = presence("h.key?(:b)", scope.with_local(:h, union))

      expect(hash_edges(pair)).to eq(["{ a: Integer, b: String }?", "{ a: Integer }?"])
    end

    it "answers two unchanged edges for a union that holds no shape (the rebuilt union is a new object)" do
      union = combinator.union(combinator.nominal_of("Integer"), combinator.constant_of(nil))

      expect(hash_edges(presence("h.key?(:b)", scope.with_local(:h, union)))).to eq(["Integer?", "Integer?"])
    end

    it "declines a required key, which is already present, and a key the shape does not declare" do
      expect(presence("h.key?(:a)", bound)).to be_nil
      expect(presence("h.key?(:zz)", bound)).to be_nil
    end

    it "declines a receiver that is not a shape" do
      expect(presence("h.key?(:b)", scope.with_local(:h, combinator.nominal_of("Hash")))).to be_nil
      expect(presence("h.key?(:b)", scope.with_local(:h, combinator.untyped))).to be_nil
    end

    it "declines an unbound receiver and a receiver that is neither a local nor an instance variable" do
      expect(presence("h.key?(:b)", scope)).to be_nil
      expect(presence("H.key?(:b)", bound)).to be_nil
      expect(presence("h.a.key?(:b)", bound)).to be_nil
    end

    it "declines a call with no argument or two arguments" do
      expect(presence("h.key?", bound)).to be_nil
      expect(presence("h.key?(:b, :a)", bound)).to be_nil
    end

    it "leaves `include?` and `member?` with a literal key to the computed-key guard, which is off outside a re-walk" do
      expect(presence("h.include?(:b)", bound)).to be_nil
      expect(presence("h.member?(:b)", bound)).to be_nil
    end

    it "leaves a computed key to the guard, which is off outside a re-walk" do
      expect(presence("h.key?(k)", bound)).to be_nil
      expect(presence("h.key?(1)", bound)).to be_nil
    end

    it "answers the guard's truthy scope for a computed key inside a re-walk (#1703)" do
      program = Prism.parse("h = {a: 1}\nif h.key?(k)\n  h[k]\nend", scopes: [[:k]]).value
      node = program.statements.body.last.predicate

      pair = Rigor::Inference::KeyPresenceGuard.with_guards(program) do
        described_class.analyse_key_presence_predicate(node, bound)
      end

      expect(pair.last).to equal(bound)
      expect(pair.first).not_to equal(bound)
    end
  end

  describe ".static_hash_key" do
    def key_of(source) = described_class.static_hash_key(call_node(source))

    it "reads a Symbol literal as a Symbol and a String literal as a String" do
      expect(key_of(":a")).to eq(:a)
      expect(key_of(':"a b"')).to eq(:"a b")
      expect(key_of('"a"')).to eq("a")
    end

    it "declines every other node" do
      expect([key_of("1"), key_of("k"), key_of("nil"), key_of("\"a\#{k}\"")]).to all(be_nil)
    end
  end
end
