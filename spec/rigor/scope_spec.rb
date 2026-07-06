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

    it "starts with an empty fact store" do
      expect(scope.fact_store).to be_empty
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

    it "invalidates facts attached to the rebound local" do
      fact = Rigor::Analysis::FactStore::Fact.new(
        bucket: :local_binding,
        target: Rigor::Analysis::FactStore::Target.local(:x),
        predicate: :==,
        payload: Rigor::Type::Combinator.constant_of(1)
      )
      with_fact = scope.with_fact(fact)

      next_scope = with_fact.with_local(:x, Rigor::Type::Combinator.constant_of(2))

      expect(next_scope.local_facts(:x)).to be_empty
    end
  end

  describe "propagated dynamic-origins (ADR-82 WD1)" do
    it "records and reads a local / ivar origin" do
      s = scope.with_local_origin(:x, :inferred_return_untyped).with_ivar_origin(:@y, :unsupported_syntax)
      expect(s.local_origin(:x)).to eq(:inferred_return_untyped)
      expect(s.ivar_origin(:@y)).to eq(:unsupported_syntax)
    end

    it "treats a nil cause as a no-op returning self" do
      s = scope.with_local_origin(:x, nil)
      expect(s).to equal(scope)
      expect(s.local_origin(:x)).to be_nil
    end

    it "drops a local's origin when the local is rebound (the new value sets its own)" do
      s = scope.with_local_origin(:x, :unsupported_syntax)
               .with_local(:x, Rigor::Type::Combinator.constant_of(1))
      expect(s.local_origin(:x)).to be_nil
    end

    it "is ignored by == and hash (advisory metadata, never varies a flow decision)" do
      base = scope.with_local(:x, Rigor::Type::Combinator.constant_of(1))
      with_origin = base.with_local_origin(:x, :inferred_return_untyped)
      expect(with_origin).to eq(base)
      expect(with_origin.hash).to eq(base.hash)
    end
  end

  describe "declaration-sourced provenance (ADR-58 WD1)" do
    let(:type) { Rigor::Type::Combinator.union(Rigor::Type::Combinator.nominal_of("P"), Rigor::Type::Combinator.constant_of(nil)) }

    it "marks a seeded ivar declaration-sourced" do
      seeded = scope.seed_declaration_sourced_ivar(:@right, type)
      expect(seeded.declaration_sourced?(:ivar, :@right)).to be(true)
    end

    it "drops the mark on a method-local ivar write" do
      seeded = scope.seed_declaration_sourced_ivar(:@right, type)
      written = seeded.with_ivar(:@right, type)
      expect(written.declaration_sourced?(:ivar, :@right)).to be(false)
    end

    it "propagates the mark to a local copy of a declaration-sourced ivar" do
      seeded = scope.seed_declaration_sourced_ivar(:@right, type)
      copied = seeded.with_declaration_sourced_local(:r, type)
      expect(copied.declaration_sourced?(:local, :r)).to be(true)
    end

    it "drops a local's mark when the local is rebound" do
      copied = scope.with_declaration_sourced_local(:r, type)
      rebound = copied.with_local(:r, Rigor::Type::Combinator.constant_of(nil))
      expect(rebound.declaration_sourced?(:local, :r)).to be(false)
    end

    it "keeps the mark only when both join branches agree (intersection)" do
      live = scope # no mark
      seeded = scope.seed_declaration_sourced_ivar(:@right, type)
      joined = seeded.join(live)
      expect(joined.declaration_sourced?(:ivar, :@right)).to be(false)
    end

    it "keeps the mark when both branches carry it" do
      a = scope.seed_declaration_sourced_ivar(:@right, type)
      b = scope.seed_declaration_sourced_ivar(:@right, type)
      expect(a.join(b).declaration_sourced?(:ivar, :@right)).to be(true)
    end

    it "participates in structural equality" do
      a = scope.seed_declaration_sourced_ivar(:@right, type)
      b = scope.with_ivar(:@right, type)
      expect(a).not_to eq(b)
    end
  end

  describe "#forget_match_globals" do
    it "drops narrowed regex match-data globals so reads fall back to the default" do
      md = Rigor::Type::Combinator.nominal_of("MatchData")
      str = Rigor::Type::Combinator.nominal_of("String")
      narrowed = scope.with_global(:$~, md).with_global(:$1, str).with_global(:$&, str)

      forgotten = narrowed.forget_match_globals

      expect(forgotten.global(:$~)).to be_nil
      expect(forgotten.global(:$1)).to be_nil
      expect(forgotten.global(:$&)).to be_nil
    end

    it "leaves non-match program globals untouched" do
      str = Rigor::Type::Combinator.nominal_of("String")
      seeded = scope.with_global(:$LOAD_PATH, str).with_global(:$1, str)

      forgotten = seeded.forget_match_globals

      expect(forgotten.global(:$LOAD_PATH)).to eq(str)
      expect(forgotten.global(:$1)).to be_nil
    end

    it "returns the same scope when no match globals are present" do
      str = Rigor::Type::Combinator.nominal_of("String")
      seeded = scope.with_global(:$stdout, str)

      expect(seeded.forget_match_globals).to equal(seeded)
    end
  end

  describe "#with_fact" do
    it "returns a new scope with the fact added" do
      fact = Rigor::Analysis::FactStore::Fact.new(
        bucket: :local_binding,
        target: Rigor::Analysis::FactStore::Target.local(:x),
        predicate: :==,
        payload: Rigor::Type::Combinator.constant_of(1)
      )
      next_scope = scope.with_fact(fact)

      expect(next_scope).not_to equal(scope)
      expect(next_scope.local_facts(:x)).to eq([fact])
      expect(scope.local_facts(:x)).to be_empty
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

    it "differs when fact stores differ" do
      fact = Rigor::Analysis::FactStore::Fact.new(
        bucket: :local_binding,
        target: Rigor::Analysis::FactStore::Target.local(:x),
        predicate: :==,
        payload: Rigor::Type::Combinator.constant_of(1)
      )
      expect(scope.with_fact(fact)).not_to eq(scope)
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

    it "joins fact stores conservatively" do
      fact = Rigor::Analysis::FactStore::Fact.new(
        bucket: :local_binding,
        target: Rigor::Analysis::FactStore::Target.local(:x),
        predicate: :==,
        payload: integer_one
      )
      a = scope.with_local(:x, integer_one).with_fact(fact)
      b = scope.with_local(:x, integer_one).with_fact(fact)

      expect(a.join(b).local_facts(:x)).to eq([fact])
    end
  end

  describe "self_type (Slice A-engine)" do
    let(:integer_one) { Rigor::Type::Combinator.constant_of(1) }
    let(:foo) { Rigor::Type::Combinator.nominal_of("Foo") }
    let(:bar) { Rigor::Type::Combinator.nominal_of("Bar") }

    it "defaults to nil for an empty scope" do
      expect(scope.self_type).to be_nil
    end

    it "with_self_type returns a fresh scope, preserving locals and facts" do
      bound = scope.with_local(:x, integer_one).with_self_type(foo)
      expect(bound.self_type).to eq(foo)
      expect(bound.local(:x)).to eq(integer_one)
    end

    it "does not mutate the receiver" do
      _ = scope.with_self_type(foo)
      expect(scope.self_type).to be_nil
    end

    it "with_local preserves self_type" do
      typed = scope.with_self_type(foo).with_local(:x, integer_one)
      expect(typed.self_type).to eq(foo)
    end

    it "join keeps self_type when both sides agree" do
      a = scope.with_local(:x, integer_one).with_self_type(foo)
      b = scope.with_local(:x, integer_one).with_self_type(foo)
      expect(a.join(b).self_type).to eq(foo)
    end

    it "join drops self_type to nil when sides disagree" do
      a = scope.with_local(:x, integer_one).with_self_type(foo)
      c = scope.with_local(:x, integer_one).with_self_type(bar)
      expect(a.join(c).self_type).to be_nil
    end

    it "==/hash include self_type" do
      a = scope.with_self_type(foo)
      b = scope.with_self_type(foo)
      c = scope.with_self_type(bar)
      expect(a).to eq(b)
      expect(a.hash).to eq(b.hash)
      expect(a).not_to eq(c)
    end
  end
end
