# frozen_string_literal: true

require_relative "../../reflection"
require_relative "../../type"
require_relative "../../rbs_extended"
require_relative "../rbs_type_translator"
require_relative "../void_origin"
require_relative "../optimistic_origin"
require_relative "overload_selector"

module Rigor
  module Inference
    module MethodDispatcher
      # Slice 4 dispatch tier that consults RBS method signatures. Sits behind {ConstantFolding}, so
      # anything the constant folder already proves (e.g., `1 + 2 == 3`) keeps its full Constant precision;
      # only the calls the folder cannot prove fall through to RBS.
      #
      # Phase 2b extends the dispatcher to recognise `Singleton[Foo]` receivers, routing those calls
      # through `singleton_method` instead of `instance_method`. The constant `Foo` therefore now resolves
      # to `Singleton[Foo]`, and `Foo.new` / `Foo.bar` look up the corresponding *class* methods.
      #
      # Phase 2c adds argument-typed overload selection: instead of always returning `method_types.first`,
      # the dispatcher delegates to {OverloadSelector} which filters overloads by positional arity and
      # consults `Rigor::Type#accepts` for each parameter. When no overload accepts the actual argument
      # types, the selector falls back to the first overload so the existing phase-1/2b behavior is
      # preserved.
      #
      # Phase 2d adds generics instantiation. Receivers carry an ordered `type_args` array on
      # `Rigor::Type::Nominal`. The dispatcher zips the receiver's `type_args` against the class's declared
      # type-parameter names (`Array` -> `[:Elem]`, `Hash` -> `[:K, :V]`, ...) to build a substitution map;
      # that map is then threaded through {RbsTypeTranslator} so a return type like `::Array[Elem]`
      # resolves to `Nominal["Array", [Integer]]` rather than degrading the variable to `Dynamic[Top]`.
      # When arities mismatch (raw receiver, partial generics) the map is left empty and free variables
      # degrade as before.
      #
      # Slice 5 phase 1 projects shape-carrying receivers onto their underlying nominal so the existing
      # dispatch + substitution machinery works without duplication: `Tuple[Integer, String]` dispatches as
      # `Array[Integer | String]`, and `HashShape{a: Integer}` dispatches as `Hash[Symbol, Integer]`.
      # Tuple/HashShape element precision (e.g., `tuple[0]` returning the precise member) is handled by the
      # preceding `ShapeDispatch` tier.
      #
      # Remaining limitations:
      #
      # * `block_type:` is ignored; method types that constrain the block return type are not yet honored.
      # * Keyword arguments are not threaded through call_arg_types, so overloads with required keywords
      #   are skipped (they cannot match the empty kwargs we send).
      # * Method-level type parameters bind only from two positions: the block return type (Slice 6 phase C)
      #   and a positional parameter whose declared type is EXACTLY a type variable (issue #303 —
      #   `def foo[T]: (T) -> T` binds `T` from the first argument, and carries it into a generic return
      #   such as `-> Array[T]`). A variable reachable only through a container position (`Array[T] arg`),
      #   a rest positional (`*T`), or a keyword parameter is still unbound and degrades to `Dynamic[Top]`.
      #
      # See docs/adr/4-type-inference-engine.md for the broader plan.
      # rubocop:disable Metrics/ModuleLength
      module RbsDispatch
        module_function

        # ADR-43 — ancestor classes whose RBS is authoritative and COMPLETE, so a call a subclass makes
        # that the ancestor's RBS does not declare is a genuine mistake rather than a gap. Membership
        # unlocks inherited-method resolution (and thus `call.undefined-method`) for Ruby-source
        # subclasses of these classes; every other RBS ancestor stays on the Dynamic fallback. Seeded with
        # the plugin contract base — this repo owns both the class and `sig/rigor/plugin/base.rbs`, and
        # the `lib` self-check keeps them in lock-step. NOT a place for third-party/core classes whose
        # objects answer to methods their RBS omits (`ActionController::Base`, `Hash`, …).
        ALLOWED_RBS_COMPLETE_ANCESTORS = ["Rigor::Plugin::Base"].freeze

        # Shared empty returns for the argument-position type-variable binding (issue #303). The
        # no-candidate answer is by far the common case — every non-generic overload takes it — so it must
        # not allocate.
        EMPTY_TYPE_VARS = {}.freeze
        private_constant :EMPTY_TYPE_VARS
        EMPTY_TYPE_PARAM_NAMES = [].freeze
        private_constant :EMPTY_TYPE_PARAM_NAMES

        # @param receiver [Rigor::Type]
        # @param method_name [Symbol]
        # @param args [Array<Rigor::Type>]
        # @param environment [Rigor::Environment]
        # @param block_type [Rigor::Type, nil] inferred block return type, propagated from
        #   `MethodDispatcher.dispatch`. When non-nil, the selector prefers a block-bearing overload and
        #   binds the method-level type parameter that the block's return type references to `block_type`
        #   (Slice 6 phase C sub-phase 2).
        # @param self_type_override [Rigor::Type, nil] when set, the substitution for `Bases::Self` in the
        #   method's return type. Used by `MethodDispatcher#try_user_class_fallback` to preserve the
        #   ORIGINAL receiver as the substitute for `self` even though the dispatch is routed through
        #   `Nominal[Object]` — so that `Bundler::URI::Generic.dup` (which resolves through the `Object`
        #   fallback because `Bundler::URI::Generic` lacks RBS) returns `Bundler::URI::Generic` per
        #   `Kernel#dup: () -> self` rather than `Object`. Defaults to nil (compute self from the resolved
        #   class_name as before).
        # @param public_only [Boolean] when true, a method whose RBS accessibility is `:private` does not
        #   resolve (the call yields `nil`, i.e. "no rule"). Set by the explicit-non-`self`-receiver
        #   user-class fallback so a call like `Favourite.select(...)` does not adopt the private
        #   `Kernel#select` signature.
        # @return [Rigor::Type, nil] inferred return type, or `nil` when no rule resolves (no class name,
        #   no method, dispatch on a Top/Dynamic[Top] receiver, etc.).
        # @param scope [Rigor::Scope, nil] when supplied, enables ADR-43 RBS-complete-ancestor resolution
        #   against `ALLOWED_RBS_COMPLETE_ANCESTORS`. `nil` keeps inherited calls unresolved
        #   (`Dynamic[Top]`) — the FP-safe default for open hierarchies (`< ActionController::Base`, …).
        def try_dispatch(context)
          environment = context.environment
          return nil if environment.nil?
          return nil unless environment.rbs_loader

          dispatch_for(
            receiver: context.receiver,
            method_name: context.method_name,
            args: context.args,
            environment: environment,
            block_type: context.block_type,
            self_type_override: context.self_type_override,
            public_only: context.public_only,
            scope: context.scope,
            call_node: context.call_node
          )
        end

        # Slice 6 (Phase C sub-phase 1) probe: returns the positional block-parameter types declared by
        # the receiving method's selected RBS overload, translated into `Rigor::Type`. Used by the
        # StatementEvaluator to bind block parameter names before evaluating the block body.
        #
        # The probe shares the receiver descriptor / overload selector plumbing with `try_dispatch`; only
        # the projection at the end differs (the block's positional params instead of the return type).
        # Returns an empty array when:
        #
        # - the environment / RBS loader is missing,
        # - the receiver does not project to a known class,
        # - the method has no signature in RBS,
        # - the selected overload has no `block:` clause, or
        # - the block is `untyped` / `UntypedFunction` (no statically declared parameter types).
        #
        # This deliberately does NOT differentiate "no overload had a block" from "the block is untyped";
        # the binder treats both the same way (every parameter defaults to `Dynamic[Top]`).
        # @return [Array<Rigor::Type>] positional block parameter types.
        def block_param_types(context)
          environment = context.environment
          return [] if environment.nil?
          return [] unless environment.rbs_loader

          probe_block_param_types(
            receiver: context.receiver,
            method_name: context.method_name,
            args: context.args,
            environment: environment
          )
        end

        # rubocop:disable Metrics/ClassLength
        class << self
          private

          def dispatch_for(receiver:, method_name:, args:, environment:, block_type:, self_type_override: nil, # rubocop:disable Metrics/ParameterLists
                           public_only: false, scope: nil, call_node: nil)
            args ||= []
            case receiver
            when Type::Union
              dispatch_union(receiver, method_name, args, environment, block_type, self_type_override,
                             public_only: public_only, scope: scope, call_node: call_node)
            else
              dispatch_one(receiver, method_name, args, environment, block_type, self_type_override,
                           public_only: public_only, scope: scope, call_node: call_node)
            end
          end

          def dispatch_union(receiver, method_name, args, environment, block_type, self_type_override = nil, # rubocop:disable Metrics/ParameterLists
                             public_only: false, scope: nil, call_node: nil)
            results = receiver.members.map do |member|
              dispatch_one(member, method_name, args, environment, block_type, self_type_override,
                           public_only: public_only, scope: scope, call_node: call_node)
            end
            return nil if results.any?(&:nil?)

            Type::Combinator.union(*results)
          end

          def dispatch_one(receiver, method_name, args, environment, block_type, self_type_override = nil, # rubocop:disable Metrics/ParameterLists
                           public_only: false, scope: nil, call_node: nil)
            descriptor = receiver_descriptor(receiver)
            return nil unless descriptor

            class_name, kind, receiver_args = descriptor
            method_definition = lookup_method(environment, class_name, kind, method_name, scope)
            return nil unless method_definition
            return nil if public_only && method_private?(method_definition)

            type_vars = build_type_vars(environment, class_name, receiver_args)
            translate_return_type(
              method_definition,
              class_name: class_name,
              kind: kind,
              method_name: method_name,
              args: args,
              type_vars: type_vars,
              block_type: block_type,
              environment: environment,
              self_type_override: self_type_override,
              scope: scope,
              call_node: call_node
            )
          rescue StandardError
            # Defensive: if RBS' definition builder raises on a broken hierarchy (e.g., partially loaded
            # user signatures), the dispatcher MUST stay fail-soft.
            nil
          end

          # Maps a Rigor::Type receiver to a `[class_name, kind, type_args]` triple where `kind` is either
          # `:instance` or `:singleton` and `type_args` carries the receiver's generic instantiation (empty
          # for raw or singleton receivers, since `Singleton[Foo]` carries no generic args today). Returns
          # nil when the receiver does not correspond to a single concrete class.
          #
          # Slice 5 phase 1 projects Tuple/HashShape receivers to their underlying Array/Hash nominal so
          # dispatch reuses the generic-typed pipeline.
          def receiver_descriptor(receiver)
            case receiver
            when Type::Constant
              [receiver.value.class.name, :instance, []]
            when Type::Nominal
              [receiver.class_name, :instance, receiver.type_args]
            when Type::Singleton
              [receiver.class_name, :singleton, []]
            when Type::Tuple
              ["Array", :instance, tuple_type_args(receiver)]
            when Type::HashShape
              ["Hash", :instance, hash_shape_type_args(receiver)]
            when Type::DataInstance, Type::DataClass, Type::StructInstance, Type::StructClass
              member_carrier_descriptor(receiver)
            when Type::BoundMethod
              # `BoundMethod` is a precision-bearing alias for `Nominal[Method]`: it carries the
              # `(receiver, method_name)` binding that `MethodFolding.try_backward` consumes at
              # `.call` / `.()` / `[]`, but every other call site (`.owner` / `.name` / `.arity` / …) must
              # still resolve through Method's RBS contract. Routing here keeps reflective Method methods
              # working without forcing the carrier to collapse to a plain Nominal at construction.
              ["Method", :instance, []]
            when Type::Refined, Type::Difference
              # #533 — a refinement (`Refined`) or subtraction (`Difference` — `non-empty-string` is
              # `String − ""`) is a precision layer over its base; RBS method lookup erases to the base
              # carrier (`RUBY_VERSION != "1.0"` resolves through `String#!=` instead of declining the
              # whole dispatch to Dynamic). The refinement-aware promotions (`String#upcase` →
              # `uppercase-string`, …) run in their own catalog tier ABOVE this one, so they still win.
              receiver_descriptor(receiver.base)
            when Type::Dynamic
              receiver_descriptor(receiver.static_facet)
            end
          end

          # ADR-48 — project a `Data`/`Struct` member carrier to its tagging class (or the `Data`/`Struct`
          # supertype) so non-member calls (`inspect`, `==`, `frozen?`, ...) resolve through RBS rather
          # than mis-firing undefined-method. Precise member reads were already folded by DataFolding /
          # StructFolding above this tier.
          def member_carrier_descriptor(receiver)
            case receiver
            when Type::DataInstance then [receiver.class_name || "Data", :instance, []]
            when Type::DataClass then [receiver.class_name || "Data", :singleton, []]
            when Type::StructInstance then [receiver.class_name || "Struct", :instance, []]
            when Type::StructClass then [receiver.class_name || "Struct", :singleton, []]
            end
          end

          def tuple_type_args(tuple)
            return [] if tuple.elements.empty?

            [Type::Combinator.union(*tuple.elements)]
          end

          def hash_shape_type_args(shape)
            return [] if shape.pairs.empty?

            key_types = shape.pairs.keys.map { |k| Type::Combinator.constant_of(k) }
            value_types = shape.pairs.values
            [
              Type::Combinator.union(*key_types),
              Type::Combinator.union(*value_types)
            ]
          end

          # True when the RBS method definition is `private`. A call with an explicit, non-`self` receiver
          # cannot reach a private method (Ruby raises `NoMethodError`), so the explicit-receiver
          # user-class fallback uses this to reject private signatures rather than return a wrong type.
          def method_private?(method_definition)
            method_definition.respond_to?(:accessibility) &&
              method_definition.accessibility == :private
          end

          def lookup_method(environment, class_name, kind, method_name, scope = nil)
            direct = lookup_method_on(environment, class_name, kind, method_name)
            return direct if direct

            # ADR-43 — scoped inherited-method resolution. The direct lookup misses when `class_name` is a
            # Ruby-source subclass absent from RBS (so no ancestor walk runs). If its discovered
            # superclass chain reaches an allow-listed RBS-complete ancestor, resolve the method there so
            # inherited contract calls (`self.manifest` on a plugin) resolve and the normal call rules
            # apply. Bounded to the allow-list, so open hierarchies stay on the Dynamic fallback (no false
            # positive on `< ActionController::Base`).
            ancestor = allowed_rbs_complete_ancestor(environment, class_name, scope)
            return nil unless ancestor

            lookup_method_on(environment, ancestor, kind, method_name)
          end

          def lookup_method_on(environment, class_name, kind, method_name)
            case kind
            when :instance
              Rigor::Reflection.instance_method_definition(class_name, method_name, environment: environment)
            when :singleton
              Rigor::Reflection.singleton_method_definition(class_name, method_name, environment: environment)
            end
          end

          # The first allow-listed, RBS-complete ancestor reachable from `class_name` through
          # `scope.discovered_superclasses`, or nil. Returns nil when no scope is threaded, when
          # `class_name` is itself RBS-known (the direct lookup already had authority), or when the
          # discovered chain reaches no allow-listed class. The walk carries a visited set so a malformed
          # cyclic `A < B < A` source cannot loop.
          def allowed_rbs_complete_ancestor(environment, class_name, scope)
            return nil if scope.nil?
            return nil if Rigor::Reflection.rbs_class_known?(class_name, environment: environment)

            supers = scope.discovered_superclasses
            seen = {}
            current = supers[class_name.to_s]
            until current.nil? || seen[current]
              return current if ALLOWED_RBS_COMPLETE_ANCESTORS.include?(current)

              seen[current] = true
              current = supers[current]
            end
            nil
          end

          # Slice 4 phase 2d substitution map. Zips the class's declared type-parameter names against the
          # receiver's `type_args`. Returns an empty hash when either side is empty or when arities
          # disagree -- in both cases free variables in the method's return type degrade to `Dynamic[Top]`
          # per the translator's contract.
          def build_type_vars(environment, class_name, receiver_args)
            return {} if receiver_args.empty?

            param_names = Rigor::Reflection.class_type_param_names(class_name, environment: environment)
            return {} if param_names.empty?
            return {} if param_names.size != receiver_args.size

            param_names.zip(receiver_args).to_h
          end

          # rubocop:disable Metrics/ParameterLists
          def translate_return_type(method_definition, class_name:, kind:, args:, type_vars:, block_type:,
                                    method_name: nil, environment: nil, self_type_override: nil,
                                    scope: nil, call_node: nil)
            # rubocop:enable Metrics/ParameterLists
            # Slice 4b-3 (ADR-7 § "Slice 4-A/4-B") — read the return-type override through the merger so
            # future plugin / `:rbs_extended` bundles that also assert a `return_type` slot at this call
            # site compose with the RBS::Extended directive instead of silently racing it.
            override = merged_return_type(method_definition, environment: environment)
            return override if override

            instance_type = Type::Combinator.nominal_of(class_name)
            resolved_self_type =
              case kind
              when :singleton then Type::Combinator.singleton_of(class_name)
              else                 instance_type
              end
            # `self_type_override` lets the user-class fallback path preserve the ORIGINAL receiver as the
            # substitute for `Bases::Self` — so `Kernel#dup: () -> self` resolved through the Object
            # fallback returns the caller's type, not Object.
            self_type = self_type_override || resolved_self_type

            method_type = OverloadSelector.select(
              method_definition,
              arg_types: args,
              self_type: self_type,
              instance_type: instance_type,
              type_vars: type_vars,
              block_required: !block_type.nil?,
              environment: environment
            )
            return nil unless method_type

            call_site = [class_name, method_name, kind]
            record_dispatch_provenance(method_definition, method_type, scope, call_node, call_site)
            full_type_vars = compose_type_vars(method_type, type_vars, args, block_type, scope, call_node, call_site)

            RbsTypeTranslator.translate(
              method_type.type.return_type,
              self_type: self_type,
              instance_type: instance_type,
              type_vars: full_type_vars
            )
          end

          # The two provenance side-tables the return-typing tier is the last place able to populate, recorded
          # together because they share one gate (`scope` && `call_node`) and one call site.
          #
          # ADR-100 WD2/WD3 — the return-typing tier is where `void → top` widens, so it is the one place that
          # still knows the RBS return was an author-declared `-> void` before the translator erases it to a
          # plain `top`. The recovery lands on the scope's `void_origins` side-table, keyed by the call node,
          # so the `static.value-use.void` check rule can fire when this `top` is used in value context. The
          # gate naturally scopes it to the *direct*-RBS dispatch (the receiver's own resolvable class): the
          # user-class / Object ancestor fallback nils both out (WD4 defers that, murkier, surface).
          #
          # Issue #286 — the same call site is the one place that still knows the selected overload spelled
          # its miss as `%a{implicitly-returns-nil}` rather than as `?`; the translator reads the return type
          # only, by the deliberate choice the spec records. Mark the result so a certainty judgment
          # downstream can tell "nil-free because of its class" from "nil-free because we bet".
          def record_dispatch_provenance(method_definition, method_type, scope, call_node, call_site)
            record_void_recovery(method_type, scope, call_node, call_site)
            record_optimistic_nil_free(method_definition, method_type, scope, call_node)
          end

          # The two method-level type-parameter binding positions, layered in precedence order over the
          # receiver-derived `type_vars`: the block return type first, then the argument positions (which
          # never displace an existing key). See {#compose_arg_type_vars} for the argument envelope.
          def compose_type_vars(method_type, type_vars, args, block_type, scope, call_node, call_site)
            vars = compose_block_type_vars(method_type, type_vars, block_type)
            compose_arg_type_vars(method_type, vars, args, scope: scope, call_node: call_node,
                                                           call_site: call_site)
          end

          # Record the `void → top` recovery when the selected overload declares `-> void` and both `scope` and
          # `call_node` are present (the direct-dispatch path). `void_site` is the `[class_name, method_name,
          # kind]` triple the {VoidOrigin} carries.
          def record_void_recovery(method_type, scope, call_node, void_site)
            return unless scope && call_node && void_return?(method_type)

            class_name, method_name, kind = void_site
            scope.record_void_origin(
              call_node,
              VoidOrigin.new(class_name: class_name, method_name: method_name, kind: kind)
            )
          end

          # Issue #286 — record that this value's nil-freeness is a bet rather than a class property. Gated on
          # `scope` && `call_node` exactly as {#record_void_recovery} is, which scopes it to the direct-RBS
          # dispatch path.
          def record_optimistic_nil_free(method_definition, method_type, scope, call_node)
            return unless scope && call_node
            return unless OptimisticOrigin.optimistic_overload?(method_definition, method_type)

            scope.record_optimistic_origin(call_node, OptimisticOrigin::IMPLICITLY_RETURNS_NIL)
          end

          def void_return?(method_type)
            fun = method_type.type
            fun.respond_to?(:return_type) && fun.return_type.is_a?(RBS::Types::Bases::Void)
          end

          # ADR-7 § "Slice 4-A/4-B" — folds the `RBS::Extended` `return:` directive (and any other
          # `return_type`-bearing contribution future slices add at this call site) through the merger
          # before consuming. Returns the merged return type or nil when no contribution overrides the
          # RBS-declared return.
          def merged_return_type(method_definition, environment: nil)
            contribution = RbsExtended.read_flow_contribution(method_definition, environment: environment)
            return nil if contribution.nil?

            Rigor::FlowContribution::Merger.merge([contribution]).return_type
          end

          # When a block type is supplied, locate the method-level type parameter that the selected
          # overload's block return type references and bind it to `block_type`. The contribution layers
          # on top of the receiver-derived `type_vars` so a method like
          # `def map[U] { (Elem) -> U } -> Array[U]` resolves `Elem` from the receiver and `U` from the
          # block return type at the same call site. Anything outside this exact shape (no block clause,
          # an `untyped` block, a non-variable block return type, a variable not declared in
          # `type_params`) returns the original `type_vars` so fallbacks stay consistent.
          def compose_block_type_vars(method_type, type_vars, block_type)
            return type_vars if block_type.nil?

            block_var_name = method_type_block_return_variable(method_type)
            return type_vars if block_var_name.nil?

            type_vars.merge(block_var_name => block_type)
          end

          # Issue #303 — bind method-level type parameters from ARGUMENT positions, layering on top of the
          # receiver-derived and block-derived `type_vars` exactly as {#compose_block_type_vars} does, so
          # `Ractor.make_shareable("x")` (`[T] (T) -> T`) answers `"x"` instead of `Dynamic[top]`.
          #
          # Envelope, deliberately the narrowest sound shape:
          #
          # * only a positional parameter (required or optional) whose declared type is EXACTLY
          #   `RBS::Types::Variable` — no container walk, so `(Array[T]) -> T` still degrades;
          # * only names the SELECTED overload declares in its own `type_params` (a class-level variable
          #   keeps its receiver-derived binding);
          # * an existing key wins, so the receiver and the block return type both outrank an argument;
          # * a `Dynamic[Top]` argument carries no evidence and contributes nothing;
          # * repeated occurrences of one variable union their arguments.
          #
          # See {#arg_binding_permitted?} for why the contribution is gated on the call site.
          def compose_arg_type_vars(method_type, type_vars, args, scope:, call_node:, call_site:)
            bindings = arg_type_var_bindings(method_type, type_vars, args)
            return type_vars if bindings.empty?
            return type_vars unless arg_binding_permitted?(scope, call_node, call_site)

            type_vars.merge(bindings)
          end

          # The candidate bindings, computed before the guard so a non-generic overload (the overwhelming
          # majority) never pays for the `scope` probes.
          def arg_type_var_bindings(method_type, type_vars, args)
            declared = declared_type_param_names(method_type)
            return EMPTY_TYPE_VARS if declared.empty? || args.empty?

            fun = method_type.type
            return EMPTY_TYPE_VARS unless fun.respond_to?(:required_positionals)

            positionals = fun.required_positionals + fun.optional_positionals
            positionals.zip(args).each_with_object({}) do |(param, arg), bindings|
              next if arg.nil?

              name = variable_param_name(param, declared, type_vars)
              next if name.nil?
              next if no_static_evidence?(arg)

              bindings[name] = bindings.key?(name) ? Type::Combinator.union(bindings[name], arg) : arg
            end
          end

          def declared_type_param_names(method_type)
            params = method_type.respond_to?(:type_params) ? method_type.type_params : nil
            return EMPTY_TYPE_PARAM_NAMES if params.nil? || params.empty?

            params.map(&:name)
          end

          # The parameter's binding name when it is spelled as a bare method-level type variable that is
          # still unbound; nil for every other shape.
          def variable_param_name(param, declared, type_vars)
            declared_type = param.type
            return nil unless declared_type.is_a?(RBS::Types::Variable)

            name = declared_type.name
            return nil unless declared.include?(name)
            return nil if type_vars.key?(name)

            name
          end

          # `Dynamic[top]` is the engine's "we could not tell" answer, so binding a variable to it would
          # dress up an absence of evidence as an inference. The variable stays unbound and degrades as it
          # did before, which is the same value anyway.
          def no_static_evidence?(arg)
            arg.is_a?(Type::Dynamic) && arg.static_facet.is_a?(Type::Top)
          end

          # Issue #303 — the FP guard on the argument-position binding.
          #
          # Binding an argument makes the RESULT precise, which turns a benign mis-resolution into a
          # confidently wrong type. The shape that matters is a user method shadowing the RBS method this
          # dispatch resolved: `spec/integration/fixtures/kernel_functions.rb`'s `def p(node)` self-send
          # resolves through `Kernel#p: [T] (T) -> T`, and binding `T` would type `p(1)` as `1` when the
          # real method returns a String.
          #
          # Two gates, cheapest first.
          #
          # 1. `scope` && `call_node` present, the same evidence surface {#record_void_recovery} reads.
          #    DIAGNOSED, not assumed: that fixture's `p(1)` reaches here through
          #    `MethodDispatcher#try_user_class_fallback`, which dispatches with `scope: nil, call_node:
          #    nil` — so the presence gate alone already declines every call routed through the Object /
          #    Kernel ancestor fallback, the path a class with no RBS of its own always takes.
          # 2. The explicit redefinition probe, in the shape `KernelDispatch#user_redefined?` established.
          #    The presence gate does NOT cover the direct-dispatch spelling of the same hazard — a
          #    top-level `def p(x)` called from the top level resolves `Nominal[Object]` DIRECTLY, with
          #    scope and call node both live — so a discovered top-level def, or a discovered method on the
          #    resolved class itself, declines too. Over-wide by construction (a project class that also
          #    has RBS declines for its own self-sends, losing precision it could have kept), and
          #    deliberately so: the cost is a `Dynamic[top]` that was already there.
          def arg_binding_permitted?(scope, call_node, call_site)
            return false if scope.nil? || call_node.nil?

            class_name, method_name, kind = call_site
            return false if method_name.nil?
            return false if scope.top_level_def_for(method_name)

            !scope.discovered_method?(class_name, method_name, kind)
          end

          def method_type_block_return_variable(method_type)
            return_variable = block_return_variable(method_type)
            return nil if return_variable.nil?

            params = method_type.respond_to?(:type_params) ? method_type.type_params : []
            return nil if params.nil?
            return nil unless params.any? { |tp| tp.name == return_variable.name }

            return_variable.name
          end

          def block_return_variable(method_type)
            block = method_type.respond_to?(:block) ? method_type.block : nil
            return nil if block.nil?

            fun = block.type
            return nil unless fun.respond_to?(:return_type)

            return_type = fun.return_type
            return_type.is_a?(RBS::Types::Variable) ? return_type : nil
          end

          # ----- block parameter probe (Phase C sub-phase 1) -----

          def probe_block_param_types(receiver:, method_name:, args:, environment:)
            args ||= []
            case receiver
            when Type::Union then probe_block_param_types_union(receiver, method_name, args, environment)
            else                  probe_block_param_types_one(receiver, method_name, args, environment)
            end
          end

          # For a union receiver we keep the conservative answer: only return block param types when every
          # member resolves the same arity and types (otherwise the call sites would have to thread
          # per-member binders, which the slice does not support yet). Mismatches degrade to the empty
          # array so the binder defaults all params to Dynamic[Top].
          def probe_block_param_types_union(receiver, method_name, args, environment)
            results = receiver.members.map do |member|
              probe_block_param_types_one(member, method_name, args, environment)
            end
            return [] if results.empty?
            return [] unless results.all? { |r| r == results.first }

            results.first
          end

          def probe_block_param_types_one(receiver, method_name, args, environment)
            descriptor = receiver_descriptor(receiver)
            return [] unless descriptor

            class_name, kind, receiver_args = descriptor
            method_definition = lookup_method(environment, class_name, kind, method_name)
            return [] unless method_definition

            type_vars = build_type_vars(environment, class_name, receiver_args)
            extract_block_param_types(
              method_definition,
              class_name: class_name,
              kind: kind,
              args: args,
              type_vars: type_vars,
              environment: environment
            )
          rescue StandardError
            []
          end

          def extract_block_param_types(method_definition, class_name:, kind:, args:, type_vars:,
                                        environment: nil)
            instance_type = Type::Combinator.nominal_of(class_name)
            self_type =
              case kind
              when :singleton then Type::Combinator.singleton_of(class_name)
              else                 instance_type
              end

            method_type = OverloadSelector.select(
              method_definition,
              arg_types: args,
              self_type: self_type,
              instance_type: instance_type,
              type_vars: type_vars,
              block_required: true,
              environment: environment
            )
            return [] unless method_type

            block = method_type.respond_to?(:block) ? method_type.block : nil
            return [] unless block

            translate_block_positional_params(
              block,
              self_type: self_type,
              instance_type: instance_type,
              type_vars: type_vars
            )
          end

          # `RBS::Types::Block#type` is normally an `RBS::Types::Function` carrying the block's parameter
          # list; some signatures use `RBS::Types::UntypedFunction` (a `(?)` block) which exposes no
          # parameter types -- we treat it as "no information" and return an empty array so the binder
          # defaults every slot.
          def translate_block_positional_params(block, self_type:, instance_type:, type_vars:)
            fun = block.type
            return [] unless fun.respond_to?(:required_positionals)

            params = fun.required_positionals + fun.optional_positionals
            params.map do |param|
              RbsTypeTranslator.translate(
                param.type,
                self_type: self_type,
                instance_type: instance_type,
                type_vars: type_vars
              )
            end
          end
        end
        # rubocop:enable Metrics/ClassLength
      end
      # rubocop:enable Metrics/ModuleLength
    end
  end
end
