# frozen_string_literal: true

require "spec_helper"

# Ractor-readiness audit. Each constructor below SHOULD produce
# a value that's `Ractor.shareable?` so it can cross a Ractor
# boundary without `Ractor.make_shareable` retro-fitting at
# every dispatch.
#
# The audit serves as a regression guard: when someone adds a
# new value-object class to the inference / type-node /
# flow-contribution surface, the matching `it` here documents
# the shareability expectation. Adding a class to one of the
# already-passing groups WITHOUT writing the spec leaves
# Ractor-readiness silent until a later refactor crashes the
# carrier at a Ractor boundary; the audit makes the gap
# visible.
#
# Phase 1 (this spec) covers the Type / TypeNode value-object
# surface that downstream Ractor-isolated workers would carry
# in the most common dispatch paths. Phase 2 (deferred) adds
# `Rigor::Configuration`, `Rigor::Scope`, and
# `Rigor::Environment` once the underlying `RbsLoader` cache
# state is split into a frozen reflection surface plus a
# per-Ractor mutable cache. Phase 3 (deferred) adds plugin
# state.
#
# See `docs/CURRENT_WORK.md` Open Engineering Items #8 for the
# full staged plan.
RSpec.describe "Ractor readiness", :ractor_readiness do
  def shareable?(obj)
    Ractor.shareable?(obj)
  end

  describe "Rigor::Type value objects" do
    it "Type::Top" do
      expect(shareable?(Rigor::Type::Combinator.top)).to be(true)
    end

    it "Type::Bot" do
      expect(shareable?(Rigor::Type::Combinator.bot)).to be(true)
    end

    it "Type::Dynamic" do
      expect(shareable?(Rigor::Type::Combinator.untyped)).to be(true)
    end

    it "Type::Constant — scalar value variants" do
      [
        Rigor::Type::Constant.new(42),
        Rigor::Type::Constant.new(:foo),
        Rigor::Type::Constant.new("hello"),
        Rigor::Type::Constant.new(true),
        Rigor::Type::Constant.new(nil)
      ].each { |c| expect(shareable?(c)).to be(true) }
    end

    it "Type::Nominal / Singleton" do
      expect(shareable?(Rigor::Type::Combinator.nominal_of("Integer"))).to be(true)
      expect(shareable?(Rigor::Type::Combinator.singleton_of("Integer"))).to be(true)
    end

    it "Type::Tuple / HashShape" do
      tuple = Rigor::Type::Combinator.tuple_of(Rigor::Type::Constant.new(1), Rigor::Type::Constant.new(2))
      expect(shareable?(tuple)).to be(true)

      shape = Rigor::Type::Combinator.hash_shape_of(a: Rigor::Type::Constant.new(1))
      expect(shareable?(shape)).to be(true)
    end

    it "Type::IntegerRange" do
      expect(shareable?(Rigor::Type::Combinator.integer_range(1, 10))).to be(true)
    end

    it "Type::Union / Difference / Intersection / Refined" do
      one = Rigor::Type::Constant.new(1)
      two = Rigor::Type::Constant.new(2)
      expect(shareable?(Rigor::Type::Combinator.union(one, two))).to be(true)
      expect(shareable?(Rigor::Type::Combinator.non_empty_string)).to be(true)
      expect(shareable?(Rigor::Type::Combinator.lowercase_string)).to be(true)
      expect(shareable?(Rigor::Type::Combinator.intersection(
                          Rigor::Type::Combinator.lowercase_string,
                          Rigor::Type::Combinator.non_empty_string
                        ))).to be(true)
    end

    it "Type::BoundMethod" do
      bound = Rigor::Type::Combinator.bound_method_of(Rigor::Type::Constant.new("x"), :upcase)
      expect(shareable?(bound)).to be(true)
    end
  end

  describe "Rigor::TypeNode value objects" do
    it "Identifier — even when constructed with a dynamic (unfrozen) String" do
      expect(shareable?(Rigor::TypeNode::Identifier.new(name: +"Foo"))).to be(true)
    end

    it "Generic — even with a dynamic head + nested Identifier args" do
      generic = Rigor::TypeNode::Generic.new(
        head: +"Pick", args: [Rigor::TypeNode::Identifier.new(name: +"A")]
      )
      expect(shareable?(generic)).to be(true)
    end

    it "IntegerLiteral / SymbolLiteral / StringLiteral" do
      expect(shareable?(Rigor::TypeNode::IntegerLiteral.new(value: 42))).to be(true)
      expect(shareable?(Rigor::TypeNode::SymbolLiteral.new(value: :foo))).to be(true)
      expect(shareable?(Rigor::TypeNode::StringLiteral.new(value: +"foo"))).to be(true)
    end

    it "IndexedAccess" do
      access = Rigor::TypeNode::IndexedAccess.new(
        receiver: Rigor::TypeNode::Identifier.new(name: +"Hash"),
        key: Rigor::TypeNode::IntegerLiteral.new(value: 0)
      )
      expect(shareable?(access)).to be(true)
    end

    it "Union" do
      union = Rigor::TypeNode::Union.new(nodes: [
                                           Rigor::TypeNode::Identifier.new(name: +"A"),
                                           Rigor::TypeNode::Identifier.new(name: +"B")
                                         ])
      expect(shareable?(union)).to be(true)
    end
  end

  describe "Other value objects" do
    it "Rigor::Cache::Descriptor" do
      expect(shareable?(Rigor::Cache::Descriptor.new)).to be(true)
    end

    it "Rigor::Analysis::FactStore.empty" do
      expect(shareable?(Rigor::Analysis::FactStore.empty)).to be(true)
    end

    it "Rigor::FlowContribution" do
      contribution = Rigor::FlowContribution.new(return_type: Rigor::Type::Combinator.untyped)
      expect(shareable?(contribution)).to be(true)
    end
  end

  describe "Phase 2 — Configuration / Scope / Environment" do
    # Phase 2a (LANDED): `Configuration` deep-freezes its
    # `@paths` Array + calls `freeze` on `self` at the end
    # of `initialize`. Backward-compatible — every reader
    # path treats the Configuration as immutable already.
    it "Rigor::Configuration (Phase 2a)" do
      expect(shareable?(Rigor::Configuration.new(Rigor::Configuration::DEFAULTS))).to be(true)
    end

    # Phase 2b (LANDED): `Environment::Reflection` extracts
    # the loader's read-only RBS query surface into a
    # frozen carrier. NOT `Ractor.shareable?` because the
    # cached `RBS::Definition` objects transitively
    # reference `RBS::Location` (C-extension state that
    # `Ractor.make_shareable` rejects). The Phase 4 worker
    # pool sidesteps the constraint by building one
    # Reflection per worker from the shared `Cache::Store`;
    # the cross-Ractor sharing point is the Store, NOT the
    # Reflection.
    it "Rigor::Environment::Reflection is frozen (Phase 2b)" do
      reflection = Rigor::Environment.for_project.reflection
      expect(reflection).not_to be_nil
      expect(reflection).to be_frozen
    end

    it "Rigor::Environment::Reflection is NOT Ractor.shareable? (RBS::Location upstream constraint)" do
      reflection = Rigor::Environment.for_project.reflection
      expect(shareable?(reflection)).to be(false)
    end

    # Phase 2b residual targets — still pending. The
    # blockers are documented in
    # `docs/design/20260514-ractor-migration.md` and
    # ADR-15; `skip` keeps the gap visible in
    # `make verify` output.
    it "Rigor::Scope.empty" do
      skip "Phase 2b residual: Scope.environment carries the non-shareable RbsLoader"
      expect(shareable?(Rigor::Scope.empty)).to be(true)
    end

    it "Rigor::Environment.default" do
      skip "Phase 2b residual: RbsLoader holds mutable @class_known_cache (per-Ractor accelerator)"
      expect(shareable?(Rigor::Environment.default)).to be(true)
    end
  end
end
