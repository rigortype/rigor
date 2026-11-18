# frozen_string_literal: true

require "spec_helper"

# Issue #3320 — a literal key read on a `Union` receiver asks each `HashShape` / `Tuple` member the way that
# member is asked as the lone receiver, and joins the answers. Before the fix `RbsDispatch`'s union arm projected
# every shape member to `Hash[K, V]` / `Array[E]`, so the read answered every value of every key. Each example
# states the expected type and, where the rule applies, that it is the lone answers joined.
RSpec.describe "MethodDispatcher key read on a union of shapes" do
  def comb = Rigor::Type::Combinator
  def c(value) = comb.constant_of(value)
  def u(*types) = comb.union(*types)
  def shape(pairs, **) = comb.hash_shape_of(pairs, **)

  def dispatch(receiver, method_name, args = [])
    Rigor::Inference::MethodDispatcher.dispatch(
      receiver_type: receiver, method_name: method_name, arg_types: args,
      environment: Rigor::Environment.default
    )
  end

  def lone_join(members, method_name, args = [])
    u(*members.map { |member| dispatch(member, method_name, args) })
  end

  def expect_read(members, method_name, args, expected)
    answer = dispatch(u(*members), method_name, args)
    expect(answer).to eq(expected)
    expect(answer).to eq(lone_join(members, method_name, args))
  end

  let(:records) { [shape({ a: c(1), b: c("s") }), shape({ a: c(2), b: c(:t) })] }
  let(:disjoint) { [shape({ a: c(1) }), shape({ b: c(2) })] }

  describe "every member declares the key" do
    it "answers the key's own values for `[]`, `fetch` and `dig`" do
      expect_read(records, :[], [c(:a)], u(c(1), c(2)))
      expect_read(records, :fetch, [c(:a)], u(c(1), c(2)))
      expect_read(records, :dig, [c(:a)], u(c(1), c(2)))
      expect_read(records, :[], [c(:b)], u(c("s"), c(:t)))
    end

    it "reads string keys the same way" do
      members = [shape({ "a" => c(1), "b" => c(2.0) }), shape({ "a" => c(:s), "b" => c("x") })]

      expect_read(members, :[], [c("a")], u(c(1), c(:s)))
    end

    it "applies to three members" do
      members = records + [shape({ a: c(3), b: c(4.0) })]

      expect_read(members, :[], [c(:a)], u(c(1), c(2), c(3)))
    end

    it "follows a nested `dig` through each member's own shape" do
      members = [shape({ a: shape({ b: c(1), c: c("x") }) }), shape({ a: shape({ b: c(:q), c: c(2.0) }) })]

      expect_read(members, :dig, [c(:a), c(:b)], u(c(1), c(:q)))
    end
  end

  describe "a member that lacks the key" do
    it "contributes the `nil` a lone shape lacking it answers to `[]`" do
      expect_read(disjoint, :[], [c(:a)], u(c(1), c(nil)))
    end

    it "keeps what a lone shape answers to `fetch`, which the shape tier leaves to the projection" do
      expect_read(disjoint, :fetch, [c(:a)], u(c(1), c(2)))
      # Without a scope the default binds to `Dynamic[top]` here; `rigor check` answers `0 | 1 | 2`.
      expect_read(disjoint, :fetch, [c(:a), c(0)], u(c(1), c(2), comb.untyped))
    end

    it "contributes `nil` for an optional key" do
      members = [shape({ k: comb.nominal_of("Integer"), o: comb.nominal_of("String") }, optional_keys: [:o]),
                 shape({ k: comb.nominal_of("Symbol"), o: comb.nominal_of("Float") })]

      expect_read(members, :[], [c(:o)], u(comb.nominal_of("String"), c(nil), comb.nominal_of("Float")))
      expect_read(members, :[], [c(:k)], u(comb.nominal_of("Integer"), comb.nominal_of("Symbol")))
    end
  end

  describe "a member that is not a shape" do
    it "keeps a plain Hash member's own answer beside the shape's" do
      plain = comb.nominal_of("Hash", type_args: [comb.nominal_of("Symbol"), comb.nominal_of("String")])

      expect_read([records.first, plain], :[], [c(:a)], u(c(1), comb.nominal_of("String")))
    end

    it "declines with a `nil` member, as before (the typer's nil-receiver path owns that read)" do
      expect(dispatch(u(records.first, c(nil)), :[],
                      [c(:a)])).to eq(dispatch(u(comb.nominal_of("Object"), c(nil)), :[], [c(:a)]))
    end

    it "declines with a `Dynamic` member, as before, so the caller keeps the read gradual" do
      expect(dispatch(u(records.first, comb.untyped), :[], [c(:a)])).to be_nil
    end
  end

  describe "the key is not value-pinned (guards: the projection still answers)" do
    it "answers a plain Symbol key with the projected values and no `nil`, as before" do
      expect(dispatch(u(*records), :[], [comb.nominal_of("Symbol")])).to eq(u(c(1), c("s"), c(2), c(:t)))
    end

    it "answers a union of declared keys as the lone shapes do" do
      expect_read(records, :[], [u(c(:a), c(:b))], u(c(1), c("s"), c(2), c(:t)))
    end
  end

  describe "a union of Tuples" do
    let(:tuples) { [comb.tuple_of(c(1), c("a")), comb.tuple_of(c(2), c(:b))] }

    it "answers the element at the index" do
      expect_read(tuples, :[], [c(0)], u(c(1), c(2)))
      expect_read(tuples, :fetch, [c(1)], u(c("a"), c(:b)))
      expect_read(tuples, :dig, [c(0)], u(c(1), c(2)))
      expect_read(tuples, :first, [], u(c(1), c(2)))
      expect_read(tuples, :last, [], u(c("a"), c(:b)))
    end
  end

  describe "calls that are not key reads (guards: the projection still answers)" do
    it "leaves `values`, `key?` and `first` on a union of hash shapes to the projection" do
      %i[values first].each do |method_name|
        expect(dispatch(u(*records), method_name)).not_to eq(lone_join(records, method_name))
      end
      expect(dispatch(u(*records), :key?, [c(:a)])).to eq(u(c(true), c(false)))
    end
  end
end
