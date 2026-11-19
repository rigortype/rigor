# frozen_string_literal: true

require_relative "../reflection"
require_relative "../typing_state"
require_relative "../type"
require_relative "dynamic_origin"
require_relative "flow_tracer"
require_relative "void_tail_summary"
require_relative "method_dispatcher/call_context"
require_relative "method_dispatcher/argument_nodes"
require_relative "method_dispatcher/constant_folding"
require_relative "method_dispatcher/literal_string_folding"
require_relative "method_dispatcher/shape_dispatch"
require_relative "method_dispatcher/data_folding"
require_relative "method_dispatcher/struct_folding"
require_relative "method_dispatcher/rbs_dispatch"
require_relative "method_dispatcher/declared_constructor"
require_relative "method_dispatcher/iterator_dispatch"
require_relative "method_dispatcher/arithmetic_sequence_elements"
require_relative "method_dispatcher/reduce_folding"
require_relative "method_dispatcher/block_folding"
require_relative "method_dispatcher/array_to_h_folding"
require_relative "method_dispatcher/hash_transform_keys_folding"
require_relative "method_dispatcher/file_folding"
require_relative "method_dispatcher/shellwords_folding"
require_relative "method_dispatcher/math_folding"
require_relative "method_dispatcher/random_folding"
require_relative "method_dispatcher/time_folding"
require_relative "method_dispatcher/regexp_folding"
require_relative "method_dispatcher/match_data_folding"
require_relative "method_dispatcher/process_folding"
require_relative "method_dispatcher/cgi_folding"
require_relative "method_dispatcher/uri_folding"
require_relative "method_dispatcher/set_folding"
require_relative "method_dispatcher/json_folding"
require_relative "method_dispatcher/kernel_dispatch"
require_relative "method_dispatcher/universal_object_dispatch"
require_relative "method_dispatcher/singleton_mixin_dispatch"
require_relative "method_dispatcher/method_folding"
require_relative "method_dispatcher/optional_count"
require_relative "method_dispatcher/meta_introspection"
require_relative "method_dispatcher/hkt_builtin_return"
require_relative "method_dispatcher/static_refinement"
require_relative "method_dispatcher/synthesized_stub"
require_relative "method_dispatcher/plugin_contribution"
require_relative "method_dispatcher/synthetic_method_dispatch"
require_relative "method_dispatcher/project_patched"
require_relative "method_dispatcher/dependency_source"
require_relative "../run_scoped_slots"

