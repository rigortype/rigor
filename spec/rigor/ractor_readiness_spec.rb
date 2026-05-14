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

  # Phase 3 (LANDED in part): the plugin contract carries a
  # Ractor-shareable {Rigor::Plugin::Blueprint} replay carrier
  # alongside live (mutable) plugin instances. A worker Ractor
  # ships `blueprints` across the boundary, then calls
  # {Rigor::Plugin::Registry.materialize} once at startup so the
  # per-Ractor plugin instance (with its mutable accumulators)
  # never escapes its owning Ractor.
  #
  # Plugin instances themselves are intentionally NOT
  # `Ractor.shareable?` — they accumulate per-run state in
  # ivars (`rigor-sorbet`'s `@reachable_absurd_nodes`,
  # `@reveal_type_calls`, `@assert_type_mismatches` are the
  # canonical examples). The blueprint+materialize pattern
  # sidesteps that constraint without forcing every plugin
  # author to refactor.
  # Self-contained reference class so this spec doesn't depend
  # on blueprint_spec.rb being loaded in the same run.
  unless defined?(RigorRactorReadinessSpecPlugin)
    class ::RigorRactorReadinessSpecPlugin < Rigor::Plugin::Base
      manifest(id: "ractor-audit", version: "0.1.0")
    end
  end

  describe "Phase 3 — Plugin contract" do
    let(:blueprint) do
      Rigor::Plugin::Blueprint.new(klass_name: "RigorRactorReadinessSpecPlugin")
    end

    it "Rigor::Plugin::Blueprint is frozen + Ractor.shareable?" do
      expect(blueprint).to be_frozen
      expect(shareable?(blueprint)).to be(true)
    end

    it "Rigor::Plugin::Blueprint with a nested-Hash config is Ractor.shareable?" do
      bp = Rigor::Plugin::Blueprint.new(
        klass_name: "RigorRactorReadinessSpecPlugin",
        config: { "factories" => [{ "path" => "spec/factories" }] }
      )
      expect(shareable?(bp)).to be(true)
    end

    it "Rigor::Plugin::Registry blueprints Array is Ractor.shareable? when populated by the loader" do
      registry = Rigor::Plugin::Registry.new(blueprints: [blueprint])
      expect(registry.blueprints).to be_frozen
      expect(shareable?(registry.blueprints)).to be(true)
    end

    it "Rigor::Plugin::Registry::EMPTY is frozen" do
      expect(Rigor::Plugin::Registry::EMPTY).to be_frozen
    end
  end

  # Phase 4a (LANDED): the per-worker analysis substrate
  # {Rigor::Analysis::WorkerSession}. The session itself is
  # NOT `Ractor.shareable?` — it intentionally owns mutable
  # state (per-session reporters, materialised plugin
  # instances with their accumulators). The contract is:
  # the session's CONSTRUCTOR INPUTS are all
  # `Ractor.shareable?` so a Phase 4b worker Ractor can
  # receive them across the boundary, then build its own
  # session inside the Ractor body.
  describe "Phase 4a — WorkerSession constructor inputs" do
    require "rigor/analysis/worker_session"

    let(:configuration) { Rigor::Configuration.new(Rigor::Configuration::DEFAULTS) }
    let(:blueprint) do
      Rigor::Plugin::Blueprint.new(klass_name: "RigorRactorReadinessSpecPlugin")
    end

    it "Configuration is Ractor.shareable? (Phase 2a)" do
      expect(shareable?(configuration)).to be(true)
    end

    it "Plugin::Blueprint Array is Ractor.shareable? (Phase 3a)" do
      blueprints = [blueprint].freeze
      expect(shareable?(blueprints)).to be(true)
    end

    it "WorkerSession itself is intentionally NOT Ractor.shareable?" do
      session = Rigor::Analysis::WorkerSession.new(
        configuration: configuration, cache_store: nil
      )
      expect(shareable?(session)).to be(false)
    end

    it "WorkerSession owns its own per-session reporters (no cross-session aliasing)" do
      session_a = Rigor::Analysis::WorkerSession.new(
        configuration: configuration, cache_store: nil
      )
      session_b = Rigor::Analysis::WorkerSession.new(
        configuration: configuration, cache_store: nil
      )
      expect(session_a.rbs_extended_reporter).not_to equal(session_b.rbs_extended_reporter)
      expect(session_a.boundary_cross_reporter).not_to equal(session_b.boundary_cross_reporter)
    end
  end

  # Phase 4b (LANDED): the Runner now ships per-file analysis
  # to a Ractor pool around `WorkerSession` when constructed
  # with `workers: N > 0`. The class-level lazy memos every
  # worker reads on its first `Environment.for_project` call
  # MUST be `Ractor.shareable?` — `Environment::ClassRegistry.default`
  # in particular, since lazy-initialising a class @ivar from
  # a non-main Ractor would trip `Ractor::IsolationError`.
  # Pre-warming the registry on the main Ractor is the
  # `Runner#analyze_files_in_pool` contract; this audit
  # asserts the underlying invariant.
  describe "Phase 4b — Ractor pool readiness" do
    it "Environment::ClassRegistry.default is Ractor.shareable?" do
      expect(shareable?(Rigor::Environment::ClassRegistry.default)).to be(true)
    end

    it "the Phase 4b worker-payload tuple crosses a Ractor boundary without raising" do
      configuration = Rigor::Configuration.new(Rigor::Configuration::DEFAULTS)
      cache_root = nil
      blueprints = [].freeze
      explain = false

      ractor = Ractor.new(configuration, cache_root, blueprints, explain) do |c, _r, b, e|
        # Touch each input on the receiving side so the
        # boundary crossing is exercised in full; return a
        # Ractor.shareable? digest so the assertion compares
        # apples to apples.
        [c.frozen?, b.frozen?, e == false].freeze
      end

      expect(ractor.value).to eq([true, true, true])
    end
  end

  # Phase 4b.x: module-level catalogs and canonical-name tables
  # that worker Ractors read during ordinary dispatch. Each
  # MUST be deep-`Ractor.shareable?`; a shallow `.freeze` is
  # insufficient when the value graph contains nested Hash /
  # Array / parsed-YAML payloads (whose inner nodes start out
  # unfrozen). A regression here surfaces on real-world target
  # projects as `Ractor::IsolationError` while reading the
  # singleton-class ivar or constant from a non-main Ractor.
  describe "Phase 4b.x — module catalog shareability" do
    it "NumericCatalog @catalog (singleton-class ivar) is Ractor.shareable?" do
      catalog = Rigor::Inference::Builtins::NumericCatalog.instance_variable_get(:@catalog)
      expect(shareable?(catalog)).to be(true)
    end

    it "Type::Refined::CANONICAL_NAMES is Ractor.shareable?" do
      table = Rigor::Type::Refined.const_get(:CANONICAL_NAMES)
      expect(shareable?(table)).to be(true)
    end

    it "Builtins::RegexRefinement::RULES is Ractor.shareable?" do
      rules = Rigor::Builtins::RegexRefinement.const_get(:RULES)
      expect(shareable?(rules)).to be(true)
    end

    it "MethodDispatcher::ShapeDispatch::REFINED_STRING_PROJECTIONS is Ractor.shareable?" do
      # Defined inside `class << self`, so it lives on the
      # singleton class of `ShapeDispatch`, not directly on the
      # module. `singleton_class.const_get` is the access path.
      table = Rigor::Inference::MethodDispatcher::ShapeDispatch.singleton_class.const_get(:REFINED_STRING_PROJECTIONS)
      expect(shareable?(table)).to be(true)
    end

    # `CONSTANT_CONSTRUCTORS` carries `Proc` values; a shallow
    # `.freeze` leaves the lambdas non-shareable and
    # `constant_constructor_lift`'s `rescue StandardError` quietly
    # swallows the resulting `Ractor::IsolationError`. The result
    # is a precision divergence (`Constant<Pathname>` under
    # sequential, `Nominal[Pathname]` under pool), which then
    # surfaces downstream as a spurious `call.argument-type-mismatch`
    # diagnostic. Surfaced on GitLab FOSS via
    # `lib/gitlab/mail_room.rb:17`.
    it "MethodDispatcher::CONSTANT_CONSTRUCTORS is Ractor.shareable? (Proc values + outer Hash)" do
      table = Rigor::Inference::MethodDispatcher.const_get(:CONSTANT_CONSTRUCTORS)
      expect(shareable?(table)).to be(true)
    end
  end
end
