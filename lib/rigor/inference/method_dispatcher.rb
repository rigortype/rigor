# frozen_string_literal: true

require_relative "../reflection"
require_relative "../type"
require_relative "../flow_contribution"
require_relative "../flow_contribution/merger"
require_relative "../builtins/hkt_builtins"
require_relative "../builtins/static_return_refinements"
require_relative "anonymous_meta_class"
require_relative "dynamic_origin"
require_relative "flow_tracer"
require_relative "void_tail_summary"
require_relative "method_dispatcher/call_context"
require_relative "method_dispatcher/constant_folding"
require_relative "method_dispatcher/literal_string_folding"
require_relative "method_dispatcher/shape_dispatch"
require_relative "method_dispatcher/data_folding"
require_relative "method_dispatcher/struct_folding"
require_relative "method_dispatcher/rbs_dispatch"
require_relative "method_dispatcher/iterator_dispatch"
require_relative "method_dispatcher/reduce_folding"
require_relative "method_dispatcher/block_folding"
require_relative "method_dispatcher/array_to_h_folding"
require_relative "method_dispatcher/file_folding"
require_relative "method_dispatcher/shellwords_folding"
require_relative "method_dispatcher/math_folding"
require_relative "method_dispatcher/time_folding"
require_relative "method_dispatcher/regexp_folding"
require_relative "method_dispatcher/cgi_folding"
require_relative "method_dispatcher/uri_folding"
require_relative "method_dispatcher/set_folding"
require_relative "method_dispatcher/json_folding"
require_relative "method_dispatcher/kernel_dispatch"
require_relative "method_dispatcher/universal_object_dispatch"
require_relative "method_dispatcher/singleton_mixin_dispatch"
require_relative "method_dispatcher/method_folding"

