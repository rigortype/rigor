# frozen_string_literal: true

require_relative "../reflection"
require_relative "../type"
require_relative "../flow_contribution"
require_relative "../flow_contribution/merger"
require_relative "method_dispatcher/constant_folding"
require_relative "method_dispatcher/literal_string_folding"
require_relative "method_dispatcher/shape_dispatch"
require_relative "method_dispatcher/rbs_dispatch"
require_relative "method_dispatcher/iterator_dispatch"
require_relative "method_dispatcher/block_folding"
require_relative "method_dispatcher/file_folding"
require_relative "method_dispatcher/kernel_dispatch"
require_relative "method_dispatcher/method_folding"

module Rigor
  module Inference
    # Coordinates method dispatch for the inference engine.
    #
    # Given `(receiver_type, method_name, arg_types, block_type, environment)`,
    # the dispatcher returns the inferred result type or `nil` when no
    # rule matches. `nil` is a deliberately blunt "I don't know" signal:
    # callers (today only `ExpressionTyper`) own the fail-soft fallback
    # and decide whether to record a `FallbackTracer` event.
    #
    # Tiers (in order):
    #
    # 1. {ConstantFolding}: executes the Ruby operation directly when
    #    the receiver and argument are `Constant` carriers and the
    #    method is on the curated whitelist. Slice 2.
    # 2. {ShapeDispatch}: returns the precise element/value type for a
    #    curated catalogue of `Tuple`/`HashShape` element-access
    #    methods (`first`, `last`, `[]` with a static integer/key,
    #    `fetch`, `dig`, `size`/`length`/`count`). Slice 5 phase 2.
    # 3. {RbsDispatch}: looks up the receiver's class in the RBS
    #    environment carried by the scope and translates the method's
    #    return type into a Rigor::Type. Slice 4.
    #
    # `ShapeDispatch` deliberately runs *above* {RbsDispatch} so the
    # precise per-position/per-key answer wins over the projected
    # `Array#[]`/`Hash#fetch` answer; it falls through (`nil`) when
    # the call cannot be proved against the static shape, in which
    # case the projection answer from {RbsDispatch} applies.
    #
    # The dispatcher's public signature reserves space for `block_type:`
    # and ADR-2 plugin extensions (later slices), so call sites added
    # now do not have to be rewritten when those tiers arrive.
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
        return nil if receiver_type.nil?

        bound_method_result = MethodFolding.try_backward(
          receiver: receiver_type, method_name: method_name, args: arg_types,
          block_type: block_type, environment: environment,
          call_node: call_node, scope: scope
        )
        return bound_method_result if bound_method_result

        precise = dispatch_precise_tiers(receiver_type, method_name, arg_types, block_type)
        return precise if precise

        # v0.1.1 Track 2 slice 7 — plugin return-type contribution
        # tier. Sits ahead of `RbsDispatch` so a plugin that
        # understands a domain-specific dispatch (e.g. an
        # `ActiveRecord::Base.find` returning `Nominal[<resolved
        # model>]`) wins over the RBS-projected envelope. Only
        # consults the registry when both `call_node` and `scope`
        # are supplied — the dispatcher's own internal callers
        # (per-element block fold, etc.) skip this tier.
        plugin_result = try_plugin_contribution(call_node, scope)
        return plugin_result if plugin_result

        rbs_result = RbsDispatch.try_dispatch(
          receiver: receiver_type, method_name: method_name, args: arg_types,
          environment: environment, block_type: block_type
        )
        if rbs_result
          record_boundary_cross_if_applicable(receiver_type, method_name, rbs_result, environment)
          return rbs_result
        end

        # ADR-16 Tier B / Tier C — synthetic-method tier. Sits
        # BELOW RBS dispatch (per WD13: user-authored RBS overrides
        # substrate synthesis) and ABOVE the dependency-source
        # inference tier so a plugin's declared emit table beats
        # the generic gem-source fallback for the same class. Slice
        # 6a-TierB (origin_module dispatch) lands precise return
        # types for Tier B emissions; Tier C emissions still return
        # `Dynamic[T]` at this tier (slice 6b is the Tier C
        # promotion via ADR-13's resolver chain).
        synthetic_result = try_synthetic_method(
          receiver_type, method_name, arg_types, block_type, environment
        )
        return synthetic_result if synthetic_result

        # ADR-10 slice 2b-ii — dependency-source inference tier.
        # Sits BELOW RBS dispatch (RBS / RBS::Inline / generated
        # stubs / plugin contracts always win) and ABOVE the
        # user-class fallback so a method defined in an opt-in
        # gem stops emitting `call.undefined-method` even when
        # no signature contract resolves. Returns
        # `Dynamic[top]` — slice 2b-ii deliberately stops at the
        # dynamic-origin envelope; per-method return-type
        # precision is queued for a later slice.
        dep_source_result = try_dependency_source(receiver_type, method_name, environment)
        return dep_source_result if dep_source_result

        # v0.1.3 — discovered-method dispatch tier. When the
        # receiver class has no RBS BUT scope_indexer recorded
        # `def method_name` for that class (or singleton), the
        # call dispatches to `Dynamic[top]` rather than falling
        # through to the user-class fallback. Sits below RBS /
        # dependency-source so authoritative signatures still win.
        # The scope-indexer-built table records every project-side
        # `def`, `define_method`, and `alias_method`; the
        # `discovered_method?` consult here closes the
        # fail-soft-event hot spot on implicit-self calls
        # (`sibling_private(...)`) inside `lib/rigor/`'s own
        # internals (analyser private helpers don't have RBS).
        discovered_result = try_discovered_method(receiver_type, method_name, scope)
        return discovered_result if discovered_result

        # Slice 7 phase 10 — user-class ancestor fallback. When
        # the receiver is `Nominal[T]` or `Singleton[T]` for a
        # class not in the RBS environment (typically a
        # user-defined class), retry the dispatch against the
        # implicit ancestor: `Nominal[Object]` for instance
        # receivers and `Singleton[Object]` for singleton
        # receivers. This resolves Kernel intrinsics
        # (`require`, `raise`, `puts`, ...) and Module/Class
        # introspection (`attr_reader`, `private`, ...) on
        # user classes without requiring the user to author
        # their own RBS.
        try_user_class_fallback(receiver_type, method_name, arg_types, environment, block_type)
      end

      # v0.1.3 — discovered-method dispatch tier. `scope` carries
      # the `discovered_methods` table built once per program by
      # `ScopeIndexer` (a `Hash[String, Hash[Symbol, :instance |
      # :singleton]]`). When the receiver names a discovered
      # class AND the requested method is recorded for that
      # class's appropriate kind, return `Type::Combinator.untyped`
      # — the dispatcher cannot infer a more precise return type
      # from the bare `def` shape, but the call site stops being a
      # fail-soft hot spot.
      #
      # Returns `nil` when scope / receiver class is unavailable,
      # when the method is not in the discovered table, OR when
      # `discovered_def_nodes` carries a re-typable body for the
      # method (so the downstream
      # `ExpressionTyper#try_user_method_inference` tier can
      # re-type the body for a precise return type rather than
      # collapsing to `Dynamic[top]` here).
      #
      # The tier does NOT gate on `rbs_class_known?`. RBS dispatch
      # already had its turn upstream and returned `nil` (otherwise
      # we wouldn't be here). When RBS knows the class but the
      # particular method is missing from the sig — common for
      # internal helpers and for auto-generated stubs that emit
      # `class X` without enumerating every method — falling
      # through to the user-class fallback would mistakenly fire
      # `call.undefined-method`. Honoring the discovered table
      # here keeps the sibling-private call resolution working
      # under partial RBS coverage.
      def try_discovered_method(receiver_type, method_name, scope)
        return nil if scope.nil?

        class_name, kind = discovered_method_lookup(receiver_type)
        return nil if class_name.nil?
        return nil unless scope.discovered_method?(class_name, method_name, kind)
        return nil if kind == :instance && scope.user_def_for(class_name, method_name)

        Type::Combinator.untyped
      end

      # Resolves the `(class_name, kind)` pair scope_indexer keys
      # its `discovered_methods` table on. `Nominal[X]` looks up
      # instance methods on X; `Singleton[X]` looks up singleton
      # methods on X. Other carriers return `[nil, nil]` so the
      # tier declines.
      def discovered_method_lookup(receiver_type)
        case receiver_type
        when Type::Nominal then [receiver_type.class_name, :instance]
        when Type::Singleton then [receiver_type.class_name, :singleton]
        else [nil, nil]
        end
      end

      # ADR-2 § "Flow Contribution Bundle" / v0.1.1 Track 2
      # slice 7. Walks every loaded plugin's
      # `#flow_contribution_for(call_node:, scope:)` hook,
      # collects the non-nil `FlowContribution` bundles, merges
      # them through `FlowContribution::Merger`, and returns
      # the merged `return_type` slot (or nil when no plugin
      # contributed a return type).
      #
      # Plugins whose hook raises have their contribution
      # silently dropped for this call so the dispatch chain
      # keeps moving — the run-level diagnostic envelope (per
      # ADR-2 § "Plugin Trust and I/O Policy") is owned by
      # `Analysis::Runner#plugin_emitted_diagnostics`.
      def try_plugin_contribution(call_node, scope)
        return nil if call_node.nil? || scope.nil?

        registry = scope.environment&.plugin_registry
        return nil if registry.nil? || registry.empty?

        contributions = collect_plugin_contributions(registry, call_node, scope)
        return nil if contributions.empty?

        FlowContribution::Merger.merge(contributions).return_type
      end

      # ADR-10 slice 2b-ii. Consults the per-run
      # `Analysis::DependencySourceInference::Index` carried by
      # the environment for `(class_name, method_name)`
      # observations harvested from opt-in gems' `roots:`. On a
      # hit, returns `Combinator.untyped` so the call site
      # carries the `Dynamic[top]` provenance (per ADR-10's
      # "Inference contract": gem-source-inferred shapes never
      # publish as ground-truth `T`). Returns `nil` when the
      # environment carries no index, the index has no entry, or
      # the receiver has no nominal class to look up.
      # ADR-16 synthetic-method tier. Slice 2b shipped the floor —
      # a match short-circuits at the right precedence (above
      # dep-source / discovered / user-class-fallback; below RBS)
      # and returns `Dynamic[T]`. Slice 6 (precision promotion):
      # - Tier B path (slice 6a, `provenance[:origin_module]`
      #   recorded by the slice-3b scanner): redispatch on
      #   `Nominal[origin_module]` via `RbsDispatch` so the
      #   module's authored RBS return type wins. Devise's
      #   `valid_password?` returns `bool`, not `Dynamic[T]`.
      # - Tier C path (slice 6b, plain `return_type:` string from
      #   the manifest's emit table): look up
      #   `environment.nominal_for_name(return_type)` so
      #   `attribute :avatar, Types::String` emits a synthetic
      #   reader returning `Nominal[ActiveStorage::Attached::One]`
      #   (when the class is in RBS). Unparameterised class names
      #   only — parameterised forms (`Array[String]`,
      #   `Hash[K, V]`) and plugin-supplied utility-type names
      #   (`Pick<T, K>`) require routing through the full ADR-13
      #   `Plugin::TypeNodeResolver` chain, which slice 6 does
      #   not yet wire in (the resolver chain is consulted only
      #   for `%a{rigor:v1:…}` payloads as of ADR-13 slice 3).
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

      # First non-nil promotion wins. Tier B (origin_module) and
      # Tier C (return_type nominal lookup) are tried in the
      # same registration-order pass per WD11 first-wins —
      # the slice-3b scanner sets `origin_module` for Tier B
      # entries and leaves it absent for Tier C, so the two
      # paths self-route per match.
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

      # Slice 6a-TierB. For Tier B emissions (origin_module
      # recorded in provenance), redispatch the call on the
      # included module's `Nominal[...]` type via `RbsDispatch`.
      # Returns nil when the SyntheticMethod is not a Tier B
      # entry or when the origin_module is not in the RBS env.
      def promote_via_origin_module(synthetic, method_name, arg_types, block_type, environment)
        module_name = synthetic.provenance[:origin_module]
        return nil unless module_name

        module_type = Type::Combinator.nominal_of(module_name)
        RbsDispatch.try_dispatch(
          receiver: module_type, method_name: method_name, args: arg_types,
          environment: environment, block_type: block_type
        )
      end

      # Slice 6b-TierC. For Tier C emissions, look up the
      # manifest-declared `return_type:` string via
      # `environment.nominal_for_name`. Skips the placeholder
      # `"untyped"` (Tier B's record-but-do-not-resolve marker
      # from the slice-3b scanner) and the `"void"` keyword
      # (RBS-style absent return). Falls back to nil when the
      # class is not in the env — caller then returns Dynamic[T].
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

      def try_dependency_source(receiver_type, method_name, environment)
        index = environment&.dependency_source_index
        return nil if index.nil? || index.empty?

        class_name = dep_source_class_name(receiver_type)
        return nil if class_name.nil?

        # ADR-10 5a — per-receiver plugin veto. When a
        # registered plugin declares `manifest(owns_receivers:
        # [<class>])` AND the call's receiver IS that class
        # (or a subclass), decline and let plugins handle the
        # call. Plugins that own a receiver are the
        # authoritative source for that type; gem-source
        # inference must not contribute behind their backs.
        return nil if plugin_owns_receiver?(class_name, environment)

        contribution = index.contribution_for(class_name: class_name, method_name: method_name)
        return dependency_source_return_type(contribution) if contribution

        # ADR-10 5b — β budget semantics. On a catalog miss,
        # if the receiver class belongs to a budget-exceeded
        # gem AND the user opted into `:dependency_silence`,
        # return `Dynamic[top]` rather than falling through to
        # the user-class fallback. The user-class fallback
        # would otherwise emit `call.undefined-method` for
        # methods Rigor's catalog couldn't reach because the
        # walker hit its cap.
        budget_silence_result(class_name, index, environment)
      end

      # ADR-10 slice 5c — record a
      # `dynamic.dependency-source.boundary-cross` event when
      # RBS dispatch resolves a call AND the receiver class
      # belongs to a `mode: :full` opt-in gem whose Walker
      # also catalogued the same `(class_name, method_name)`.
      # The dispatcher still returns the RBS answer (per
      # ADR-10's tier order: authoritative-source wins), but
      # the reporter accumulates the crossing for end-of-run
      # audit diagnostics.
      #
      # Five honest fall-throughs keep the gate narrow:
      #
      # - environment / index / reporter missing — slice 5c
      #   needs all three.
      # - receiver has no nominal class name (Dynamic-only
      #   carriers) — nothing to look up.
      # - receiver class doesn't belong to a `mode: :full` gem
      #   — the user didn't opt this gem into the distinct
      #   dispatch path.
      # - the gem-source catalog has no entry for the method —
      #   only RBS knows about it; nothing to cross.
      # - the RBS-side result is itself `Dynamic[Top]` — the
      #   "agreement" is trivially `untyped ≈ untyped`, no
      #   meaningful divergence to flag.
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

      # Maps a {DependencySourceInference::Walker::CatalogEntry}
      # to the Type the dispatcher returns at the call site.
      # When the heuristic recovered a static facet, wrap it in
      # `Dynamic[T]` per ADR-10's gem-boundary contract;
      # otherwise fall back to the pre-heuristic `Dynamic[top]`.
      def dependency_source_return_type(contribution)
        return Type::Combinator.untyped if contribution.return_type.nil?

        Type::Combinator.dynamic(contribution.return_type)
      end

      # Composite preflight for {#record_boundary_cross_if_applicable}.
      # Returns the receiver class name only when every prerequisite
      # for emitting the diagnostic is satisfied (environment carries
      # an index + reporter, receiver is a nominal carrier, RBS-side
      # result is not the trivial `Dynamic[Top]` envelope). Returns
      # `nil` to short-circuit otherwise.
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

      def plugin_owns_receiver?(class_name, environment)
        registry = environment&.plugin_registry
        return false if registry.nil? || registry.empty?

        registry.plugins.any? do |plugin|
          owns = plugin.manifest.owns_receivers # rigor:disable undefined-method
          owns.any? { |owner| receiver_matches_owner?(class_name, owner, environment) }
        end
      end

      def receiver_matches_owner?(class_name, owner, environment)
        return true if class_name == owner

        ordering = environment.class_ordering(class_name, owner)
        %i[equal subclass].include?(ordering)
      rescue StandardError
        false
      end

      def dep_source_class_name(receiver_type)
        case receiver_type
        when Type::Nominal, Type::Singleton then receiver_type.class_name
        end
      end

      def collect_plugin_contributions(registry, call_node, scope)
        registry.plugins.filter_map do |plugin|
          contribution = plugin.flow_contribution_for(call_node: call_node, scope: scope)
          contribution.is_a?(FlowContribution) ? contribution : nil
        rescue StandardError
          nil
        end
      end

      # Runs the precision tiers (constant fold, shape dispatch,
      # file-path fold, block fold) in order and returns the first
      # non-nil answer. Each tier owns its own receiver/argument
      # shape checks; a tier that does not recognise the receiver
      # returns nil so the next tier can try. The RBS tier sits
      # below this chain and is invoked by the outer `dispatch`
      # method.
      #
      # `BlockFolding` runs last among the precision tiers because
      # its rules apply only to block-taking calls, so the cheaper
      # arity-based fold tiers above it filter out the common
      # cases first. When `block_type` is nil the tier is a no-op.
      def dispatch_precise_tiers(receiver_type, method_name, arg_types, block_type = nil)
        meta_result = try_meta_introspection(receiver_type, method_name, arg_types)
        return meta_result if meta_result

        ConstantFolding.try_fold(receiver: receiver_type, method_name: method_name, args: arg_types) ||
          LiteralStringFolding.try_dispatch(receiver: receiver_type, method_name: method_name, args: arg_types) ||
          ShapeDispatch.try_dispatch(receiver: receiver_type, method_name: method_name, args: arg_types) ||
          FileFolding.try_dispatch(receiver: receiver_type, method_name: method_name, args: arg_types) ||
          KernelDispatch.try_dispatch(receiver: receiver_type, method_name: method_name, args: arg_types) ||
          MethodFolding.try_forward(receiver: receiver_type, method_name: method_name, args: arg_types) ||
          BlockFolding.try_fold(
            receiver: receiver_type, method_name: method_name, args: arg_types, block_type: block_type
          )
      end

      def try_user_class_fallback(receiver_type, method_name, arg_types, environment, block_type)
        return nil if environment.nil?

        fallback_receiver = user_class_fallback_receiver(receiver_type, environment)
        return nil if fallback_receiver.nil?

        RbsDispatch.try_dispatch(
          receiver: fallback_receiver,
          method_name: method_name,
          args: arg_types,
          environment: environment,
          block_type: block_type
        )
      end

      def user_class_fallback_receiver(receiver_type, environment)
        case receiver_type
        when Type::Nominal
          return nil if Rigor::Reflection.rbs_class_known?(receiver_type.class_name, environment: environment)

          environment.nominal_for_name("Object")
        when Type::Singleton
          return nil if Rigor::Reflection.rbs_class_known?(receiver_type.class_name, environment: environment)

          environment.singleton_for_name("Class")
        end
      end

      # Slice 7 phase 8 — meta-introspection shortcuts. The
      # default `Object#class` RBS return type is `Class`, but
      # for a receiver of known nominal identity we can do
      # better: `instance_of(Foo).class` is `Singleton[Foo]`
      # (the class object itself), which downstream dispatch
      # uses to resolve `self.class.some_class_method`. The
      # same logic answers `Foo.class` as `Singleton[Class]`
      # (deliberate; calling `.class` on a class object yields
      # `Class`, the metaclass). We also special-case `is_a?`-
      # adjacent calls and the trivial `instance_of?(self)`
      # later as the rule catalogue grows; for now only `class`
      # is handled.
      def try_meta_introspection(receiver_type, method_name, arg_types = [])
        case method_name
        when :class then meta_class(receiver_type)
        when :new then meta_new(receiver_type, arg_types)
        end
      end

      def meta_class(receiver_type)
        case receiver_type
        when Type::Nominal then Type::Combinator.singleton_of(receiver_type.class_name)
        when Type::Constant then constant_metaclass(receiver_type.value)
        end
      end

      # `Singleton[Foo].new` returns `Nominal[Foo]` (a fresh
      # instance), regardless of whether Foo is in RBS. This
      # short-circuits the Class.new generic-`instance`
      # plumbing for user classes, so a discovered-class
      # `ScanAccumulator.new` types as `Nominal[ScanAccumulator]`
      # rather than `Class`.
      #
      # v0.0.7 — for the curated set of immutable scalar-shaped
      # classes that `Type::Constant::SCALAR_CLASSES` accepts
      # (today: `Pathname`), `.new(Constant<…>)` lifts to a
      # `Constant<…>` carrier so downstream method calls fold
      # through the standard catalog tier.
      def meta_new(receiver_type, arg_types = [])
        return nil unless receiver_type.is_a?(Type::Singleton)

        constant_lift = constant_constructor_lift(receiver_type.class_name, arg_types)
        return constant_lift if constant_lift

        array_lift = array_new_lift(receiver_type.class_name, arg_types)
        return array_lift if array_lift

        Type::Combinator.nominal_of(receiver_type.class_name)
      end

      # ADR-15 Phase 4b.x — `Ractor.make_shareable` on both the
      # outer Hash and each lambda value. A plain `.freeze` leaves
      # the Procs unshareable; reading `CONSTANT_CONSTRUCTORS[class]`
      # from a worker Ractor would raise `Ractor::IsolationError`,
      # which the `rescue StandardError` in
      # `constant_constructor_lift` silently swallows — `meta_new`
      # then falls back to `Nominal[Pathname]` in pool mode while
      # sequential builds the `Constant<Pathname>` lift. The
      # divergence surfaces downstream as a spurious
      # `call.argument-type-mismatch` (sequential's
      # `argument_type_diagnostic` short-circuits on Constant<Pathname>
      # because Pathname is not in its CONSTANT_CLASSES table; pool's
      # Nominal[Pathname] doesn't short-circuit). Surfaced on GitLab
      # FOSS via `lib/gitlab/mail_room.rb:17`.
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

      # `Array.new(n, value)` and `Array.new(n)` (no value, default
      # `nil`) lift to a per-position `Tuple[…]` when `n` is a
      # small `Constant<Integer>`. Cap at `ARRAY_NEW_TUPLE_LIMIT`
      # (16) so a `Array.new(1_000_000)` does not balloon the
      # carrier; oversize calls fall back to `Nominal[Array]`.
      ARRAY_NEW_TUPLE_LIMIT = 16
      private_constant :ARRAY_NEW_TUPLE_LIMIT

      def array_new_lift(class_name, arg_types)
        return nil unless class_name == "Array"
        return nil if arg_types.empty? || arg_types.size > 2

        size = array_new_size(arg_types.first)
        return nil if size.nil? || size.negative? || size > ARRAY_NEW_TUPLE_LIMIT

        fill = array_new_fill(arg_types[1])
        Type::Combinator.tuple_of(*Array.new(size, fill))
      end

      def array_new_size(type)
        return nil unless type.is_a?(Type::Constant) && type.value.is_a?(Integer)

        type.value
      end

      def array_new_fill(type)
        return Type::Combinator.constant_of(nil) if type.nil?

        type
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

      # Returns the positional block parameter types declared by the
      # receiving method's selected RBS overload, translated into
      # `Rigor::Type`. Used by the StatementEvaluator's CallNode
      # handler to bind block parameter names before evaluating the
      # block body.
      #
      # The probe is best-effort: it returns an empty array whenever
      # the receiver, environment, method definition, or selected
      # overload does not provide statically declared block parameter
      # types. Callers MUST treat the empty array as "no information";
      # the binder falls back to `Dynamic[Top]` for every parameter
      # slot in that case.
      #
      # @param receiver_type [Rigor::Type, nil]
      # @param method_name [Symbol]
      # @param arg_types [Array<Rigor::Type>]
      # @param environment [Rigor::Environment, nil]
      # @return [Array<Rigor::Type>]
      def expected_block_param_types(receiver_type:, method_name:, arg_types:, environment: nil)
        return [] if receiver_type.nil?

        iterator_result = IteratorDispatch.block_param_types(
          receiver: receiver_type,
          method_name: method_name,
          args: arg_types
        )
        return iterator_result if iterator_result

        RbsDispatch.block_param_types(
          receiver: receiver_type,
          method_name: method_name,
          args: arg_types,
          environment: environment
        )
      end
    end
  end
end