module Rigor
  module Inference
    # Coordinates method dispatch for the inference engine.
    #
    # Given `(receiver_type, method_name, arg_types, block_type, environment)`, the dispatcher
    # returns the inferred result type or `nil` when no rule matches. `nil` is a deliberately
    # blunt "I don't know" signal: callers (`ExpressionTyper`, `StatementEvaluator`, `GuardRebinding`) own the fail-soft
    # fallback and decide whether to record a `FallbackTracer` event.
    #
    # Tier order is documented inline in `resolve`; the precise-tier group is built from
    # `PRECISE_TIERS_HEAD`, `STDLIB_SINGLETON_FOLDERS`, and `PRECISE_TIERS_TAIL`. `ShapeDispatch`
    # runs above {RbsDispatch} so a precise per-position/per-key answer wins over the projected
    # `Array#[]`/`Hash#fetch` RBS answer.
    #
    # The `block_type:` and plugin contribution (`dynamic_return`) tiers landed in Slice 6 phase C
    # and v0.1.1 Track 2 respectively; all call sites pass through `dispatch`/`resolve` unchanged.
    module MethodDispatcher # rubocop:disable Metrics/ModuleLength
      module_function

      # @param receiver_type — type of the receiver expression, or
      #   `nil` for an implicit-self call.
      # @param block_type — inferred return type of the
      #   accompanying `do ... end` / `{ ... }` block (Slice 6 phase C
      #   sub-phase 2). When non-nil, the dispatcher prefers an
      #   overload that declares a block, and binds the method's
      #   block-return type variable to `block_type` so a return type
      #   like `Array[U]` resolves to `Array[block_type]`.
      # @param environment — required for
      #   RBS-backed dispatch; when nil only constant folding can fire.
      # @return inferred result type, or `nil` for "no rule".
      def dispatch(receiver_type:, method_name:, arg_types:,
                   block_type: nil, environment: nil,
                   call_node: nil, scope: nil)
        result = resolve(
          receiver_type: receiver_type, method_name: method_name, arg_types: arg_types,
          block_type: block_type, environment: environment,
          call_node: call_node, scope: scope
        )
        # ADR-100 WD4 — the transitive-void consult, HERE in the wrapper rather than in any result
        # tier: which tier answers the intermediate's call depends on where the leaf's RBS came from
        # (`RbsDispatch` on the ADR-93 synthesized `untyped` skeleton, or the post-dispatch
        # `ExpressionTyper` body-inference tiers on a partial hand-written `sig/`), and both answers
        # are correct types that must not change. Recording is therefore result-independent and
        # type-blind; a statement-position record stays inert because the collector only reads value
        # positions.
        record_transitive_void_origin(receiver_type, method_name, call_node, scope)
        # `rigor trace` — record the dispatch outcome (resolved type, or the fail-soft `nil` the
        # caller widens to `Dynamic[Top]`).
        if FlowTracer.active?
          FlowTracer.dispatch(
            receiver: receiver_type, method_name: method_name, args: arg_types,
            result: result, location: call_node&.location
          )
        end
        result
      end

      # `plugin_typed_sink` is internal bookkeeping for the composite-receiver tier below: when it is an
      # Array, an answering plugin tier PUSHES the call node instead of recording it on the scope, and
      # the tier commits the buffer only if it goes on to answer. See {#try_composite_receiver}.
      def resolve(receiver_type:, method_name:, arg_types:, # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/ParameterLists
                  block_type: nil, environment: nil,
                  call_node: nil, scope: nil, plugin_typed_sink: nil, skip_project_patched: false)
        return nil if receiver_type.nil?

        # Issue #1393 — a `nil` count on `min` / `max` / `min_by` / `max_by` is the no-count call.
        nil_count = OptionalCount.split(receiver_type, method_name, arg_types, block: !block_type.nil?)
        if nil_count
          return resolve_nil_count(nil_count.first, receiver_type: receiver_type, method_name: method_name,
                                                    block_type: block_type, environment: environment,
                                                    call_node: call_node, scope: scope,
                                                    plugin_typed_sink: plugin_typed_sink,
                                                    skip_project_patched: skip_project_patched)
        end

        # Build the call context once and thread it — unchanged — through every tier
        # (`_DispatchTier#try_dispatch`). The dispatcher's own private fallback tiers still read
        # the positional locals below; only the tier modules consume the context object.
        context = CallContext.build(
          receiver: receiver_type, method_name: method_name, args: arg_types,
          block_type: block_type, environment: environment,
          call_node: call_node, scope: scope
        )

        bound_method_result = MethodFolding.try_backward(context)
        return bound_method_result if bound_method_result

        precise = dispatch_precise_tiers(context)
        return precise if precise

        # v0.1.1 Track 2 slice 7 — plugin return-type contribution tier ({PluginContribution}). Sits ahead of
        # `RbsDispatch` so a plugin that understands a domain-specific dispatch (e.g. an
        # `ActiveRecord::Base.find` returning `Nominal[<resolved model>]`) wins over the
        # RBS-projected envelope. Only consults the registry when both `call_node` and `scope`
        # are supplied — the dispatcher's own internal callers (per-element block fold, etc.)
        # skip this tier.
        plugin_result = PluginContribution.try_dispatch(context)
        if plugin_result
          # Issue #653 — this tier answering is what makes the site's type the plugin's rather than the
          # RBS's, and `call.undefined-method` reads that record instead of re-deciding from the receiver's
          # (possibly partial) signature. Recorded for EVERY plugin answer, dynamic or precise: the
          # incoherence the record closes is about which subsystem typed the call, not about the type.
          #
          # Under a composite-receiver projection the record is BUFFERED instead (#1101). It is the one
          # recording in this method that is set-only — `Scope#plugin_typed_calls` has no removal, and
          # `UndefinedMethod.call_site_exempt?` / `WrongArity.source_arity_envelope` read it as an exemption — so a
          # member a plugin answers beside a member that declines would exempt a call this dispatcher
          # never typed, silencing `call.undefined-method` and `call.wrong-arity` on a firing that stands.
          # `call_site_exempt?` runs ahead of the receiver-shape branch, so the union rule is covered by
          # it too and the suppression is reachable end to end — the arms are measured in
          # `spec/integration/composite_receiver_plugin_typed_suppression_spec.rb`. The
          # `record_dynamic_origin` writes below and in the tiers that follow need no such care: that
          # table is last-wins and the caller's fail-soft widening overwrites it.
          if plugin_typed_sink
            plugin_typed_sink << call_node
          else
            scope&.record_plugin_typed_call(call_node)
          end
          if plugin_result.is_a?(Type::Dynamic)
            scope&.record_dynamic_origin(call_node, DynamicOrigin::FRAMEWORK_DSL_BOUNDARY)
          end
          return plugin_result
        end

        # ADR-20 slice 3 — Rigor-bundled HKT-builtin return-type tier ({HktBuiltinReturn}). Sits ABOVE
        # `RbsDispatch.try_dispatch` so the handful of stdlib methods whose upstream RBS
        # signature is `untyped` but whose runtime shape Rigor models via a Lightweight HKT
        # (`json::value`, eventually `dry_monads::result`, …) get the reduced type instead of
        # `Dynamic[Top]`. The table that populates this tier lives in
        # `Rigor::Builtins::HktBuiltins::METHOD_RETURN_OVERRIDES`; plugin-supplied per-method
        # overrides are out of scope for slice 3 and continue to flow through the
        # {PluginContribution} tier above.
        #
        # Rigor-bundled static refinement tier ({StaticRefinement}). Sits between HKT and RBS so stdlib methods whose
        # upstream RBS is broader than the documented behaviour (e.g. `Kernel#__dir__` declared
        # `() -> String?` when the documented return is `non-empty-string | nil`) get the
        # tightened type without modifying the vendored `ruby/rbs` submodule. The override table
        # lives in `Rigor::Builtins::StaticReturnRefinements::OVERRIDES`.
        bundled_override = first_tier_answer(BUNDLED_OVERRIDE_TIERS, context)
        return bundled_override if bundled_override

        # `Foo.instance` for a class that includes the stdlib `Singleton` mixin. Ruby grows that method through
        # an `included` hook and the upstream RBS leaves `Singleton::SingletonClassMethods` empty, so nothing
        # below can answer it. See {SingletonMixinDispatch} for why the value matters more than the site count.
        singleton_mixin = SingletonMixinDispatch.try_dispatch(context)
        return singleton_mixin if singleton_mixin

        rbs_result = RbsDispatch.try_dispatch(context)
        if rbs_result
          record_boundary_cross_if_applicable(receiver_type, method_name, rbs_result, environment)
          if Type::Combinator.untyped?(rbs_result)
            scope&.record_dynamic_origin(call_node, DynamicOrigin::EXPLICIT_UNTYPED)
          end
          return rbs_result
        end

        # ADR-16 Tier B / Tier C — synthetic-method tier ({SyntheticMethodDispatch}). Sits BELOW RBS dispatch (per WD13:
        # user-authored RBS overrides substrate synthesis) and ABOVE the dependency-source
        # inference tier so a plugin's declared emit table beats the generic gem-source fallback
        # for the same class. Slice 6a-TierB (origin_module dispatch) lands precise return types
        # for Tier B emissions; Tier C emissions return their manifest `return_type` when the environment
        # names that class (slice 6b), and `Dynamic[T]` otherwise.
        synthetic_result = first_tier_answer(SYNTHETIC_TIERS, context)
        return synthetic_result if synthetic_result

        # ADR-17 slice 2 — project-side patched-method tier ({ProjectPatched}). Sits BELOW the substrate / plugin
        # tiers and ABOVE dependency-source inference per ADR-17 § "Inference contract". When
        # the user's `pre_eval:` list named a file that re-opens a class (e.g.,
        # `lib/core_ext/string_extensions.rb` declaring `class String; def to_url; end; end`),
        # the pre-pass populated `ProjectPatchedMethods` with the `(class, method, kind)` triple;
        # this tier surfaces it as `Dynamic[top]` so the patched call resolves cross-file without
        # `call.undefined-method`.
        patched_result = ProjectPatched.try_dispatch(context) unless skip_project_patched
        if patched_result
          scope&.record_dynamic_origin(call_node, DynamicOrigin::EXTERNAL_GEM_WITHOUT_RBS)
          return patched_result
        end

        # ADR-10 slice 2b-ii — dependency-source inference tier ({DependencySource}). Sits BELOW RBS dispatch (RBS /
        # RBS::Inline / generated stubs / plugin contracts always win) and ABOVE the user-class
        # fallback so a method defined in an opt-in gem stops emitting `call.undefined-method`
        # even when no signature contract resolves. Returns `Dynamic[top]` — slice 2b-ii
        # deliberately stops at the dynamic-origin envelope; per-method return-type precision is
        # queued for a later slice.
        dep_source_result = DependencySource.try_dispatch(context)
        if dep_source_result
          scope&.record_dynamic_origin(call_node, DynamicOrigin::EXTERNAL_GEM_WITHOUT_RBS)
          return dep_source_result
        end

        # v0.1.3 — discovered-method dispatch tier. When the receiver class has no RBS BUT
        # scope_indexer recorded `def method_name` for that class (or singleton), the call
        # dispatches to `Dynamic[top]` rather than falling through to the user-class fallback.
        # Sits below RBS / dependency-source so authoritative signatures still win. The
        # scope-indexer-built table records every project-side `def`, `define_method`, and
        # `alias_method`; the `discovered_method?` consult here closes the fail-soft-event hot
        # spot on implicit-self calls (`sibling_private(...)`) inside `lib/rigor/`'s own
        # internals (analyser private helpers don't have RBS).
        discovered_result = try_discovered_method(receiver_type, method_name, scope)
        if discovered_result
          # ADR-82 WD2/WD3 — the call resolved to a discovered user method but its return could not be
          # inferred (bare `def`, untyped-parameter chain). Record it as an inference gap, not the
          # generic `unsupported_syntax`, so `coverage --protection` routes it to ADR-58/67.
          if discovered_result.is_a?(Type::Dynamic)
            scope&.record_dynamic_origin(call_node, DynamicOrigin::INFERRED_RETURN_UNTYPED)
          end
          return discovered_result
        end

        # Issue #1708 — a `pre_eval:` patch on one of the receiver's ancestors (`class Object; def zz`,
        # `module Enumerable; def sum_by`). Below the RBS tier, whose decline means no nearer RBS declares the
        # method, and below the tiers that answer the receiver's own patch or a gem catalogue entry. A nearer
        # `def` in the project's source (on an RBS-known receiver, which the discovered-method tier leaves to
        # user-method inference) stops the walk: see {ProjectPatched.project_source_defines?}. That probe reads the
        # scope's def index, so a single-file scope (`type-of`, `annotate`, an LSP buffer) cannot see a `def` in
        # another file.
        ancestor_patched =
          (ProjectPatched.try_dispatch(context, through_ancestors: true) if !skip_project_patched && scope)
        if ancestor_patched
          scope&.record_dynamic_origin(call_node, DynamicOrigin::EXTERNAL_GEM_WITHOUT_RBS)
          return ancestor_patched
        end

        # ADR-5 robustness — synthesized-stub-type tier ({SynthesizedStub}). When the receiver is a type Rigor
        # invented to make an otherwise-unbuildable project signature resolve (a
        # missing-namespace module, or a stub for a referenced-but-undeclared type like an
        # unavailable `DRb::DRbServer`), the stub carries no methods, so an unresolved call
        # against it would otherwise mis-fire `call.undefined-method`. Resolve it to
        # `Dynamic[Top]` instead — the same no-false-positive contract as the dependency-source
        # tier. Sits below every real resolution tier so a genuine signature always wins.
        stub_result = first_tier_answer(STUB_TIERS, context)
        return stub_result if stub_result

        # The receiver-independent `BasicObject` / `Object` / `Kernel` selectors, for a receiver no tier
        # above could name. `x.nil?` is `bool` whatever `x` is; without this tier it was `Dynamic[Top]`
        # like every other call on an untyped receiver. Sits here, below every real resolution tier, so a
        # nameable receiver always answers from its own signature first — this only ever replaces a
        # `Dynamic[Top]` the typer was about to produce. See {UniversalObjectDispatch} for the table and
        # for the selectors deliberately left out of it.
        universal_result = UniversalObjectDispatch.try_dispatch(context)
        return universal_result if universal_result

        # Slice 7 phase 10 — user-class ancestor fallback. When the receiver is `Nominal[T]` or
        # `Singleton[T]` for a class not in the RBS environment (typically a user-defined class),
        # retry the dispatch against the implicit ancestor: `Nominal[Object]` for instance
        # receivers and `Singleton[Object]` for singleton receivers. This resolves Kernel
        # intrinsics (`require`, `raise`, `puts`, ...) and Module/Class introspection
        # (`attr_reader`, `private`, ...) on user classes without requiring the user to author
        # their own RBS.
        fallback_result = try_user_class_fallback(receiver_type, environment, call_node, context)
        # ADR-82 WD2/WD3 — a user-class receiver whose call resolved to the lenient ancestor fallback
        # with no inferable return. Same inference-gap provenance as the discovered-method tier, so a
        # downstream dispatch on this value is labeled honestly rather than `unsupported_syntax`.
        if fallback_result.is_a?(Type::Dynamic)
          scope&.record_dynamic_origin(call_node, DynamicOrigin::INFERRED_RETURN_UNTYPED)
        end
        return fallback_result if fallback_result

        # Issue #1101 — composite-receiver projection, the last tier. Every tier above needs a
        # receiver it can name; a `Union` or a `Difference` is not one, so a composite receiver whose
        # members WOULD each resolve still lands `Dynamic[top]`. Retry per projected member through
        # this same chain. See {#try_composite_receiver} for the projection rule and why it sits here.
        try_composite_receiver(context)
      end

      # The `nil` part of an optional count dispatches as the no-argument call, the rest as written; a count
      # that is both answers the union of the two, or declines when either declines. See {OptionalCount}.
      def resolve_nil_count(rest, **common)
        return resolve(arg_types: [], **common) if rest.nil?

        # The counted leg runs first: a leg's plugin answer records on the scope (or buffers in the sink, #1101),
        # and a declining counted leg must not leave the no-argument leg's record behind for a call that answers nil.
        counted = resolve(arg_types: [rest], **common)
        return nil if counted.nil?

        without = resolve(arg_types: [], **common)
        without && Type::Combinator.union(without, counted)
      end

      # ADR-100 WD4 — records the transitive `-> void` provenance when the called method is a
      # discovered project `def` whose {VoidTailSummary} chain ends in an author-declared `-> void`
      # leaf on the same owner. Guards cheapest-first: the internal dispatcher callers nil `scope` /
      # `call_node` out; the receiver must project through {#discovered_method_lookup}
      # (`Nominal` / `Singleton` only — unions and `Dynamic` receivers stay out); and the
      # `discovered_method?` pre-filter (two pure hash reads) keeps the hot path at ~zero cost —
      # only a call that provably targets a discovered def of the right kind resolves the node and
      # consults the summary. The `Prism::CallNode` guard mirrors `PluginContribution.collect_plugin_contributions`:
      # the `&:symbol` block path dispatches with the `Prism::BlockArgumentNode` itself, which is
      # never a collector value position, so recording on it would be dead weight.
      def record_transitive_void_origin(receiver_type, method_name, call_node, scope)
        return if scope.nil? || call_node.nil?
        return unless call_node.is_a?(Prism::CallNode)

        class_name, kind = discovered_method_lookup(receiver_type)
        return if class_name.nil?
        return unless scope.discovered_method?(class_name, method_name, kind)

        def_node =
          if kind == :singleton
            scope.singleton_def_for(class_name, method_name)
          else
            scope.user_def_for(class_name, method_name)
          end
        return if def_node.nil?

        origin = VoidTailSummary.new(scope).origin_for(def_node, class_name, kind)
        scope.record_void_origin(call_node, origin) if origin
      end

      # v0.1.3 — discovered-method dispatch tier. `scope` carries the `discovered_methods` table
      # built once per program by `ScopeIndexer` (a `Hash[String, Hash[Symbol, :instance |
      # :singleton]]`). When the receiver names a discovered class AND the requested method is
      # recorded for that class's appropriate kind, return `Type::Combinator.untyped` — the
      # dispatcher cannot infer a more precise return type from the bare `def` shape, but the
      # call site stops being a fail-soft hot spot.
      #
      # Returns `nil` when scope / receiver class is unavailable, when the method is not in the
      # discovered table, OR when `discovered_def_nodes` carries a re-typable body for the method
      # (so the downstream `ExpressionTyper#try_user_method_inference` tier can re-type the body
      # for a precise return type rather than collapsing to `Dynamic[top]` here).
      #
      # The tier does NOT gate on `rbs_class_known?`. RBS dispatch already had its turn upstream
      # and returned `nil` (otherwise we wouldn't be here). When RBS knows the class but the
      # particular method is missing from the sig — common for internal helpers and for
      # auto-generated stubs that emit `class X` without enumerating every method — falling
      # through to the user-class fallback would mistakenly fire `call.undefined-method`.
      # Honoring the discovered table here keeps the sibling-private call resolution working
      # under partial RBS coverage.
      def try_discovered_method(receiver_type, method_name, scope)
        return nil if scope.nil?

        class_name, kind = discovered_method_lookup(receiver_type)
        return nil if class_name.nil?
        return nil unless scope.discovered_method?(class_name, method_name, kind)
        # Decline when a re-typable body is recorded for the method, so the downstream
        # `ExpressionTyper` inference tier can fold a precise return instead of collapsing to
        # `Dynamic[top]` here — instance bodies via `user_def_for`, singleton bodies (`def
        # self.x` / `module_function`) via `singleton_def_for` (module-singleton call
        # resolution, ADR-57 follow-up).
        return nil if kind == :instance && scope.user_def_for(class_name, method_name)
        return nil if kind == :singleton && scope.singleton_def_for(class_name, method_name)

        Type::Combinator.untyped
      end

      # Resolves the `(class_name, kind)` pair scope_indexer keys its `discovered_methods` table
      # on. `Nominal[X]` looks up instance methods on X; `Singleton[X]` looks up singleton
      # methods on X. Other carriers return `[nil, nil]` so the tier declines.
      def discovered_method_lookup(receiver_type)
        # #525 — the ADR-48 member carriers name their class too: a `Line = Struct.new(...) do ... end`
        # value is a StructInstance whose block-def methods are discovered under "Line".
        case receiver_type
        when Type::Nominal, Type::StructInstance, Type::DataInstance
          [receiver_type.class_name, :instance]
        when Type::Singleton, Type::StructClass, Type::DataClass
          [receiver_type.class_name, :singleton]
        else NO_DISCOVERED_LOOKUP
        end
      end

      # The shared "no discovered-method key" pair; callers destructure it (#775).
      NO_DISCOVERED_LOOKUP = [nil, nil].freeze
      private_constant :NO_DISCOVERED_LOOKUP

      # Issue #963 item 2 — the MEMBERSHIP half of the two plugin tiers, for #618's own-method veto.
      #
      # `ExpressionTyper#try_local_def_dispatch` has to decide whether the call's own `self` answers the
      # name before a same-named top-level `def` may bind, and a plugin-supplied member is an answer Ruby
      # really dispatches to: a model's column reader, an association, a scope, a macro-synthesised
      # reader. The veto asked neither tier, so a top-level `def name` bound ahead of the member and
      # typed the read as the def's `nil` — #618's false positive at a source the veto could not see.
      #
      # The question is asked HERE, of the same two tiers `resolve` consults and in the same order, rather
      # than reconstructed in the veto: a name this reports as answered is a name the dispatch really would
      # resolve, and no plugin knowledge moves into the engine's veto. The tiers are the gated
      # `dynamic_return` walk and the ADR-16 synthetic-method index (Tier C `heredoc_templates` emissions and
      # the Tier B `Plugin::Macro::TraitRegistry` explosions, which share that table; since #476 the pre-pass
      # explodes a trait module whenever the project's RBS declares it).
      #
      # It is a predicate, not a type: the veto's job is to stop the top-level bind, after which the call
      # falls through to the ordinary dispatch chain and the tier that answered here answers there too. The
      # walk is not on the hot path — it runs only once `Scope#bindable_top_level_def_for` has already
      # produced a candidate, which needs a project top-level `def` of the same name.
      def plugin_member_answers?(call_node:, scope:, receiver_type:, method_name:)
        return false if receiver_type.nil?
        return true unless PluginContribution.merged_return_type(call_node, scope, receiver_type).nil?

        SyntheticMethodDispatch.synthetic_method_member?(receiver_type, method_name, scope&.environment)
      end

      # ADR-10 slice 5c — record a `dynamic.dependency-source.boundary-cross` event when RBS
      # dispatch resolves a call AND the receiver class belongs to a `mode: :full` opt-in gem
      # whose Walker also catalogued the same `(class_name, method_name)`. The dispatcher still
      # returns the RBS answer (per ADR-10's tier order: authoritative-source wins), but the
      # reporter accumulates the crossing for end-of-run audit diagnostics.
      #
      # Five honest fall-throughs keep the gate narrow:
      #
      # - environment / index / reporter missing — slice 5c needs all three.
      # - receiver has no nominal class name (Dynamic-only carriers) — nothing to look up.
      # - receiver class doesn't belong to a `mode: :full` gem — the user didn't opt this gem
      #   into the distinct dispatch path.
      # - the gem-source catalog has no entry for the method — only RBS knows about it; nothing
      #   to cross.
      # - the RBS-side result is itself `Dynamic[Top]` — the "agreement" is trivially `untyped ≈
      #   untyped`, no meaningful divergence to flag.
      def record_boundary_cross_if_applicable(receiver_type, method_name, rbs_result, environment)
        class_name = boundary_cross_class_name(receiver_type, environment, rbs_result)
        return if class_name.nil?

        index = environment.dependency_source_index
        return unless index.full_mode?(class_name)
        return unless index.contribution_for(class_name: class_name, method_name: method_name)

        environment.boundary_cross_reporter.record(
          class_name: class_name, method_name: method_name,
          gem_name: index.gem_for(class_name),
          rbs_display: rbs_display_for(rbs_result)
        )
      end

      # Composite preflight for {#record_boundary_cross_if_applicable}. Returns the receiver
      # class name only when every prerequisite for emitting the diagnostic is satisfied
      # (environment carries an index + reporter, receiver is a nominal carrier, RBS-side result
      # is not the trivial `Dynamic[Top]` envelope). Returns `nil` to short-circuit otherwise.
      def boundary_cross_class_name(receiver_type, environment, rbs_result)
        return nil if environment.nil?
        return nil if environment.dependency_source_index.nil?
        return nil if environment.dependency_source_index.empty?
        return nil if environment.boundary_cross_reporter.nil?
        return nil if rbs_result_untyped?(rbs_result)

        DependencySource.dep_source_class_name(receiver_type)
      end

      def rbs_result_untyped?(rbs_result)
        Type::Combinator.untyped?(rbs_result)
      end

      def rbs_display_for(rbs_result)
        return "untyped" if rbs_result.nil?

        rbs_result.respond_to?(:describe) ? rbs_result.describe : rbs_result.inspect
      end

      # The tiers `resolve` asks through an array outside the precise band, each where its comment in `resolve`
      # says. A tier is in an array when nothing in `resolve` follows its answer; one whose answer `resolve`
      # follows with a record on the scope or the reporter stays a call there.
      BUNDLED_OVERRIDE_TIERS = Ractor.make_shareable([HktBuiltinReturn, StaticRefinement].freeze)
      private_constant :BUNDLED_OVERRIDE_TIERS

      SYNTHETIC_TIERS = Ractor.make_shareable([SyntheticMethodDispatch].freeze)
      private_constant :SYNTHETIC_TIERS

      STUB_TIERS = Ractor.make_shareable([SynthesizedStub].freeze)
      private_constant :STUB_TIERS

      # Asks the tiers of one array in order and answers the first answer, or nil when every tier declines.
      #
      # The walk is a `while` loop on purpose. On Ruby 4.0.5 a `return` out of an `each` block allocates one object
      # for every call that answers (a call that declines allocates none), so `tiers.each { |tier| ... return result }`
      # cost an object per dispatch a tier array answered: 171,897 in one `rigor check lib` while the four arrays were
      # walked that way (#3345). Keep the index walk; an `each`, a `find` or an `each_with_index` brings them back.
      def first_tier_answer(tiers, context)
        index = 0
        count = tiers.size
        while index < count
          result = tiers[index].try_dispatch(context)
          return result if result

          index += 1
        end
        nil
      end

      # Runs the precision tiers in order and returns the first non-nil answer. Each tier owns its own receiver/argument
      # shape checks; a tier that does not recognise the receiver returns nil so the next tier
      # can try. The RBS tier sits below this chain and is invoked by `resolve`.
      #
      # The precise-tier folders, consulted in order via the uniform `_DispatchTier` interface
      # (`try_dispatch(CallContext) -> Type?`). Order is significant: MetaIntrospection answers `class` and
      # `new` first, behind the `Data` and `Struct` value tiers that `dispatch_precise_tiers` asks ahead of
      # this array; ConstantFolding's exact-value folds win next, the stdlib singleton folders sit in the middle (each
      # gates on a distinct `Singleton` receiver, so their relative order is immaterial), and
      # BlockFolding runs near the end because its rules only apply to block-taking calls — the cheaper
      # arity folds above it filter the common cases first. Adding a precise tier is a one-line
      # append here rather than another link in a hand-written `||` ladder.
      PRECISE_TIERS_HEAD = Ractor.make_shareable([
        MetaIntrospection, ConstantFolding, LiteralStringFolding, ShapeDispatch
      ].freeze)
      private_constant :PRECISE_TIERS_HEAD

      # ADR-53 re-review follow-up (gate-by-held-key applied to the built-in tiers): the stdlib
      # singleton folders are mutually exclusive — each fires only on `Singleton[<its
      # class>]`, the first check in every `try_dispatch` — so at most one can match a given
      # receiver and their relative trial order was never observable. Compiling them into a
      # class-name table turns a no-op trial per folder into one Hash read, skipped entirely
      # when the receiver is not a `Singleton` (the overwhelmingly common case). The table sits
      # after ShapeDispatch, before KernelDispatch.
      STDLIB_SINGLETON_FOLDERS = Ractor.make_shareable({
        "File" => FileFolding,
        "Shellwords" => ShellwordsFolding,
        "Math" => MathFolding,
        "Random" => RandomFolding,
        "Time" => TimeFolding,
        "Regexp" => RegexpFolding,
        "Process" => ProcessFolding,
        "CGI" => CGIFolding,
        "URI" => URIFolding,
        "Set" => SetFolding,
        "JSON" => JSONFolding
      }.freeze)
      private_constant :STDLIB_SINGLETON_FOLDERS

      PRECISE_TIERS_TAIL = Ractor.make_shareable([
        MethodFolding, ReduceFolding, ArrayToHFolding, HashTransformKeysFolding, BlockFolding,
        ArithmeticSequenceElements
      ].freeze)
      private_constant :PRECISE_TIERS_TAIL

      def dispatch_precise_tiers(context)
        # ADR-48 — Data value folding runs ahead of meta-introspection: `meta_new` intercepts
        # every `Singleton[*].new` (returning `Nominal`), which would mask a `Data` class's
        # precise instance. The tier only fires on Data receivers (a `Data.define`, a
        # `DataClass`/`DataInstance`, or a `Singleton` with a recorded member layout), so it
        # never shadows meta's Array/Set/Range lifts.
        data_result = DataFolding.try_dispatch(context)
        return data_result if data_result

        # ADR-48 Struct follow-up — runs in the same band and for the same reason as DataFolding:
        # `meta_new` would otherwise intercept every `Singleton[*].new` (the old
        # `struct_new_lift` produced a bare `Singleton[Struct]`), masking a Struct class's
        # precise instance. Only fires on Struct receivers, so it never shadows meta's lifts.
        struct_result = StructFolding.try_dispatch(context)
        return struct_result if struct_result

        head_result = first_tier_answer(PRECISE_TIERS_HEAD, context)
        return head_result if head_result

        folder_result = dispatch_receiver_keyed_folder(context)
        return folder_result if folder_result

        kernel_result = dispatch_kernel_intrinsic(context)
        return kernel_result if kernel_result

        first_tier_answer(PRECISE_TIERS_TAIL, context)
      end

      # The folders the receiver's class selects, at most one per call: a stdlib singleton folder, or for a
      # `MatchData` receiver the slice fold of the proven `$~` (issue #1381). Every other receiver skips them without
      # a trial.
      def dispatch_receiver_keyed_folder(context)
        receiver = context.receiver
        folder =
          case receiver
          when Type::Singleton then STDLIB_SINGLETON_FOLDERS[receiver.class_name]
          when Type::Nominal then MatchDataFolding if receiver.class_name == "MatchData"
          end
        folder&.try_dispatch(context)
      end

      # ADR-91 WD1 — the single dispatcher-held ownership gate for the Kernel module-function surface
      # (gate-by-held-key, the same move STDLIB_SINGLETON_FOLDERS made above). The tier runs only when
      # the method name is in the compiled `INTRINSIC_NAMES` table AND the call is attributable to
      # Kernel itself (implicit self / `Kernel.` receiver, no discovered user redefinition). Because the
      # gate lives HERE and nowhere else, a fold inside KernelDispatch that "forgets" its ownership
      # guard is unrepresentable — the whole tier is unreachable for a foreign receiver. Unit probes
      # calling `KernelDispatch.try_dispatch` directly keep the caller-vouches-for-ownership contract.
      def dispatch_kernel_intrinsic(context)
        return nil unless KernelDispatch::INTRINSIC_NAMES.include?(context.method_name)
        return nil unless KernelDispatch.kernel_owned_call?(context)

        KernelDispatch.try_dispatch(context)
      end

      def try_user_class_fallback(receiver_type, environment, call_node, context)
        return nil if environment.nil?

        fallback_receiver = user_class_fallback_receiver(receiver_type, environment)
        return nil if fallback_receiver.nil?
        return nil if declared_by_external_ancestor?(receiver_type, environment, context)
        return nil if project_singleton_definer?(receiver_type, context)

        # Preserve the ORIGINAL receiver type as the `self` substitution so `Kernel#dup: () ->
        # self` and other `self`-returning methods route through Object's RBS while still
        # returning the caller's type rather than `Object`. Without this, `base = self.dup`
        # inside a `Bundler::URI::Generic` instance method types `base` as `Object` because
        # `Bundler::URI::Generic` is not in RBS and the fallback's `self` resolves to Object.
        #
        # `public_only:` — when the call has an EXPLICIT, non-`self` receiver
        # (`Favourite.select(...)`), suppress the private `Object`/`Kernel`/`Class` methods the
        # fallback would otherwise resolve. Ruby raises `NoMethodError` for a private method
        # called with an explicit receiver, so resolving `Favourite.select` to the private
        # `Kernel#select` (`-> Array[String]`) is a confidently-wrong type. Implicit-self /
        # `self.`-receiver calls (`puts`, `raise`, `require`) keep resolving — those are the
        # fallback's intended targets.
        RbsDispatch.try_dispatch(
          context.with(
            receiver: fallback_receiver,
            self_type_override: receiver_type,
            public_only: ProjectPatched.explicit_non_self_receiver?(call_node),
            call_node: nil, scope: nil
          )
        )
      end

      # Issue #2196 — a project class whose ancestry reaches a core or stdlib class before `Object` (`class FL <
      # Array`) answers a name that class declares from that class, not from `Object` / `Kernel`: Ruby dispatches
      # `select { … }` on an `FL` to `Array#select`, never to the private `Kernel#select` (`-> Array[String]`). The
      # ancestor tiers decline such a name where they cannot type it (`RbsDispatch#returns_the_walked_ancestry?`),
      # and the `Object` fallback then fabricated `Kernel#select`'s answer, so `fields.detect { |f| f.errors }` read
      # `f` as `String`. The fallback declines the name instead, which leaves the call `Dynamic[top]`.
      # {ExternalAncestorResolution.resolve} answers nil for a name only `Object`, `Kernel` or `BasicObject` declares,
      # so `puts` and `raise` keep resolving.
      def declared_by_external_ancestor?(receiver_type, environment, context)
        return false unless receiver_type.is_a?(Type::Nominal)

        scope = context.scope
        return false if scope.nil?

        class_name = receiver_type.class_name
        method_name = context.method_name
        if MemoAudit.enabled? && MemoAudit.suspended?
          return external_ancestor_declares?(class_name, method_name, scope,
                                             environment)
        end

        memo = external_ancestor_memo(scope, environment)
        key = [class_name, method_name]
        if memo.key?(key)
          return MemoAudit.check("user class fallback external ancestor", memo[key], class_name, method_name) do
            external_ancestor_declares?(class_name, method_name, scope, environment)
          end
        end

        memo[key] = MemoAudit.key_audit("user class fallback external ancestor") do
          external_ancestor_declares?(class_name, method_name, scope, environment)
        end
      end

      def external_ancestor_declares?(class_name, method_name, scope, environment)
        !ExternalAncestorResolution.resolve(class_name, method_name, :instance,
                                            scope: scope, environment: environment, record_dependencies: false).nil?
      end

      # Issue #2284 — a class object whose singleton chain holds a project definer of the name (its own `def
      # self.name`, one a project superclass wrote, an `extend`ed module's `def name`) answers from that definer,
      # not from `Module#name` / `Class#…` on the `Singleton[Object]` fallback: Ruby's singleton ancestry puts
      # every project entry ahead of `Class`. The fallback declines so the typer's singleton-body inference
      # answers the definer's return, or `Dynamic` where the slot is contested and the def may not be the one
      # that runs.
      #
      # The chain walk files the class edge of every entry it passes, so it runs only for a name some project file
      # defines at all ({BlockCallTiming.project_defines_anywhere?}, which files the `defines:<name>` edge either way,
      # #1459). Without it every class-body `private` / `attr_reader` call on a project class would depend on its
      # whole ancestry. The by-name answer is memoised per discovery index; the edge is filed on every call.
      def project_singleton_definer?(receiver_type, context)
        return false unless receiver_type.is_a?(Type::Singleton)

        scope = context.scope
        return false if scope.nil?
        return false unless project_defines_name?(scope, context.method_name)

        !scope.singleton_def_through_ancestors(receiver_type.class_name, context.method_name).last.nil?
      end

      def project_defines_name?(scope, method_name)
        if MemoAudit.enabled? && MemoAudit.suspended?
          return BlockCallTiming.project_defines_anywhere?(method_name,
                                                           scope)
        end

        memo = defines_name_memo(scope)
        if memo.key?(method_name)
          Analysis::DependencyRecorder.read_missing(:defines, method_name) if Analysis::DependencyRecorder.active?
          return MemoAudit.check("user class fallback defines name", memo[method_name], method_name) do
            BlockCallTiming.project_defines_anywhere?(method_name, scope)
          end
        end

        memo[method_name] = MemoAudit.key_audit("user class fallback defines name") do
          BlockCallTiming.project_defines_anywhere?(method_name, scope)
        end
      end

      # ADR-129 WD1 — a run-scoped Memo: one slot keyed on the identity of the discovery index and the environment,
      # the only inputs the name table's answers read.
      DEFINES_NAME_MEMO = TypingState.memo(
        :user_class_fallback_defines_name,
        run_scoped: true, audit: "user class fallback defines name",
        reason: "one [discovery, environment, names] slot keyed on the identities of the discovery " \
                "index and the environment; each name's answer reads only them"
      )
      private_constant :DEFINES_NAME_MEMO

      # One slot per discovery index and environment, as {#external_ancestor_memo} keeps its own: the answer reads
      # only the frozen discovery tables and the environment's `pre_eval:` patches.
      def defines_name_memo(scope)
        discovery = scope.discovery
        environment = scope.environment
        state = TypingState.current
        slot = state[DEFINES_NAME_MEMO]
        unless slot && slot[0].equal?(discovery) && slot[1].equal?(environment)
          slot = [discovery, environment, {}]
          state[DEFINES_NAME_MEMO] = slot
        end
        slot[2]
      end

      # ADR-129 WD1 — a run-scoped Memo, keyed as {DEFINES_NAME_MEMO} is.
      EXTERNAL_ANCESTOR_MEMO = TypingState.memo(
        :user_class_fallback_external_ancestor,
        run_scoped: true, audit: "user class fallback external ancestor",
        reason: "one [discovery, environment, answers] slot keyed on the identities of the " \
                "discovery index and the RBS environment, the only inputs the walk reads"
      )
      private_constant :EXTERNAL_ANCESTOR_MEMO

      # One slot per discovery index and environment, as `RbsDispatch#ancestor_memo_slot` keeps its own: the answer
      # reads only the frozen discovery tables and the RBS environment, and its walk is withheld from dependency
      # recording, so it may be served again for the same pair.
      def external_ancestor_memo(scope, environment)
        discovery = scope.discovery
        state = TypingState.current
        slot = state[EXTERNAL_ANCESTOR_MEMO]
        unless slot && slot[0].equal?(discovery) && slot[1].equal?(environment)
          slot = [discovery, environment, {}]
          state[EXTERNAL_ANCESTOR_MEMO] = slot
        end
        slot[2]
      end

      def user_class_fallback_receiver(receiver_type, environment)
        case receiver_type
        when Type::Nominal
          # Modules: even when RBS knows the module, an instance method on a mixin-only module
          # (e.g. `PP::ObjectMixin`) observes Kernel / Object methods through every concrete
          # includer's ancestor chain. Route through the `Nominal[Object]` fallback so
          # `self.inspect` / `self.respond_to?` / `self.class` resolve cleanly when the module
          # itself does not declare them.
          known = Rigor::Reflection.rbs_class_known?(receiver_type.class_name, environment: environment)
          return environment.nominal_for_name("Object") if !known || environment.rbs_module?(receiver_type.class_name)

          nil
        when Type::Singleton
          return nil if Rigor::Reflection.rbs_class_known?(receiver_type.class_name, environment: environment)

          environment.singleton_for_name("Class")
        end
      end

      # Issue #1101 — the composite-receiver projection tier, the LAST thing `resolve` tries.
      #
      # Every tier above needs a receiver it can *name*: `receiver_descriptor`, the discovered-method
      # lookup, the dependency-source and synthesized-stub tiers and the user-class fallback all switch
      # on `Nominal` / `Singleton` / a member carrier. A `Union` or a `Difference` is none of those, so a
      # composite receiver whose members would each resolve perfectly well still fell through the whole
      # chain and landed `Dynamic[top]`.
      #
      # `RbsDispatch` already distributes over a `Union` (and erases a `Difference` to its base, #533),
      # but it does so INSIDE one tier, so a member that needs a LOWER tier — a user class with no RBS,
      # a discovered `def`, an opt-in gem — makes the whole union decline. That was the corpus shape before
      # #2430: rigor-actionpack typed `params[:k]` as the bare `ActionController::Parameters | nil` union, the
      # `Parameters` arm resolved only through the user-class fallback, and so `params[:k].present?` / `#==`
      # / `#blank?` / `#to_s` read opaque on every Rails app. Measured by toggling this file alone: the
      # named-pair census drained 137 sites on redmine and 56 on mastodon, and `rigor check` reported the
      # same diagnostics on both arms across eight survey targets. The plugin now answers a `Dynamic`
      # carrier, which this projection does not reach, so those off-chain calls read `Dynamic[top]` until
      # the carrier is projected here too (#2448).
      #
      # **Why the bottom and not next to `RbsDispatch`.** Sitting here, the tier can only ever replace a
      # `Dynamic[top]` the typer was about to produce — the same ADR-5 argument {UniversalObjectDispatch}
      # makes. Hoisting the projection above `RbsDispatch` would change answers that resolve today, which
      # is a different change with a different measurement.
      #
      # **The projection rule** (`receiver_projection` below; the normative statement lives in
      # [`inference-engine.md`](docs/internal-spec/inference-engine.md) § "Composite receivers"):
      #
      # - `Union[A, B, …]` projects to its members. Each is dispatched through this same chain and the
      #   results are unioned; if ANY member declines, the whole tier declines. Never a partial answer —
      #   a union whose members disagree about whether the method exists is exactly the case where an
      #   answer would be a guess.
      # - `Difference[base, nil]` projects to `base` with its nil-valued members removed. Removing `nil`
      #   from a receiver cannot change method resolution at all: `NilClass` is nobody's ancestor, so
      #   every remaining inhabitant looks a method up exactly as a plain `base` inhabitant does, and the
      #   carrier is value-set-equal to the projection. This is `T.must(x)` (rigor-sorbet's
      #   `strip_nil`), which builds `Difference[inferred(x), Constant[nil]]` — over a `T?` local that
      #   base IS a union, which is why the two arms compose rather than being separate features.
      # - Any other `Difference` DECLINES. `A − B` for a real `B` is a claim about which inhabitants
      #   survive, and the projection has nowhere to put it: dispatching on `A` re-admits exactly the
      #   overrides `B` contributed, and over a union base (`(String | Integer) − Integer` is Strings
      #   only) it re-admits a member the difference eliminated and unions in its answer — a WIDER type
      #   than today's decline, on a shape no corpus target produces. Subtracting a class from a union
      #   needs an algebra the `Difference` carrier does not have (it removes a value set, not a member),
      #   so the honest answer is to keep declining until something demands it. `RbsDispatch`'s #533
      #   erasure is untouched and still answers these for an RBS-known base.
      #
      # `self` binds to the PROJECTED receiver, not to the composite: the projection is the exact set of
      # inhabitants that can reach the method, so a `-> self` method (`dup`, `itself`, `tap`) answers per
      # member and the union reassembles them — `(String | Symbol)#itself` is `String | Symbol`. Nothing is
      # lost on the `Difference` arm because the projection is value-set-equal to the carrier there. This
      # falls out of re-entering `resolve` rather than needing a `self_type_override`.
      def try_composite_receiver(context)
        members = receiver_projection(context.receiver)
        return nil if members.nil? || members.size > COMPOSITE_PROJECTION_MEMBERS

        plugin_typed = []
        results = members.map do |member|
          resolve(
            receiver_type: member, method_name: context.method_name, arg_types: context.args,
            block_type: context.block_type, environment: context.environment,
            call_node: context.call_node, scope: context.scope, plugin_typed_sink: plugin_typed
          )
        end
        return nil if results.any?(&:nil?)

        plugin_typed.uniq.each { |node| context.scope&.record_plugin_typed_call(node) }
        Type::Combinator.union(*results)
      end

      # An upper bound on the fan-out, because this tier re-runs the FULL dispatch chain per member.
      # Real unions are two or three members wide; a receiver wider than this is a join the engine has
      # already lost precision on, and paying N chain walks to union N answers is not worth it.
      COMPOSITE_PROJECTION_MEMBERS = 8
      private_constant :COMPOSITE_PROJECTION_MEMBERS

      # The receivers each member of a composite carrier is dispatched as, or nil when the carrier is not
      # projectable. Every member returned MUST itself be non-composite: that is what bounds the re-entry
      # into `resolve` at one level, by construction rather than by a counter — the nested call reaches
      # this tier with a receiver it declines immediately. A normalized `Union` never holds a `Union`, so
      # the shapes the guard turns away are a `Difference` over a `Difference` (`T.must(T.must(x))`) and a
      # `Union` holding one (`c ? T.must(y) : Bar.new`, which normalizes to `(A - nil) | Bar`). Both
      # decline exactly as they did before this tier existed; neither appears in the survey corpus.
      def receiver_projection(receiver)
        members =
          case receiver
          when Type::Union then receiver.members
          when Type::Difference then difference_projection(receiver)
          end
        return nil if members.nil? || members.empty?
        return nil if members.any? { |member| member.is_a?(Type::Union) || member.is_a?(Type::Difference) }

        members
      end

      # `Difference[base, nil]` projects to `base` minus its nil-valued members; every other difference
      # declines. The nil filter runs over a scalar base as well as a union one, so the rule stays total:
      # `Combinator.difference` does not normalize `NilClass - nil` (or `nil - nil`) to `Bot`, and this
      # tier must not project `[NilClass]` and answer a NilClass method for a carrier with no inhabitant.
      # Nothing observable turns on it today — `RbsDispatch`'s #533 erasure sits above this tier and
      # already answers a nil-only base from the base's own descriptor — which is why the guard is here
      # rather than in `Combinator`, where it would be a normalization change with its own blast radius.
      def difference_projection(difference)
        return nil unless nil_valued_type?(difference.removed)

        base = difference.base
        members = base.is_a?(Type::Union) ? base.members : [base]
        retained = members.reject { |member| nil_valued_type?(member) }
        return nil if retained.empty?

        retained
      end

      # `nil` as either carrier spells it: the value-pinned `Constant[nil]` the engine normally produces,
      # and the `Nominal[NilClass]` a widened or RBS-sourced position carries.
      def nil_valued_type?(type)
        (type.is_a?(Type::Constant) && type.value.nil?) ||
          (type.is_a?(Type::Nominal) && type.class_name == "NilClass")
      end

      # Returns the positional block parameter types declared by the receiving method's selected
      # RBS overload, translated into `Rigor::Type`. Used by the StatementEvaluator's CallNode
      # handler to bind block parameter names before evaluating the block body.
      #
      # The probe is best-effort: it returns an empty array whenever the receiver, environment,
      # method definition, or selected overload does not provide statically declared block
      # parameter types. Callers MUST treat the empty array as "no information"; the binder
      # falls back to `Dynamic[Top]` for every parameter slot in that case.
      #
      # `call_node` lets the overload selector read the call's keyword arguments as keywords (#1727, #1737), as
      # the return path does; without it they are read positionally.
      def expected_block_param_types(receiver_type:, method_name:, arg_types:, environment: nil,
                                     scope: nil, call_node: nil)
        return [] if receiver_type.nil?

        context = CallContext.build(
          receiver: receiver_type, method_name: method_name,
          args: arg_types, environment: environment, scope: scope, call_node: call_node
        )
        iterator_result = IteratorDispatch.block_param_types(context)
        return iterator_result if iterator_result

        RbsDispatch.block_param_types(context)
      end
    end
  end
end