module Rigor
  module Inference
    # Coordinates method dispatch for the inference engine.
    #
    # Given `(receiver_type, method_name, arg_types, block_type, environment)`, the dispatcher
    # returns the inferred result type or `nil` when no rule matches. `nil` is a deliberately
    # blunt "I don't know" signal: callers (today only `ExpressionTyper`) own the fail-soft
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

      # @param receiver_type [Rigor::Type, nil] type of the receiver expression, or
      #   `nil` for an implicit-self call.
      # @param method_name [Symbol]
      # @param arg_types [Array<Rigor::Type>] positional argument types.
      # @param block_type [Rigor::Type, nil] inferred return type of the
      #   accompanying `do ... end` / `{ ... }` block (Slice 6 phase C
      #   sub-phase 2). When non-nil, the dispatcher prefers an
      #   overload that declares a block, and binds the method's
      #   block-return type variable to `block_type` so a return type
      #   like `Array[U]` resolves to `Array[block_type]`.
      # @param environment [Rigor::Environment, nil] required for
      #   RBS-backed dispatch; when nil only constant folding can fire.
      # @return [Rigor::Type, nil] inferred result type, or `nil` for "no rule".
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

      def resolve(receiver_type:, method_name:, arg_types:, # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
                  block_type: nil, environment: nil,
                  call_node: nil, scope: nil)
        return nil if receiver_type.nil?

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

        # v0.1.1 Track 2 slice 7 — plugin return-type contribution tier. Sits ahead of
        # `RbsDispatch` so a plugin that understands a domain-specific dispatch (e.g. an
        # `ActiveRecord::Base.find` returning `Nominal[<resolved model>]`) wins over the
        # RBS-projected envelope. Only consults the registry when both `call_node` and `scope`
        # are supplied — the dispatcher's own internal callers (per-element block fold, etc.)
        # skip this tier.
        plugin_result = try_plugin_contribution(call_node, scope, receiver_type)
        if plugin_result
          # Issue #653 — this tier answering is what makes the site's type the plugin's rather than the
          # RBS's, and `call.undefined-method` reads that record instead of re-deciding from the receiver's
          # (possibly partial) signature. Recorded for EVERY plugin answer, dynamic or precise: the
          # incoherence the record closes is about which subsystem typed the call, not about the type.
          scope&.record_plugin_typed_call(call_node)
          if plugin_result.is_a?(Type::Dynamic)
            scope&.record_dynamic_origin(call_node, DynamicOrigin::FRAMEWORK_DSL_BOUNDARY)
          end
          return plugin_result
        end

        # ADR-20 slice 3 — Rigor-bundled HKT-builtin return-type tier. Sits ABOVE
        # `RbsDispatch.try_dispatch` so the handful of stdlib methods whose upstream RBS
        # signature is `untyped` but whose runtime shape Rigor models via a Lightweight HKT
        # (`json::value`, eventually `dry_monads::result`, …) get the reduced type instead of
        # `Dynamic[Top]`. The table that populates this tier lives in
        # `Rigor::Builtins::HktBuiltins::METHOD_RETURN_OVERRIDES`; plugin-supplied per-method
        # overrides are out of scope for slice 3 and continue to flow through the
        # `try_plugin_contribution` tier above.
        hkt_builtin_result = try_hkt_builtin_return(receiver_type, method_name, arg_types, environment)
        return hkt_builtin_result if hkt_builtin_result

        # Rigor-bundled static refinement tier. Sits between HKT and RBS so stdlib methods whose
        # upstream RBS is broader than the documented behaviour (e.g. `Kernel#__dir__` declared
        # `() -> String?` when the documented return is `non-empty-string | nil`) get the
        # tightened type without modifying the vendored `ruby/rbs` submodule. The override table
        # lives in `Rigor::Builtins::StaticReturnRefinements::OVERRIDES`.
        static_refinement = try_static_refinement(receiver_type, method_name, arg_types)
        return static_refinement if static_refinement

        # `Foo.instance` for a class that includes the stdlib `Singleton` mixin. Ruby grows that method through
        # an `included` hook and the upstream RBS leaves `Singleton::SingletonClassMethods` empty, so nothing
        # below can answer it. See {SingletonMixinDispatch} for why the value matters more than the site count.
        singleton_mixin = SingletonMixinDispatch.try_dispatch(context)
        return singleton_mixin if singleton_mixin

        rbs_result = RbsDispatch.try_dispatch(context)
        if rbs_result
          record_boundary_cross_if_applicable(receiver_type, method_name, rbs_result, environment)
          if rbs_result.is_a?(Type::Dynamic) && rbs_result.static_facet.is_a?(Type::Top)
            scope&.record_dynamic_origin(call_node, DynamicOrigin::EXPLICIT_UNTYPED)
          end
          return rbs_result
        end

        # ADR-16 Tier B / Tier C — synthetic-method tier. Sits BELOW RBS dispatch (per WD13:
        # user-authored RBS overrides substrate synthesis) and ABOVE the dependency-source
        # inference tier so a plugin's declared emit table beats the generic gem-source fallback
        # for the same class. Slice 6a-TierB (origin_module dispatch) lands precise return types
        # for Tier B emissions; Tier C emissions still return `Dynamic[T]` at this tier (slice 6b
        # is the Tier C promotion via ADR-13's resolver chain).
        synthetic_result = try_synthetic_method(
          receiver_type, method_name, arg_types, block_type, environment
        )
        return synthetic_result if synthetic_result

        # ADR-17 slice 2 — project-side patched-method tier. Sits BELOW the substrate / plugin
        # tiers and ABOVE dependency-source inference per ADR-17 § "Inference contract". When
        # the user's `pre_eval:` list named a file that re-opens a class (e.g.,
        # `lib/core_ext/string_extensions.rb` declaring `class String; def to_url; end; end`),
        # the pre-pass populated `ProjectPatchedMethods` with the `(class, method, kind)` triple;
        # this tier surfaces it as `Dynamic[top]` so the patched call resolves cross-file without
        # `call.undefined-method`.
        patched_result = try_project_patched_method(receiver_type, method_name, environment)
        if patched_result
          scope&.record_dynamic_origin(call_node, DynamicOrigin::EXTERNAL_GEM_WITHOUT_RBS)
          return patched_result
        end

        # ADR-10 slice 2b-ii — dependency-source inference tier. Sits BELOW RBS dispatch (RBS /
        # RBS::Inline / generated stubs / plugin contracts always win) and ABOVE the user-class
        # fallback so a method defined in an opt-in gem stops emitting `call.undefined-method`
        # even when no signature contract resolves. Returns `Dynamic[top]` — slice 2b-ii
        # deliberately stops at the dynamic-origin envelope; per-method return-type precision is
        # queued for a later slice.
        dep_source_result = try_dependency_source(receiver_type, method_name, environment)
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

        # ADR-5 robustness — synthesized-stub-type tier. When the receiver is a type Rigor
        # invented to make an otherwise-unbuildable project signature resolve (a
        # missing-namespace module, or a stub for a referenced-but-undeclared type like an
        # unavailable `DRb::DRbServer`), the stub carries no methods, so an unresolved call
        # against it would otherwise mis-fire `call.undefined-method`. Resolve it to
        # `Dynamic[Top]` instead — the same no-false-positive contract as the dependency-source
        # tier. Sits below every real resolution tier so a genuine signature always wins.
        stub_result = try_synthesized_stub_type(receiver_type, environment)
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
        fallback_result
      end

      # ADR-100 WD4 — records the transitive `-> void` provenance when the called method is a
      # discovered project `def` whose {VoidTailSummary} chain ends in an author-declared `-> void`
      # leaf on the same owner. Guards cheapest-first: the internal dispatcher callers nil `scope` /
      # `call_node` out; the receiver must project through {#discovered_method_lookup}
      # (`Nominal` / `Singleton` only — unions and `Dynamic` receivers stay out); and the
      # `discovered_method?` pre-filter (two pure hash reads) keeps the hot path at ~zero cost —
      # only a call that provably targets a discovered def of the right kind resolves the node and
      # consults the summary. The `Prism::CallNode` guard mirrors `collect_plugin_contributions`:
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
        else [nil, nil]
        end
      end

      # ADR-5 robustness — returns `Dynamic[Top]` when the receiver is an instance or singleton
      # of a type Rigor synthesized (a missing-namespace module or a referenced-type stub). The
      # stub has no methods, so the call would otherwise reach the user-class fallback and
      # surface `call.undefined-method`; the honest answer for a type Rigor invented is "unknown
      # shape", i.e. `Dynamic[Top]`. Returns nil (declines) for any real type.
      def try_synthesized_stub_type(receiver_type, environment)
        return nil if environment.nil?

        loader = environment.rbs_loader
        return nil if loader.nil? || !loader.respond_to?(:synthesized_type_names)

        names = loader.synthesized_type_names
        return nil if names.empty?

        class_name =
          case receiver_type
          when Type::Nominal, Type::Singleton then receiver_type.class_name.to_s.sub(/\A::/, "")
          end
        return nil unless class_name && names.include?(class_name)

        Type::Combinator.untyped
      end

      # ADR-20 slice 3 — looks up the receiver / method pair in
      # {Rigor::Builtins::HktBuiltins::METHOD_RETURN_OVERRIDES} and returns the reduced HKT type.
      # Only fires when the receiver is a {Rigor::Type::Singleton} (the `JSON.parse` shape) and
      # the registry-backed reduction succeeds; returns `nil` otherwise so the dispatcher falls
      # through to RBS.
      def try_hkt_builtin_return(receiver_type, method_name, arg_types, environment)
        return nil if environment.nil?
        return nil unless receiver_type.is_a?(Type::Singleton)

        Rigor::Builtins::HktBuiltins.method_return_override(
          class_name: receiver_type.class_name,
          method_name: method_name,
          kind: :singleton,
          arg_types: arg_types,
          hkt_registry: environment.hkt_registry
        )
      end

      # Consults the Rigor-bundled static refinement table for a (owner-class, method-name,
      # kind) entry. Kernel methods are mixed into every non-BasicObject class, so an
      # implicit-self `__dir__` call (receiver_type = Nominal[ClassName]) is matched by looking
      # up Kernel as the owner. Explicit `Kernel.__dir__` (receiver_type = Singleton[Kernel]) and
      # instance-side calls (receiver_type = Nominal[Klass]) share the `:both` row.
      #
      # The receiver-side ancestor check is intentionally cheap: any non-BasicObject Nominal /
      # Singleton matches every Kernel-owned override. BasicObject explicitly excludes Kernel and
      # is therefore rejected. The narrow risk of a user-defined `def __dir__` shadowing Kernel's
      # method would also alter the runtime answer; users with that configuration opt out via a
      # `signature_paths` overlay declaring their own return type.
      def try_static_refinement(receiver_type, method_name, arg_types)
        candidates = Rigor::Builtins::StaticReturnRefinements.owners_for(method_name)
        return nil if candidates.empty?

        owner = static_refinement_owner_for(receiver_type, candidates)
        return nil unless owner

        kind = receiver_type.is_a?(Type::Singleton) ? :singleton : :instance
        Rigor::Builtins::StaticReturnRefinements.lookup(
          owner_class_name: owner,
          method_name: method_name,
          kind: kind,
          arg_types: arg_types
        )
      end

      # Picks the most specific override owner the receiver honours. For Kernel-owned overrides
      # the receiver simply needs to be a real-class Nominal / Singleton (i.e. not BasicObject
      # and not a Dynamic / Constant / shape carrier — those carriers go through their own
      # narrower tiers).
      def static_refinement_owner_for(receiver_type, candidates)
        receiver_class = static_refinement_class_for(receiver_type)
        return nil unless receiver_class

        return "Kernel" if candidates.include?("Kernel") && receiver_class != "BasicObject"

        candidates.find { |owner| owner == receiver_class }
      end

      def static_refinement_class_for(receiver_type)
        case receiver_type
        when Type::Singleton, Type::Nominal
          receiver_type.class_name
        end
      end

      # ADR-2 § "Flow Contribution Bundle" / v0.1.1 Track 2 slice 7; ADR-52 WD3 — consults each
      # loaded plugin's gated `dynamic_return` rules, wraps the contributed types as
      # `FlowContribution` bundles, merges them through `FlowContribution::Merger`, and returns
      # the merged `return_type` slot (or nil when no plugin contributed a return type).
      #
      # Plugins whose hook raises have their contribution silently dropped for this call so the
      # dispatch chain keeps moving — the run-level diagnostic envelope (per ADR-2 § "Plugin
      # Trust and I/O Policy") is owned by `Analysis::Runner#plugin_emitted_diagnostics`.
      def try_plugin_contribution(call_node, scope, receiver_type)
        return nil if call_node.nil? || scope.nil?

        registry = scope.environment&.plugin_registry
        return nil if registry.nil? || registry.empty?

        contributions = collect_plugin_contributions(registry, call_node, scope, receiver_type)
        return nil if contributions.empty?

        FlowContribution::Merger.merge(contributions).return_type
      end

      # ADR-16 synthetic-method tier. Slice 2b shipped the floor — a match short-circuits at the
      # right precedence (above dep-source / discovered / user-class-fallback; below RBS) and
      # returns `Dynamic[T]`. Slice 6 (precision promotion):
      # - Tier B path (slice 6a, `provenance[:origin_module]` recorded by the slice-3b scanner):
      #   redispatch on `Nominal[origin_module]` via `RbsDispatch` so the module's authored RBS
      #   return type wins. Devise's `valid_password?` returns `bool`, not `Dynamic[T]`.
      # - Tier C path (slice 6b, plain `return_type:` string from the manifest's emit table):
      #   look up `environment.nominal_for_name(return_type)` so `attribute :avatar,
      #   Types::String` emits a synthetic reader returning
      #   `Nominal[ActiveStorage::Attached::One]` (when the class is in RBS). Unparameterised
      #   class names only — parameterised forms (`Array[String]`, `Hash[K, V]`) and
      #   plugin-supplied utility-type names (`Pick<T, K>`) require routing through the full
      #   ADR-13 `Plugin::TypeNodeResolver` chain, which slice 6 does not yet wire in (the
      #   resolver chain is consulted only for `%a{rigor:v1:…}` payloads as of ADR-13 slice 3).
      def try_synthetic_method(receiver_type, method_name, arg_types, block_type, environment)
        index = environment&.synthetic_method_index
        return nil if index.nil? || index.empty?

        class_name = synthetic_method_class_name(receiver_type)
        return nil if class_name.nil?

        matches = case receiver_type
                  when Type::Singleton then index.lookup_singleton(class_name, method_name)
                  else index.lookup_instance(class_name, method_name)
                  end
        return nil if matches.empty?

        promoted = promote_synthetic_match(matches, method_name, arg_types, block_type, environment)
        promoted || Type::Combinator.untyped
      end

      # First non-nil promotion wins. Tier B (origin_module) and Tier C (return_type nominal
      # lookup) are tried in the same registration-order pass per WD11 first-wins — the slice-3b
      # scanner sets `origin_module` for Tier B entries and leaves it absent for Tier C, so the
      # two paths self-route per match.
      def promote_synthetic_match(matches, method_name, arg_types, block_type, environment)
        return nil if environment.nil?

        matches.each do |synthetic|
          promoted =
            promote_via_origin_module(synthetic, method_name, arg_types, block_type, environment) ||
            promote_via_return_type(synthetic, environment)
          return promoted if promoted
        end
        nil
      end

      # Slice 6a-TierB. For Tier B emissions (origin_module recorded in provenance), redispatch
      # the call on the included module's `Nominal[...]` type via `RbsDispatch`. Returns nil when
      # the SyntheticMethod is not a Tier B entry or when the origin_module is not in the RBS
      # env.
      def promote_via_origin_module(synthetic, method_name, arg_types, block_type, environment)
        module_name = synthetic.provenance[:origin_module]
        return nil unless module_name

        module_type = Type::Combinator.nominal_of(module_name)
        RbsDispatch.try_dispatch(
          CallContext.build(
            receiver: module_type, method_name: method_name, args: arg_types,
            environment: environment, block_type: block_type
          )
        )
      end

      # Slice 6b-TierC. For Tier C emissions, look up the manifest-declared `return_type:` string
      # via `environment.nominal_for_name`. Skips the placeholder `"untyped"` (Tier B's
      # record-but-do-not-resolve marker from the slice-3b scanner) and the `"void"` keyword
      # (RBS-style absent return). Falls back to nil when the class is not in the env — caller
      # then returns Dynamic[T].
      TIER_C_PLACEHOLDER_RETURNS = %w[untyped void].freeze
      private_constant :TIER_C_PLACEHOLDER_RETURNS

      def promote_via_return_type(synthetic, environment)
        return_type = synthetic.return_type
        return nil if return_type.nil? || TIER_C_PLACEHOLDER_RETURNS.include?(return_type)

        environment.nominal_for_name(return_type)
      end

      def synthetic_method_class_name(receiver_type)
        case receiver_type
        when Type::Nominal, Type::Singleton then receiver_type.class_name
        end
      end

      # ADR-17 slice 2 — project-side patched-method tier. Slice 3a uses the registry's
      # heuristic-extracted `return_type` (populated via the same
      # `Analysis::DependencySourceInference::ReturnTypeHeuristic` the ADR-10 walker uses): a
      # `def to_url; "hello"; end` patched onto `String` now resolves `s.to_url` to
      # `Dynamic[Nominal[String]]` instead of the pre-3a `Dynamic[Top]`. Falls back to
      # `Dynamic[Top]` when the heuristic declined (non-literal tail expression).
      def try_project_patched_method(receiver_type, method_name, environment)
        registry = environment&.project_patched_methods
        return nil if registry.nil? || registry.empty?

        class_name = synthetic_method_class_name(receiver_type)
        return nil if class_name.nil?

        kind = receiver_type.is_a?(Type::Singleton) ? :singleton : :instance
        entry = registry.lookup(class_name: class_name, method_name: method_name, kind: kind)
        return nil if entry.nil?
        return Type::Combinator.untyped if entry.return_type.nil?

        Type::Combinator.dynamic(entry.return_type)
      end

      # ADR-10 slice 2b-ii. Consults the per-run `Analysis::DependencySourceInference::Index`
      # carried by the environment for `(class_name, method_name)` observations harvested from
      # opt-in gems' `roots:`. On a hit, returns `Combinator.untyped` so the call site carries
      # the `Dynamic[top]` provenance (per ADR-10's "Inference contract": gem-source-inferred
      # shapes never publish as ground-truth `T`). Returns `nil` when the environment carries no
      # index, the index has no entry, or the receiver has no nominal class to look up.
      def try_dependency_source(receiver_type, method_name, environment)
        index = environment&.dependency_source_index
        return nil if index.nil? || index.empty?

        class_name = dep_source_class_name(receiver_type)
        return nil if class_name.nil?

        # ADR-10 5a — per-receiver plugin veto. When a registered plugin declares
        # `manifest(owns_receivers: [<class>])` AND the call's receiver IS that class (or a
        # subclass), decline and let plugins handle the call. Plugins that own a receiver are
        # the authoritative source for that type; gem-source inference must not contribute
        # behind their backs.
        return nil if plugin_owns_receiver?(class_name, environment)

        contribution = index.contribution_for(class_name: class_name, method_name: method_name)
        return dependency_source_return_type(contribution) if contribution

        # ADR-10 5b — β budget semantics. On a catalog miss, if the receiver class belongs to a
        # budget-exceeded gem AND the user opted into `:dependency_silence`, return
        # `Dynamic[top]` rather than falling through to the user-class fallback. The user-class
        # fallback would otherwise emit `call.undefined-method` for methods Rigor's catalog
        # couldn't reach because the walker hit its cap.
        budget_silence_result(class_name, index, environment)
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

      # Maps a {DependencySourceInference::Walker::CatalogEntry} to the Type the dispatcher
      # returns at the call site. When the heuristic recovered a static facet, wrap it in
      # `Dynamic[T]` per ADR-10's gem-boundary contract; otherwise fall back to the
      # pre-heuristic `Dynamic[top]`.
      def dependency_source_return_type(contribution)
        return Type::Combinator.untyped if contribution.return_type.nil?

        Type::Combinator.dynamic(contribution.return_type)
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

        dep_source_class_name(receiver_type)
      end

      def rbs_result_untyped?(rbs_result)
        rbs_result.is_a?(Type::Dynamic) && rbs_result.static_facet.is_a?(Type::Top)
      end

      def rbs_display_for(rbs_result)
        return "untyped" if rbs_result.nil?

        rbs_result.respond_to?(:describe) ? rbs_result.describe : rbs_result.inspect
      end

      def budget_silence_result(class_name, index, _environment)
        return nil unless index.budget_overrun_strategy == :dependency_silence

        owning_gem = index.gem_for(class_name)
        return nil if owning_gem.nil?
        return nil unless index.budget_exceeded.include?(owning_gem)

        Type::Combinator.untyped
      end

      # ADR-52 WD1 — the per-dispatch plugins × owns_receivers × `class_ordering` walk moved into
      # the compiled contribution table: the union is built once per registry (almost always
      # empty → O(1) false) and per-class verdicts memoise per run.
      def plugin_owns_receiver?(class_name, environment)
        registry = environment&.plugin_registry
        return false if registry.nil? || registry.empty?

        registry.contribution_index.owns_receiver?(class_name, environment)
      end

      def dep_source_class_name(receiver_type)
        case receiver_type
        when Type::Nominal, Type::Singleton then receiver_type.class_name
        end
      end

      # ADR-37 slice 2 / ADR-52 WD3 — gathers each plugin's return-type contribution from the
      # gated `dynamic_return` DSL, wrapped as a return-only `FlowContribution` for the shared
      # merger. (The legacy ungated `flow_contribution_for` escape valve was deleted once its
      # five users migrated.)
      EMPTY_CONTRIBUTIONS = [].freeze
      private_constant :EMPTY_CONTRIBUTIONS

      # Collects every plugin's flow / dynamic-return contribution for one call site. Two
      # prunings keep this off the hot path on plugin-heavy projects (it was the #1 allocation
      # site and a top CPU cost):
      #
      # 1. Only the plugins that *structurally* implement a per-call path are visited —
      #    `registry.contribution_index.for_method_dispatch` is the registry-ordered subset
      #    declaring a `dynamic_return`. Iterating the subset in registry order, and gating each
      #    path by membership, yields the exact same contributions in the same order as visiting
      #    every plugin would (a skipped plugin's call returns nil/[] anyway). The
      #    receiver-class ancestry match still happens per dispatch inside `dynamic_return_type`.
      # 2. Contributions accumulate lazily — allocate only when one actually appears, and share a
      #    frozen empty array otherwise. The caller treats the result as read-only (`.empty?` /
      #    `Merger.merge`).
      # 3. ADR-52 WD1 — method-name gates compiled at registry build. The global gate makes the
      #    common "no plugin cares about this call" case a single Set probe; the per-plugin gate
      #    skips a plugin whose `dynamic_return` rules are all `methods:`-gated on other names. A
      #    pruned consultation could only have returned nil, so contribution order and content
      #    are unchanged.
      def collect_plugin_contributions(registry, call_node, scope, receiver_type)
        index = registry.contribution_index
        relevant = index.for_method_dispatch
        return EMPTY_CONTRIBUTIONS if relevant.empty?

        # `call_node` is not always a CallNode — the `&:symbol` block path dispatches with the
        # `Prism::BlockArgumentNode` itself (`ExpressionTyper#symbol_block_return_type`). A bare
        # `.name` here raised, and the raise was silently absorbed by `block_return_type_for`'s
        # rescue, nil-ing the block type and flipping `select(&:p)`-style calls onto their
        # no-block Enumerator overloads (caught by the GitLab corpus gate).
        name = call_node.respond_to?(:name) ? call_node.name : nil
        return EMPTY_CONTRIBUTIONS unless index.dispatch_candidate?(name)

        collect_gated_contributions(index, relevant, name, call_node, scope, receiver_type)
      end

      # The post-gate walk, in registry order — the same order the ungated walk used.
      def collect_gated_contributions(index, relevant, name, call_node, scope, receiver_type)
        result = nil
        relevant.each do |plugin|
          next unless index.dynamic_candidate_for?(plugin, name)

          dynamic = plugin.dynamic_return_type(call_node: call_node, scope: scope, receiver_type: receiver_type)
          (result ||= []) << FlowContribution.new(return_type: dynamic) if dynamic
        rescue StandardError
          next
        end
        result || EMPTY_CONTRIBUTIONS
      end

      # Runs the precision tiers (constant fold, shape dispatch, file-path fold, block fold) in
      # order and returns the first non-nil answer. Each tier owns its own receiver/argument
      # shape checks; a tier that does not recognise the receiver returns nil so the next tier
      # can try. The RBS tier sits below this chain and is invoked by the outer `dispatch`
      # method.
      #
      # The precise-tier folders, consulted in order via the uniform `_DispatchTier` interface
      # (`try_dispatch(CallContext) -> Type?`). Order is significant: ConstantFolding's
      # exact-value folds win first, the stdlib singleton folders sit in the middle (each
      # gates on a distinct `Singleton` receiver, so their relative order is immaterial), and
      # BlockFolding runs last because its rules only apply to block-taking calls — the cheaper
      # arity folds above it filter the common cases first. Adding a precise tier is a one-line
      # append here rather than another link in a hand-written `||` ladder.
      PRECISE_TIERS_HEAD = Ractor.make_shareable([
        ConstantFolding, LiteralStringFolding, ShapeDispatch
      ].freeze)
      private_constant :PRECISE_TIERS_HEAD

      # ADR-53 re-review follow-up (gate-by-held-key applied to the built-in tiers): the stdlib
      # singleton folders are mutually exclusive — each fires only on `Singleton[<its
      # class>]`, the first check in every `try_dispatch` — so at most one can match a given
      # receiver and their relative trial order was never observable. Compiling them into a
      # class-name table turns nine no-op trials per call into one Hash read, skipped entirely
      # when the receiver is not a `Singleton` (the overwhelmingly common case). The table sits
      # where the original eight sat in the old flat list: after ShapeDispatch, before KernelDispatch.
      STDLIB_SINGLETON_FOLDERS = Ractor.make_shareable({
        "File" => FileFolding,
        "Shellwords" => ShellwordsFolding,
        "Math" => MathFolding,
        "Time" => TimeFolding,
        "Regexp" => RegexpFolding,
        "CGI" => CGIFolding,
        "URI" => URIFolding,
        "Set" => SetFolding,
        "JSON" => JSONFolding
      }.freeze)
      private_constant :STDLIB_SINGLETON_FOLDERS

      PRECISE_TIERS_TAIL = Ractor.make_shareable([
        MethodFolding, ReduceFolding, ArrayToHFolding, BlockFolding
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

        meta_result = try_meta_introspection(context.receiver, context.method_name, context.args, context)
        return meta_result if meta_result

        PRECISE_TIERS_HEAD.each do |tier|
          result = tier.try_dispatch(context)
          return result if result
        end

        receiver = context.receiver
        if receiver.is_a?(Type::Singleton) && (folder = STDLIB_SINGLETON_FOLDERS[receiver.class_name])
          result = folder.try_dispatch(context)
          return result if result
        end

        kernel_result = dispatch_kernel_intrinsic(context)
        return kernel_result if kernel_result

        PRECISE_TIERS_TAIL.each do |tier|
          result = tier.try_dispatch(context)
          return result if result
        end
        nil
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
            public_only: explicit_non_self_receiver?(call_node),
            call_node: nil, scope: nil
          )
        )
      end

      # True when the call node carries an explicit receiver that is not the literal `self`.
      # Such a call cannot legally dispatch to a private method, so the user-class fallback must
      # skip private signatures rather than return a confidently-wrong type. Returns false for
      # implicit-self calls and `self.`-receiver calls (both may legally reach a private method
      # in modern Ruby), and false when no `call_node` is supplied (internal dispatcher callers).
      def explicit_non_self_receiver?(call_node)
        return false if call_node.nil?
        return false unless call_node.respond_to?(:receiver)

        receiver = call_node.receiver
        return false if receiver.nil?

        !receiver.is_a?(Prism::SelfNode)
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

      # Slice 7 phase 8 — meta-introspection shortcuts. The default `Object#class` RBS return
      # type is `Class`, but for a receiver of known nominal identity we can do better:
      # `instance_of(Foo).class` is `Singleton[Foo]` (the class object itself), which downstream
      # dispatch uses to resolve `self.class.some_class_method`. The same logic answers
      # `Foo.class` as `Singleton[Class]` (deliberate; calling `.class` on a class object yields
      # `Class`, the metaclass). We also special-case `is_a?`-adjacent calls and the trivial
      # `instance_of?(self)` later as the rule catalogue grows; for now only `class` is handled.
      def try_meta_introspection(receiver_type, method_name, arg_types = [], context = nil)
        case method_name
        when :class then meta_class(receiver_type)
        when :new then meta_new(receiver_type, arg_types, context)
        end
      end

      def meta_class(receiver_type)
        case receiver_type
        when Type::Nominal then Type::Combinator.singleton_of(receiver_type.class_name)
        when Type::Constant then constant_metaclass(receiver_type.value)
        end
      end

      # `Singleton[Foo].new` returns `Nominal[Foo]` (a fresh instance), regardless of whether Foo
      # is in RBS. This short-circuits the Class.new generic-`instance` plumbing for user
      # classes, so a discovered-class `ScanAccumulator.new` types as
      # `Nominal[ScanAccumulator]` rather than `Class`.
      #
      # v0.0.7 — for the curated set of immutable scalar-shaped classes that
      # `Type::Constant::SCALAR_CLASSES` accepts (today: `Pathname`), `.new(Constant<…>)` lifts
      # to a `Constant<…>` carrier so downstream method calls fold through the standard catalog
      # tier.
      def meta_new(receiver_type, arg_types = [], context = nil)
        return nil unless receiver_type.is_a?(Type::Singleton)

        constant_lift = constant_constructor_lift(receiver_type.class_name, arg_types)
        return constant_lift if constant_lift

        array_lift = array_new_lift(receiver_type.class_name, arg_types, context&.block_type)
        return array_lift if array_lift

        range_lift = range_new_lift(receiver_type.class_name, arg_types)
        return range_lift if range_lift

        set_lift = set_new_lift(receiver_type.class_name, arg_types)
        return set_lift if set_lift

        hash_lift = hash_new_lift(receiver_type.class_name, arg_types)
        return hash_lift if hash_lift

        regexp_lift = regexp_new_lift(receiver_type.class_name, arg_types)
        return regexp_lift if regexp_lift

        date_lift = date_new_lift(receiver_type.class_name, arg_types)
        return date_lift if date_lift

        struct_new_lift = struct_new_lift(receiver_type.class_name, arg_types)
        return struct_new_lift if struct_new_lift

        class_new_lift = class_new_lift(receiver_type.class_name, arg_types, context)
        return class_new_lift if class_new_lift

        Type::Combinator.nominal_of(receiver_type.class_name)
      end

      # `Struct.new(:a, :b)` synthesises an anonymous Struct *subclass* (a class object), not a
      # Struct *instance* — so the chained idiom `Struct.new(:a, :b).new(1, 2)` must resolve
      # `.new` again on a class-like carrier. The constant-bound form (`S = Struct.new(:a);
      # S.new(1)`) already records `Singleton[S]` via `ScopeIndexer#record_meta_new_constant?`;
      # this lift gives the *chained* (anonymous) position the same class-like carrier so the
      # trailing `.new` dispatches instead of firing a spurious `undefined method 'new' for
      # Struct`.
      #
      # The disambiguation mirrors `ScopeIndexer#struct_new_call?`: a call whose positionals are
      # all `Constant<Symbol>` literals is a member-list class definition → `Singleton[Struct]`.
      # The following `AnonStruct.new(1, 2)` carries non-symbol args, so it falls through this
      # gate to `Nominal[Struct]` (a fresh instance) via the `meta_new` tail. ADR-48 deferred full
      # Struct *value* folding (member-reader precision) on mutability grounds; this is the
      # narrower `.new`-dispatch-only fix and contributes no member layout, so `instance.a` stays
      # at its RBS/Dynamic type.
      def struct_new_lift(class_name, arg_types)
        return nil unless class_name == "Struct"

        positional = arg_types.grep_v(Type::HashShape)
        return nil if positional.empty?
        return nil unless positional.all? { |t| t.is_a?(Type::Constant) && t.value.is_a?(Symbol) }

        Type::Combinator.singleton_of("Struct")
      end

      # `Class.new` and `Class.new(Parent)` create a brand-new anonymous class. Statically that
      # class is representable as the parent's singleton type — its singleton-method surface is
      # the parent's (plus whatever the block defines, which we do not statically track here),
      # so `Singleton[Parent]` lets downstream `klass.some_class_method` resolve. No parent →
      # `singleton(Object)`. Anything else (dynamic parent, more than one positional, …) falls
      # back to `Nominal[Class]` via the surrounding `meta_new` tail.
      # #319 — a `Class.new do ... end` with no parent is NOT `Object`: the block body is a class body, so the
      # class owns whatever that body defines. Answering `Singleton[Object]` handed the call site `Object`'s
      # zero-arity `new` and `Object`'s method surface, so an `initialize(bucket)` written right there produced
      # `wrong number of arguments ... (given 1, expected 0)` on code Ruby runs happily. `ScopeIndexer` registers
      # the body's methods under the call site's anonymous name; return that name so the lookups reach them.
      #
      # Scoped to the parentless form on purpose. `Class.new(Parent) { ... }` keeps `Singleton[Parent]`: the
      # anonymous name would have to carry the full ancestor chain for `Parent`'s own surface to stay reachable,
      # and the parentless case is where the false positive lives.
      def class_new_lift(class_name, arg_types, context = nil)
        return nil unless class_name == "Class"

        if arg_types.empty?
          anonymous = anonymous_class_new_name(context)
          return Type::Combinator.singleton_of(anonymous || "Object")
        end
        return nil unless arg_types.size == 1

        parent = arg_types.first
        return parent if parent.is_a?(Type::Singleton)

        nil
      end

      # The synthetic name `ScopeIndexer` keyed this call site's block body by, or nil when the context carries no
      # call node (internal dispatcher callers) or the call has no block. The source path is passed through
      # verbatim — including when it is nil, which is exactly what `ScopeIndexer` saw for the same file — so the
      # two passes derive the same name whether or not the caller supplied a path.
      def anonymous_class_new_name(context)
        return nil if context.nil?

        AnonymousMetaClass.name_for(context.call_node, context.scope&.source_path)
      end

      # ADR-15 Phase 4b.x — `Ractor.make_shareable` on both the outer Hash and each lambda value.
      # A plain `.freeze` leaves the Procs unshareable; reading `CONSTANT_CONSTRUCTORS[class]`
      # from a worker Ractor would raise `Ractor::IsolationError`, which the `rescue
      # StandardError` in `constant_constructor_lift` silently swallows — `meta_new` then falls
      # back to `Nominal[Pathname]` in pool mode while sequential builds the `Constant<Pathname>`
      # lift. The divergence surfaces downstream as a spurious `call.argument-type-mismatch`
      # (sequential's `argument_type_diagnostic` short-circuits on Constant<Pathname> because
      # Pathname is not in its CONSTANT_CLASSES table; pool's Nominal[Pathname] doesn't
      # short-circuit). Surfaced on GitLab FOSS via `lib/gitlab/mail_room.rb:17`.
      CONSTANT_CONSTRUCTORS = Ractor.make_shareable({
                                                      "Pathname" => Ractor.make_shareable(lambda { |arg|
                                                                                            Pathname.new(arg)
                                                                                          })
                                                    })
      private_constant :CONSTANT_CONSTRUCTORS

      def constant_constructor_lift(class_name, arg_types)
        builder = CONSTANT_CONSTRUCTORS[class_name]
        return nil if builder.nil?
        return nil unless arg_types.size == 1

        arg = arg_types.first
        return nil unless arg.is_a?(Type::Constant) && arg.value.is_a?(String)

        result = builder.call(arg.value)
        Type::Combinator.constant_of(result)
      rescue StandardError
        nil
      end

      # `Array.new(n, value)` and `Array.new(n)` (no value, default `nil`) lift to a per-position
      # `Tuple[…]` when `n` is a small `Constant<Integer>`. Cap at `ARRAY_NEW_TUPLE_LIMIT` (16)
      # so a `Array.new(1_000_000)` does not balloon the carrier; oversize calls fall through to
      # the element-parameter seed below.
      #
      # #317 — `Array.new(n) { |i| ... }` fills every slot from the BLOCK's return type instead
      # of the two-arg `(n, default_value)` overload's `nil` fill. The block and the trailing
      # `default_value` positional are mutually exclusive per `Array#initialize`'s RBS overload
      # set (`(int size, ?E default_value) -> void` vs `(int size) { (Integer index) -> E } ->
      # void`), so a block present at the call site always wins over any (illegal, but tolerated
      # rather than rejected here) second positional.
      ARRAY_NEW_TUPLE_LIMIT = 16
      private_constant :ARRAY_NEW_TUPLE_LIMIT

      def array_new_lift(class_name, arg_types, block_type = nil)
        return nil unless class_name == "Array"
        return nil if arg_types.empty? || arg_types.size > 2

        size = array_new_size(arg_types.first)
        if size && !size.negative? && size <= ARRAY_NEW_TUPLE_LIMIT
          return Type::Combinator.tuple_of(*Array.new(size, block_type || array_new_fill(arg_types[1])))
        end

        array_new_seed(arg_types, block_type)
      end

      # The carrier for a constructor whose size is not a small literal — `Array.new(n)`,
      # `Array.new(n, v)`, `Array.new(n) { … }`.
      #
      # This must never be a BARE `Array`. A nominal with no type argument carries no element
      # arm, and the ADR-56 block/loop seams read exactly that as an ELEMENTLESS seed — a fresh
      # accumulator whose every store the seam saw — so they CLOSE the carrier over the block's
      # own stores. `acc = Array.new(n); [1].each { acc.push(1) }` then read `Array[1]` for an
      # array whose other `n` slots hold `nil`, and `acc = Array.new(n, "x")` read `Array[1]` and
      # drew `undefined method 'upcase'` on the correct `acc.first.upcase` (issue #615). Handing
      # the seams a real element arm is what puts the constructor under the #586 rule, which
      # keeps every seed arm through the join.
      #
      # The element itself is the fill value's / block result's type, value-pin widened for the
      # reason `hash_new_lift` widens its default: the slots are rewritten over the array's
      # lifetime, so pinning the parameter to the literal would let a later `a[i] == "x"`
      # constant-fold.
      #
      # **The no-fill form seeds the GRADUAL element, not `nil`.** `Array.new(n)` really does put
      # a `nil` in every slot, but a `Nominal` seed gets DECLARED-carrier semantics downstream:
      # the #586 join keeps a seed arm forever, and `MutationWidening#widen_for_mutator` declines
      # a `Nominal` outright, so no whole-array rewrite — `[]=`, `fill`, `map!`, `replace`,
      # `concat` — can ever retract it. The placeholder would become a permanent nil possibility
      # over the allocate-then-fill idiom that is the whole point of the constructor:
      #
      #     dp = Array.new(xs.size); dp[0] = 1
      #     (1...n).each { |i| dp[i] = dp[i - 1] + xs[i] }   # `undefined method '+' for nil`
      #
      #     buf = Array.new(256); 256.times { |i| buf[i] = i.to_s }
      #     buf.each { |c| c.upcase }                        # possible nil receiver
      #
      # Both are correct Ruby, and both went from quiet to an ERROR on the `nil` seed. The true
      # positive the `nil` would buy — `Array.new(n).first.upcase` on an array nothing ever wrote
      # — is not worth the dominant idiom, so the no-fill form stays gradual whatever the size
      # argument reads as. (That also happens to absorb Ruby's array-convertible COPY overload:
      # `Array.new([1, 2])` is `[1, 2]`, not two nils.)
      def array_new_seed(arg_types, block_type)
        fill = block_type || arg_types[1]
        return array_seed_of(Type::Combinator.untyped) if fill.nil?

        element = array_new_element(fill)
        # `Array.new(n, nil)` is the same allocate-then-fill idiom as `Array.new(n)`, spelled with the
        # placeholder made explicit — concurrent-ruby writes `@Resolutions = ::Array.new(count, nil)` and
        # fills it by index. A nil-only element would be a PERMANENT nil arm (a Nominal carrier's element is
        # never widened by a later `[]=` / `fill` / `replace`), so every read of a filled slot would draw
        # `undefined method '…' for nil` on correct code. Same trade as the no-fill form above: the seam
        # needs an arm, not a precise one.
        element = Type::Combinator.untyped if nil_only_element?(element)
        array_seed_of(element)
      end

      # Whether the widened fill leaves nothing but `nil` behind — see {#array_new_seed}.
      def nil_only_element?(element)
        members = element.is_a?(Type::Union) ? element.members : [element]
        members.all? do |member|
          (member.is_a?(Type::Constant) && member.value.nil?) ||
            (member.is_a?(Type::Nominal) && member.class_name == "NilClass")
        end
      end

      def array_seed_of(element)
        Type::Combinator.nominal_of("Array", type_args: [element])
      end

      # A fill / block result as an element PARAMETER. Value pinning is dropped, and a literal
      # container widens to its nominal: `Array.new(n) { [] }` builds n INDEPENDENT arrays that
      # the program then appends to, and `Array[Tuple[]]` claims every one of them stays empty —
      # the adjacency-list idiom would read `adj[i].first` as `nil`. Both conversions go through
      # {MutationWidening}'s own helpers, the single owner of "literal container → parameterised
      # nominal" that `MemberShapeProjection` already borrows.
      #
      # The walk is **recursive**, through `Union` members and through a container's own elements /
      # values alike. Every one of those positions is a fresh object per constructed slot that the
      # program goes on to mutate, so stopping at the outermost level only moved the wrong-precise
      # answer one level in: `a = Array.new(n) { [[1]] }; a[0][0] << 5` left `Array[Array[[1]]]`
      # and folded `a[0][0].last == 5` always-falsey on correct code. Judging a `Union` wholesale
      # was the same defect one axis over — `Array.new(n) { flag ? [1] : [2] }` kept both arms as
      # fixed-arity tuples.
      #
      # `depth` is defensive only. A `Type` carrier is an immutable value object assembled
      # bottom-up (`Tuple.new(elements)`, `HashShape.new(pairs)`), so it cannot contain itself and
      # this walk is bounded by the source literal's own nesting; the cap costs nothing on any
      # literal a person writes and stops a malformed carrier from recursing forever.
      ARRAY_NEW_FILL_DEPTH_LIMIT = 8
      private_constant :ARRAY_NEW_FILL_DEPTH_LIMIT

      def array_new_element(type, depth = 0)
        return Type::Combinator.untyped if depth > ARRAY_NEW_FILL_DEPTH_LIMIT

        case type
        when Type::Tuple then MutationWidening.widen_tuple(recursed_tuple(type, depth))
        when Type::HashShape then MutationWidening.widen_hash_shape(recursed_hash_shape(type, depth))
        when Type::Union then Type::Combinator.union(*type.members.map { |m| array_new_element(m, depth + 1) })
        else Type::Combinator.widen_value_pinned(type)
        end
      end

      # The same tuple / hash shape with every element / value already widened, so the
      # {MutationWidening} helper that consumes it sees nominals where the literal had pins. The
      # rebuilt carrier is a throwaway argument — never surfaced — and the helpers read only
      # `elements` / `pairs`, so no policy field rides on it.
      def recursed_tuple(type, depth)
        Type::Combinator.tuple_of(*type.elements.map { |e| array_new_element(e, depth + 1) })
      end

      def recursed_hash_shape(type, depth)
        Type::Combinator.hash_shape_of(
          type.pairs.transform_values { |v| array_new_element(v, depth + 1) }
        )
      end

      def array_new_size(type)
        return nil unless type.is_a?(Type::Constant) && type.value.is_a?(Integer)

        type.value
      end

      def array_new_fill(type)
        return Type::Combinator.constant_of(nil) if type.nil?

        type
      end

      # `Hash.new(default)` — lifts the default value's type into the Hash's value parameter so
      # a subsequent `h[k]` read surfaces the default type rather than `Dynamic[top]`. The
      # common counter idiom `h = Hash.new(0); h[k] += 1` then types the read as `Integer`. The
      # key parameter is left `untyped` (the default carrier imposes no key constraint), so
      # reads of any key resolve through the value parameter. A value-pinned `Constant` default
      # (`0`) is widened to its nominal (`Integer`): the hash's values mutate over its lifetime,
      # so pinning the parameter to the literal would be unsound for the aggregate.
      #
      # Only the single-argument default form folds. The zero-arg (`Hash.new`) and the block
      # form (`Hash.new { |h, k| … }`) keep the bare `Nominal[Hash]` answer — the block's value
      # type is not available at this `:new` dispatch site, and conservatively leaving the read
      # as today's behaviour is precision-additive.
      def hash_new_lift(class_name, arg_types)
        return nil unless class_name == "Hash"
        return nil unless arg_types.size == 1

        default = arg_types.first
        return nil if default.nil?

        value = Type::Combinator.widen_value_pinned(default)
        Type::Combinator.nominal_of("Hash", type_args: [Type::Combinator.untyped, value])
      end

      # `Range.new(b, e)` / `Range.new(b, e, excl)` — folds to `Constant[Range]` when both
      # endpoints are `Constant[Integer]` or both are `Constant[String]`, and the optional third
      # argument is a `Constant[true/false]`. Nil endpoints (beginless / endless ranges) are not
      # folded because the useful instance methods (`to_a`, `first`, `last`) are not defined for
      # them; the RBS tier answers `Nominal[Range]` for those forms.
      def range_new_lift(class_name, arg_types)
        return nil unless class_name == "Range"
        return nil if arg_types.size < 2 || arg_types.size > 3

        b_type = arg_types[0]
        e_type = arg_types[1]

        return nil unless b_type.is_a?(Type::Constant) && e_type.is_a?(Type::Constant)

        b_val = b_type.value
        e_val = e_type.value

        # Only fold homogeneous Integer or String endpoint pairs.
        return nil unless b_val.instance_of?(e_val.class)
        return nil unless b_val.is_a?(Integer) || b_val.is_a?(String)

        excl = range_new_excl(arg_types[2])
        return nil if excl.nil?

        Type::Combinator.constant_of(Range.new(b_val, e_val, excl))
      rescue StandardError
        nil
      end

      # Resolves the optional `exclude_end` argument for `range_new_lift`. Returns `false` (no
      # arg), `true`/`false` (Constant[bool] arg), or `nil` to signal "decline" (wrong type /
      # wrong value class).
      def range_new_excl(excl_type)
        case excl_type
        when nil then false
        when Type::Constant
          excl_type.value if [true, false].include?(excl_type.value)
        end
      end

      # `Set.new` / `Set.new(tuple_of_constants)` — folds to `Constant[Set]` when zero arguments
      # are given or the single argument is a `Tuple` whose every element is a `Constant[T]`.
      # Mirrors `SetFolding#fold_new` but lives here so the `:new` path in
      # `try_meta_introspection` can reach it before the RBS tier answers `Nominal[Set]`.
      def set_new_lift(class_name, arg_types)
        return nil unless class_name == "Set"
        return Type::Combinator.constant_of(::Set.new) if arg_types.empty?
        return nil if arg_types.size > 1

        arg = arg_types.first
        return nil unless arg.is_a?(Type::Tuple)
        return nil unless arg.elements.all?(Type::Constant)

        values = arg.elements.map(&:value)
        Type::Combinator.constant_of(::Set.new(values))
      rescue StandardError
        nil
      end

      # `Regexp.new(pattern)` / `Regexp.new(pattern, opts)` — folds to `Constant[Regexp]` when
      # the pattern is a `Constant[String]`. Mirrors `RegexpFolding#fold_new` but lives here so
      # the `:new` path in `try_meta_introspection` can reach it.
      def regexp_new_lift(class_name, arg_types)
        return nil unless class_name == "Regexp"
        return nil if arg_types.empty? || arg_types.size > 2

        pattern_arg = arg_types.first
        return nil unless pattern_arg.is_a?(Type::Constant) && pattern_arg.value.is_a?(String)

        opts = if arg_types.size == 2
                 opt_type = arg_types[1]
                 return nil unless opt_type.is_a?(Type::Constant)

                 opt_type.value
               else
                 0
               end

        Type::Combinator.constant_of(Regexp.new(pattern_arg.value, opts))
      rescue StandardError
        nil
      end

      # `Date.new(y, m, d)` / `DateTime.new(y, m, d, h, min, s, off)` — folds to `Constant[Date]`
      # / `Constant[DateTime]` when every argument is a `Constant` carrying an Integer (or, for
      # the `DateTime` offset / `start` slots, a Rational or String). `Date.new` carries no
      # timezone, and `DateTime.new`'s offset defaults to UTC, so the literal is
      # machine-independent. `Date.today` / `Date.parse` are not constructors here — they are
      # non-deterministic / string-dependent and stay `Nominal[Date]`.
      DATE_NEW_CLASSES = %w[Date DateTime].freeze
      private_constant :DATE_NEW_CLASSES

      def date_new_lift(class_name, arg_types)
        return nil unless DATE_NEW_CLASSES.include?(class_name)
        return nil unless arg_types.size.between?(1, 8)
        return nil unless arg_types.all?(Type::Constant)

        values = arg_types.map(&:value)
        return nil unless values.all? { |v| v.is_a?(Integer) || v.is_a?(Rational) || v.is_a?(String) }

        klass = class_name == "Date" ? Date : DateTime
        Type::Combinator.constant_of(klass.new(*values))
      rescue StandardError
        nil
      end

      CONSTANT_METACLASSES = {
        Integer => "Integer", Float => "Float", String => "String",
        Symbol => "Symbol", Range => "Range",
        TrueClass => "TrueClass", FalseClass => "FalseClass",
        NilClass => "NilClass"
      }.freeze
      private_constant :CONSTANT_METACLASSES

      def constant_metaclass(value)
        CONSTANT_METACLASSES.each do |klass, name|
          return Type::Combinator.singleton_of(name) if value.is_a?(klass)
        end
        nil
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
      # @param receiver_type [Rigor::Type, nil]
      # @param method_name [Symbol]
      # @param arg_types [Array<Rigor::Type>]
      # @param environment [Rigor::Environment, nil]
      # @return [Array<Rigor::Type>]
      def expected_block_param_types(receiver_type:, method_name:, arg_types:, environment: nil)
        return [] if receiver_type.nil?

        context = CallContext.build(
          receiver: receiver_type, method_name: method_name,
          args: arg_types, environment: environment
        )
        iterator_result = IteratorDispatch.block_param_types(context)
        return iterator_result if iterator_result

        RbsDispatch.block_param_types(context)
      end
    end
  end
end
