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

  describe "void-value origins (ADR-100 WD3)" do
    let(:call_node) { Prism.parse("puts 1").value.statements.body.first }
    let(:origin) { Rigor::Inference::VoidOrigin.new(class_name: "VoidBox", method_name: :log, kind: :instance) }

    it "records and reads an origin keyed by the introduction-site node identity" do
      s = scope.record_void_origin(call_node, origin)
      expect(s.void_origins[call_node]).to eq(origin)
      expect(s).to equal(scope) # mutates the shared advisory table in place, like record_dynamic_origin
    end

    it "is identity-keyed (a value-equal but distinct node does not collide)" do
      twin = Prism.parse("puts 1").value.statements.body.first
      scope.record_void_origin(call_node, origin)
      expect(scope.void_origins[twin]).to be_nil
    end

    # Teeth for the `==` / `#hash` exclusion (ADR-100 WD3, mirroring dynamic_origins): recording a void
    # origin must NOT fork a flow-dedup or cache key. Two independent-but-equal scopes (each with its own
    # fresh advisory table, as fresh method-body entry scopes get) must stay `==` / hash-equal after one
    # records a void origin. Reverting the exclusion (adding void_origins to `==` / `#hash`) fails this pair.
    it "is ignored by == and hash (advisory metadata, never varies a flow decision)" do
      base = described_class.empty
      with_void = described_class.empty
      with_void.record_void_origin(call_node, origin)
      expect(with_void).to eq(base)
      expect(with_void.hash).to eq(base.hash)
    end

    it "threads the table by reference through #join (never joined / dropped)" do
      recorded = scope.record_void_origin(call_node, origin)
      joined = recorded.join(scope)
      expect(joined.void_origins[call_node]).to eq(origin)
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

  # Issue #589 — the fold-safe set is a property of the method BODY, stamped once by a static scan and
  # threaded by `rebuild`. `join` omitted it entirely, so every `if` / `while` merge reset it to empty and
  # revoked struct member folding for the rest of the body.
  describe "#join struct fold-safety" do
    it "keeps a grant both arms carry" do
      left = described_class.empty.with_struct_fold_safe(Set[:p])
      right = described_class.empty.with_struct_fold_safe(Set[:p])
      expect(left.join(right).struct_fold_safe?(:p)).to be(true)
    end

    # Intersection, not union: the grant licenses a FOLD, so retaining one an arm did not have could fold
    # a stale constant. Dropping one only costs precision.
    it "drops a grant only one arm carries" do
      left = described_class.empty.with_struct_fold_safe(Set[:p])
      expect(left.join(described_class.empty).struct_fold_safe?(:p)).to be(false)
    end

    it "keeps only the names both arms agree on" do
      left = described_class.empty.with_struct_fold_safe(Set[:p, :q])
      right = described_class.empty.with_struct_fold_safe(Set[:q, :r])
      joined = left.join(right)
      expect([joined.struct_fold_safe?(:p), joined.struct_fold_safe?(:q), joined.struct_fold_safe?(:r)])
        .to eq([false, true, false])
    end
  end

  # Issue #600 — the sibling omission of #589's, found one review apart and with the same shape: the flag was
  # simply absent from `build_joined_scope`, so it fell back to `false` and EVERY merge inside a block reset
  # the #316/#319 decline gate. The direction is what makes it urgent — opacity is the DECLINING state, so a
  # lost flag is a WRONG BIND (a cross-file top-level `def` captured by a DSL block again), not lost precision.
  describe "#join opaque block self" do
    it "keeps the flag when both arms carry it" do
      left = described_class.empty.entering_opaque_block
      right = described_class.empty.entering_opaque_block
      expect(left.join(right).opaque_block_self?).to be(true)
    end

    # `||`, where the fold-safe set intersects: that grant licenses a FOLD, so keeping one an arm lacked could
    # fold a stale constant. This flag licenses a DECLINE, so the conservative merge is the opposite one —
    # keeping it costs only precision, dropping it binds a call the gate exists to leave alone. Asserted in
    # both argument orders because the join reads one side through `@`-ivars and the other through a reader.
    it "keeps the flag when only one arm carries it" do
      opaque = described_class.empty.entering_opaque_block
      clear = described_class.empty
      expect([opaque.join(clear).opaque_block_self?, clear.join(opaque).opaque_block_self?]).to eq([true, true])
    end

    # The must-not-fire pairing: a join does not manufacture opacity, so a merge in ordinary top-level code
    # still binds. Without this, an `opaque_block_self: true` constant would satisfy the two above.
    it "stays clear when neither arm carries it" do
      expect(described_class.empty.join(described_class.empty).opaque_block_self?).to be(false)
    end
  end

  # Issue #600's systematic half. Two omissions of ONE class were found one review apart — #589's
  # `struct_fold_safe_locals` and #600's `opaque_block_self` — and both were the same mistake: a constructor
  # keyword missing from `build_joined_scope`, silently taking its default at every branch merge, surfacing far
  # from the join as a lost fold or a wrong bind. These examples end the class: a keyword added to the
  # constructor and forgotten in the join turns one of them red.
  describe "#join field coverage" do
    def constructor_keywords
      described_class.instance_method(:initialize).parameters
                     .filter_map { |kind, name| name if %i[key keyreq].include?(kind) }
    end

    # How `join` must treat each constructor keyword.
    #
    # - `:merged` — combined from both arms (union, intersection, agreement, or `||`). The exact rule differs
    #   per field and is pinned by the examples above and around; what this roster pins is that the field is
    #   REACHED at all.
    # - `:receiver` — deliberately taken from the receiver alone. `discovery`, `source_path` and
    #   `lexical_nesting` describe where the code IS, not what a branch did. The three `*_origins` node tables
    #   and `plugin_typed_calls` are advisory, compare-by-identity and shared by reference: passing only
    #   `mine` is the documented contract, not an omission.
    # - `:required` — no default exists for it to silently fall back to.
    def join_field_groups
      { merged: %i[
          locals fact_store self_type ivars cvars globals
          indexed_narrowings method_chain_narrowings declaration_sourced
          struct_fold_safe_locals opaque_block_self
          local_origins ivar_origins optimistic_locals optimistic_ivars
        ],
        receiver: %i[
          discovery source_path lexical_nesting
          dynamic_origins void_origins optimistic_origins plugin_typed_calls
        ],
        required: %i[environment] }
    end

    let(:type) { Rigor::Type::Combinator.constant_of(1) }
    let(:node) { Prism.parse("x").value.statements.body.first }
    let(:fact) do
      Rigor::Analysis::FactStore::Fact.new(
        bucket: :local_binding, target: Rigor::Analysis::FactStore::Target.local(:x),
        predicate: :==, payload: type
      )
    end

    # One arm, populated so that EVERY constructor keyword holds a non-default value. Both arms are built from
    # the same values, so the agreement / intersection rules keep them and any field the join forgets shows up
    # as the constructor default instead.
    def populated(fact, type, node)
      described_class.new(
        environment: Rigor::Environment.default,
        locals: { x: type }.freeze,
        fact_store: Rigor::Analysis::FactStore.empty.with_fact(fact),
        self_type: type,
        ivars: { :@i => type }.freeze,
        cvars: { :@@c => type }.freeze,
        globals: { :$g => type }.freeze,
        discovery: Rigor::Scope::DiscoveryIndex::EMPTY.with(discovered_classes: { "C" => :class }.freeze),
        indexed_narrowings: { %i[local h k] => type }.freeze,
        method_chain_narrowings: { %i[local r m] => type }.freeze,
        declaration_sourced: Set[%i[local x]].freeze,
        source_path: "lib/a.rb",
        struct_fold_safe_locals: Set[:s].freeze,
        opaque_block_self: true,
        lexical_nesting: ["A::B"].freeze,
        dynamic_origins: { node => :cause }.compare_by_identity,
        local_origins: { x: :cause }.freeze,
        ivar_origins: { :@i => :cause }.freeze,
        void_origins: { node => :cause }.compare_by_identity,
        plugin_typed_calls: { node => true }.compare_by_identity,
        optimistic_origins: { node => :cause }.compare_by_identity,
        optimistic_locals: { x: :cause }.freeze,
        optimistic_ivars: { :@i => :cause }.freeze
      )
    end

    it "has a join rule recorded for every constructor keyword" do
      # A keyword added to the constructor without a row above fails here, which is the prompt to decide its
      # join semantics rather than discover them from a bug report a release later.
      expect(constructor_keywords).to match_array(join_field_groups.values.flatten)
    end

    # `environment` is excluded because it has no default to fall back TO — every scope here carries the same
    # one, so a difference could never be observed for it.
    def joinable_fields = join_field_groups.values.flatten - %i[environment]

    # The fields whose value on `candidate` is indistinguishable from a scope that was never populated at
    # all — i.e. exactly the ones a join silently dropped back to the constructor default.
    def fields_left_at_default(candidate)
      default = described_class.empty
      joinable_fields.select { |field| candidate.public_send(field) == default.public_send(field) }
    end

    it "leaves no field at its constructor default after joining two populated scopes" do
      joined = populated(fact, type, node).join(populated(fact, type, node))

      expect(fields_left_at_default(joined)).to eq([])
    end

    # Non-vacuity for the example above: the comparison really can see a default, so a green run there means
    # the fields were carried rather than that nothing was ever compared.
    it "reports every field of an unpopulated scope as defaulted" do
      expect(fields_left_at_default(described_class.empty)).to match_array(joinable_fields)
    end

    # The advisory node tables are shared by reference and only the RECEIVER's are passed — deliberate, and
    # documented on the join. Encoded here as the expected semantics so a future audit does not "fix" it.
    it "carries only the receiver's advisory origin tables" do
      mine = Prism.parse("x").value.statements.body.first
      theirs = Prism.parse("y").value.statements.body.first
      left = described_class.empty.record_dynamic_origin(mine, :cause)
      right = described_class.empty.record_dynamic_origin(theirs, :cause)

      joined = left.join(right)

      expect([joined.dynamic_origins.key?(mine), joined.dynamic_origins.key?(theirs)]).to eq([true, false])
    end

    it "drops a self type the two arms disagree about" do
      left = described_class.empty.with_self_type(Rigor::Type::Combinator.constant_of(1))
      right = described_class.empty.with_self_type(Rigor::Type::Combinator.constant_of(2))
      expect(left.join(right).self_type).to be_nil
    end
  end

  # #682 — the candidate order an ancestor NAME walks. It is decided by the `Module.nesting` the
  # SUBCLASS'S declaration header is written in, which the discovery pre-pass records per class, and
  # never by peeling the subclass's qualified name: the two spellings render the identical name.
  describe "#ancestor_name_candidates" do
    def scope_with(header_nestings)
      Rigor::Scope.empty.with_discovery(
        Rigor::Scope::DiscoveryIndex::EMPTY.with(discovered_header_nestings: header_nestings)
      )
    end

    it "offers only the bare name for a compact declaration written at the top level" do
      scope = scope_with({ "Admin::Widget" => [] })
      expect(scope.ancestor_name_candidates("Admin::Widget", "Base")).to eq(%w[Base])
    end

    it "offers the enclosing namespace first for the nested spelling of the same class" do
      scope = scope_with({ "Admin::Widget" => %w[Admin] })
      expect(scope.ancestor_name_candidates("Admin::Widget", "Base")).to eq(["Admin::Base", "Base"])
    end

    it "walks a multi-keyword nesting innermost first" do
      scope = scope_with({ "A::B::C" => ["A::B", "A"] })
      expect(scope.ancestor_name_candidates("A::B::C", "R")).to eq(["A::B::R", "A::R", "R"])
    end

    # The fallback, and the reason an unrecorded class is unchanged rather than degraded: peeling the
    # qualified name IS the nested spelling's chain, so it reproduces the pre-#682 candidate list exactly.
    it "peels the qualified name when no header nesting was recorded, answering the nested spelling" do
      unrecorded = described_class.empty.ancestor_name_candidates("A::B::C", "R")
      expect(unrecorded).to eq(["A::B::R", "A::R", "R"])
      expect(unrecorded).to eq(scope_with({ "A::B::C" => ["A::B", "A"] }).ancestor_name_candidates("A::B::C", "R"))
    end

    it "peels to the bare name alone for a single-segment class" do
      expect(described_class.empty.ancestor_name_candidates("Widget", "Base")).to eq(%w[Base])
    end
  end
end
