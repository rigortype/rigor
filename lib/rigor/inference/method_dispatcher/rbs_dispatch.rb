# frozen_string_literal: true

require_relative "../../reflection"
require_relative "../../type"
require_relative "../../rbs_extended"
require_relative "../range_constant"
require_relative "../rbs_type_translator"
require_relative "../external_ancestor_resolution"
require_relative "../void_origin"
require_relative "../optimistic_origin"
require_relative "overload_selector"
require_relative "self_substitute"

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
      # * Keyword arguments reach `args` only as one trailing hash entry and are not matched against keyword
      #   parameters, so overloads with required keywords are skipped.
      # * Method-level type parameters bind only from two positions: the block return type (Slice 6 phase C)
      #   and a positional parameter whose declared type is EXACTLY a type variable (issue #303 —
      #   `def foo[T]: (T) -> T` binds `T` from the first argument, and carries it into a generic return
      #   such as `-> Array[T]`). A variable reachable only through a container position (`Array[T] arg`),
      #   a rest positional (`*T`), or a keyword parameter is still unbound and degrades to `Dynamic[Top]`.
      #   A block-return variable that a parameter also names takes the value class the argument and the
      #   block share once the call passes an argument, or stays unbound when they share none (see
      #   {compose_block_type_vars}).
      #
      # See docs/adr/4-type-inference-engine.md for the broader plan.
      # rubocop:disable-next Metrics/ModuleLength
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

        # Issue #1094 — the methods through which a value can answer Ruby's implicit `to_ary` conversion.
        # Multiple assignment and block auto-splat convert through `rb_check_array_type`, which calls
        # `to_ary` when defined and otherwise asks `respond_to_missing?`, dispatching to `method_missing`
        # when that answers true — so a `Delegator` destructures its target without defining `to_ary`.
        ARRAY_CONVERSION_HOOKS = %i[to_ary method_missing respond_to_missing?].freeze

        # The owners whose declarations of those hooks are the defaults rather than an override:
        # `BasicObject#method_missing` raises and `Kernel#respond_to_missing?` answers false.
        ARRAY_CONVERSION_DEFAULT_OWNERS = %w[::BasicObject ::Object ::Kernel].freeze

        # Core value classes whose instances never convert — the answer with no RBS environment to hand.
        ARRAY_CONVERSION_FREE_CORE_CLASSES = %w[
          Integer Float Symbol String Hash Range Regexp Proc NilClass TrueClass FalseClass
        ].freeze

        # The classes `Array` itself inherits from. A `Nominal[Object]` is routinely an array at runtime, so
        # the RBS walk below, which reads the named class's own ancestry, cannot vouch for them.
        ARRAY_SUPERCLASSES = %w[Object BasicObject].freeze

        # Issue #1094 — whether an instance of `class_name` provably has no implicit array conversion, so
        # `a, b = value` binds `a` to the value and `b` to `nil` rather than splatting it. Shares ADR-43's
        # rationale for when an RBS ancestry is closed: the RBS of a class the environment KNOWS is the method
        # set every other negative rule already trusts (`call.undefined-method` fires on it), while a class the
        # environment does not know — a Ruby-source class, whatever it inherits — is an open hierarchy and
        # declines, exactly as ADR-43 keeps it on the Dynamic fallback. Modules and `Array`'s own superclasses
        # decline because a value of those types is routinely something else. A project `def` of any hook on
        # the class, its source ancestors, or the default owners declines too: the project's source outranks
        # the RBS it did not write. Without a `scope` only the core list answers.
        def array_conversion_free?(class_name, scope)
          name = class_name.to_s.delete_prefix("::")
          return false if project_defines_array_conversion?(name, scope)
          return true if ARRAY_CONVERSION_FREE_CORE_CLASSES.include?(name)
          return false if scope.nil? || ARRAY_SUPERCLASSES.include?(name)

          rbs_ancestry_array_conversion_free?(name, scope.environment)
        end

        # ADR-17's boundary for what the project's source can add to a class: a `def` in the analysed file
        # (`Scope#discovered_method*`, walked through the source ancestry) or in a `pre_eval:` file
        # (`Environment#project_patched_methods`). Both are asked about the class, its RBS ancestors and the
        # default owners, because a hook added to any of them reaches the instance.
        def project_defines_array_conversion?(name, scope)
          return false if scope.nil?

          owners = [name, *rbs_instance_ancestor_names(name, scope.environment),
                    *ARRAY_CONVERSION_DEFAULT_OWNERS.map { |owner| owner.delete_prefix("::") }].uniq
          patched = scope.environment&.project_patched_methods
          patched = nil if patched && patched.empty?
          ARRAY_CONVERSION_HOOKS.any? do |hook|
            scope.discovered_method_through_ancestors?(name, hook, :instance) ||
              owners.any? do |owner|
                scope.discovered_method?(owner, hook, :instance) ||
                  !patched&.lookup(class_name: owner, method_name: hook, kind: :instance).nil?
              end
          end
        end

        def rbs_instance_ancestor_names(name, environment)
          return [] if environment.nil? || !Rigor::Reflection.rbs_class_known?(name, environment: environment)

          definition = Rigor::Reflection.instance_definition(name, environment: environment)
          return [] if definition.nil?

          definition.ancestors.ancestors.map { |ancestor| ancestor.name.to_s.delete_prefix("::") }
        end

        def rbs_ancestry_array_conversion_free?(name, environment)
          return false if environment.nil?
          return false unless Rigor::Reflection.rbs_class_known?(name, environment: environment)
          return false if environment.rbs_module?(name)

          definition = Rigor::Reflection.instance_definition(name, environment: environment)
          return false if definition.nil?

          ARRAY_CONVERSION_HOOKS.none? do |hook|
            method = definition.methods[hook]
            method && !ARRAY_CONVERSION_DEFAULT_OWNERS.include?(method.defined_in.to_s)
          end
        end

        # Shared empty returns for the argument-position type-variable binding (issue #303). The
        # no-candidate answer is by far the common case — every non-generic overload takes it — so it must
        # not allocate.
        EMPTY_TYPE_VARS = {}.freeze
        private_constant :EMPTY_TYPE_VARS
        EMPTY_TYPE_PARAM_NAMES = [].freeze
        private_constant :EMPTY_TYPE_PARAM_NAMES
        NO_BINDING = [nil, nil].freeze
        private_constant :NO_BINDING
        EMPTY_ARGUMENT_NODES = [].freeze
        private_constant :EMPTY_ARGUMENT_NODES

        # The classes {#shared_value_class} admits. Given an argument of the same class, each one's `+`
        # answers that class for every receiver, subclass instances included (`String#+` answers a String;
        # the numeric classes have no instances of a subclass). `class Name < String` is left out, since the
        # `+` it inherits answers a plain String, and so is any class whose `coerce` may make `+` answer a
        # third one.
        CLOSED_VALUE_CLASSES = Set["Integer", "Float", "Rational", "Complex", "String"].freeze
        private_constant :CLOSED_VALUE_CLASSES

        # Both spellings a resolved `RBS::Types::ClassInstance#name` — or a `Nominal#class_name` built
        # from one — may carry for `Range`; core signatures absolutise, but a plugin-contributed one
        # need not.
        RANGE_TYPE_NAMES = ["::Range", "Range"].freeze
        private_constant :RANGE_TYPE_NAMES

        # Four fields of `context` shape the answer beyond receiver, method name and arguments.
        #
        # `block_type` is the inferred block return type propagated from `MethodDispatcher.dispatch`; when
        # non-nil, the selector prefers a block-bearing overload and binds the method-level type parameter
        # that the block's return type references to it (Slice 6 phase C sub-phase 2).
        #
        # `self_type_override`, when set, is the substitution for `Bases::Self` in the method's return type.
        # `MethodDispatcher#try_user_class_fallback` uses it to preserve the ORIGINAL receiver as the
        # substitute for `self` even though the dispatch is routed through `Nominal[Object]` — so that
        # `Bundler::URI::Generic.dup` (which resolves through the `Object` fallback because
        # `Bundler::URI::Generic` lacks RBS) returns `Bundler::URI::Generic` per `Kernel#dup: () -> self`
        # rather than `Object`. Nil computes self from the resolved class_name as before.
        #
        # `public_only`, when true, keeps a method whose RBS accessibility is `:private` from resolving (the
        # call yields `nil`, i.e. "no rule"). Set by the explicit-non-`self`-receiver user-class fallback so
        # a call like `Favourite.select(...)` does not adopt the private `Kernel#select` signature.
        #
        # `scope`, when supplied, enables ADR-43 RBS-complete-ancestor resolution against
        # `ALLOWED_RBS_COMPLETE_ANCESTORS`; `nil` keeps inherited calls unresolved (`Dynamic[Top]`) — the
        # FP-safe default for open hierarchies (`< ActionController::Base`, …).
        #
        # @return inferred return type, or `nil` when no rule resolves (no class name,
        #   no method, dispatch on a Top/Dynamic[Top] receiver, etc.).
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
        # @return positional block parameter types.
        def block_param_types(context)
          environment = context.environment
          return [] if environment.nil?
          return [] unless environment.rbs_loader

          probe_block_param_types(
            receiver: context.receiver,
            method_name: context.method_name,
            args: context.args,
            environment: environment,
            scope: context.scope
          )
        end

        # rubocop:disable-next Metrics/ClassLength
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
            method_definition = lookup_method(environment, class_name, kind, method_name, scope,
                                              call_node: call_node)
            return nil unless method_definition
            return nil if public_only && method_private?(method_definition)
            # Issue #823 — a declaration that states the member's presence and parameters but not its
            # return (`%a{rigor:v1:inferred-return}`, written by `rigor-rbs-inline` on every type slot it
            # DEFAULTED). Declining here is the whole mechanism: this tier's product IS the return type, so
            # withholding it routes the call down the same tiers an undeclared method takes and the body
            # gets typed. Everything the declaration DOES say survives, because the rules that read it —
            # `call.undefined-method`, `call.wrong-arity`, argument-type checking — look the method up in
            # the environment themselves rather than reading this tier's answer.
            return nil if RbsExtended.inferred_return?(method_definition)
            return SPACESHIP_ENVELOPE if inherited_identity_spaceship?(method_definition, class_name, kind, method_name)

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
              self_type_override: self_type_override ||
                                  SelfSubstitute.for(receiver, receiver_args, method_name, args, block_type),
              scope: scope,
              call_node: call_node
            )
          rescue StandardError
            # Defensive: if RBS' definition builder raises on a broken hierarchy (e.g., partially loaded
            # user signatures), the dispatcher MUST stay fail-soft.
            nil
          end

          # Issue #661 — `Kernel#<=>: (untyped other) -> 0?` is the IDENTITY comparison: `0` when the two
          # are the same object, `nil` otherwise, and correct as written for a bare `Object`. Reached by
          # inheritance it stops being a statement about the call. `1.day <=> 2.days` typed as `0?`, and a
          # `Money` whose signature says `include Comparable` — whose whole contract is that the includer
          # defines `<=>` — typed the same, because neither declares `<=>` of its own and every class
          # inherits Kernel's.
          #
          # `0?` is a VALUE claim, so the cost is not confined to the expression: narrowing
          # `n = a <=> b; n.negative? if n` reads the truthy arm as the literal `0`, folds `0.negative?`
          # to false, and answers `bot` for a branch the runtime takes on every ordered pair. That is one
          # `clause.unreachable` away from a false positive on correct code.
          #
          # Widened rather than declined: `Integer?` is the envelope Ruby's own `<=>` convention states and
          # the one upstream rbs writes wherever a class DOES declare the operator (`Array`, `Module`,
          # `Complex`). It is a supertype of `0?`, so this only ever removes a conclusion — and it removes
          # exactly the conclusions that rested on the receiver not overriding an operator its signature
          # was never required to mention (ADR-5: a partially-declared class is not a closed world).
          #
          # Bounded to the three classes that OWN the identity comparison, where the claim is the truth
          # about the receiver rather than an artifact of inheritance, and to `<=>` alone — the general
          # question of what an inherited Object/Kernel signature may assert about a subclass is much
          # larger, and `to_s` / `hash` / `inspect` do not carry a value-precise return to lose.
          SPACESHIP_IDENTITY_OWNERS = %w[Kernel Object BasicObject].to_set.freeze
          private_constant :SPACESHIP_IDENTITY_OWNERS

          SPACESHIP_ENVELOPE = Type::Combinator.union(
            Type::Combinator.nominal_of("Integer"),
            Type::Combinator.constant_of(nil)
          ).freeze
          private_constant :SPACESHIP_ENVELOPE

          def inherited_identity_spaceship?(method_definition, class_name, kind, method_name)
            return false unless method_name == :<=>
            return false unless kind == :instance
            return false if SPACESHIP_IDENTITY_OWNERS.include?(class_name.to_s.delete_prefix("::"))
            return false unless method_definition.respond_to?(:defined_in)

            SPACESHIP_IDENTITY_OWNERS.include?(method_definition.defined_in.to_s.delete_prefix("::"))
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
            when Type::FloatRange
              # ADR-109 WD4 — a bounded Float is a Float for every method the fold tiers do not own.
              ["Float", :instance, []]
            when Type::IntegerRange
              # #842 — a bounded Integer is an Integer for every method the fold tiers
              # (ConstantFolding, ShapeDispatch#dispatch_integer_range) do not own.
              ["Integer", :instance, []]
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

          # An open shape's unseen keys may hold any value (rbs-erasure.md § *Open shapes with extra-value
          # bounds*), so its projection carries a `Dynamic[top]` arm on both sides. Without it every read the
          # shape tier does not answer — a `Union` receiver, a non-literal key — took the known values for a
          # key outside them: `h = { a: 1 }; h.default = 0 if flag; h[:b] == 1` folded always-truthy.
          def hash_shape_type_args(shape)
            return [] if shape.pairs.empty?

            key_types = shape.pairs.keys.map { |k| Type::Combinator.constant_of(k) }
            value_types = shape.pairs.values
            if shape.open?
              key_types += [Type::Combinator.untyped]
              value_types += [Type::Combinator.untyped]
            end
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

          def lookup_method(environment, class_name, kind, method_name, scope = nil, call_node: nil)
            direct = lookup_method_on(environment, class_name, kind, method_name)
            return direct if direct

            # Issue #1173 — the include-edge sibling of the superclass bridges below: a discovered
            # class's `include M` where M is RBS-known resolves M's declaration here. It runs BEFORE
            # them because an include edge precedes the superclass edge in the MRO (`Sub < Hash` with
            # `include M` chains `Sub → M → Hash`): when both a nearer mixin and a bridged ancestor
            # declare the name, the mixin is the method that runs. See {#included_module_method}.
            included = included_module_method(environment, class_name, kind, method_name, scope)
            return included if included

            # ADR-43 — scoped inherited-method resolution. The direct lookup misses when `class_name` is a
            # Ruby-source subclass absent from RBS (so no ancestor walk runs). If its discovered
            # superclass chain reaches an allow-listed RBS-complete ancestor, resolve the method there so
            # inherited contract calls (`self.manifest` on a plugin) resolve and the normal call rules
            # apply. Bounded to the allow-list, so open hierarchies stay on the Dynamic fallback (no false
            # positive on `< ActionController::Base`).
            ancestor = allowed_rbs_complete_ancestor(environment, class_name, kind, method_name, scope)
            return lookup_method_on(environment, ancestor, kind, method_name) if ancestor

            # `extend M` in a class/module body lifts M's INSTANCE surface onto the extending object's
            # singleton — `class F; extend T::Sig; sig { ... }; end` resolves `sig` through
            # `T::Sig#sig`. Same contract as the superclass bridge: only allow-listed (manifest
            # `rbs_complete_extends:`) modules qualify, so open hierarchies stay on Dynamic.
            if kind == :singleton
              mod = allowed_rbs_complete_extended_module(environment, class_name, method_name, scope,
                                                         call_node)
              return lookup_method_on(environment, mod, :instance, method_name) if mod
            end

            # Issue #527 slice 1 — the same shape, one RBS ancestry wider: a Ruby-source subclass of a
            # CORE or STDLIB class (`class SubHash < Hash`, `< StandardError`, `< ::StringScanner`)
            # resolves its inherited calls there. Injected HERE rather than as a new tier because
            # `dispatch_one` keys `self`, `instance`, the type-variable map and `SelfSubstitute` on the
            # RECEIVER's class name, so changing only the lookup gets the correct binding for free.
            core_stdlib_ancestor_method(environment, class_name, kind, method_name, scope)
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
          #
          # ADR-43 WD4 — the allow-list's manifest-declared half: a loaded plugin may name its own
          # contract classes in `rbs_complete_ancestors:` (e.g. rigor-graphql's `GraphQL::Schema::Object`),
          # extending the engine's hard-coded seed without editing this constant.
          def allowed_rbs_complete_ancestor(environment, class_name, kind, method_name, scope)
            return nil if scope.nil?
            return nil if Rigor::Reflection.rbs_class_known?(class_name, environment: environment)

            # A project `def` on the receiver class or on a nearer source ancestor shadows the
            # bridged declaration. RBS dispatch runs before the discovered-method tier, so without
            # this guard the bridge would resolve e.g. `field` on `GraphQL::Schema::Object` while
            # the runtime actually calls a user `def self.field` on an intermediate `BaseObject` —
            # a wrong return type and a false `undefined-method`/arity reading downstream.
            return nil if scope.discovered_method?(class_name, method_name, kind)

            registry = environment&.plugin_registry
            each_source_ancestor_candidate(scope, class_name) do |candidate|
              return nil if scope.discovered_method?(candidate, method_name, kind)
              return candidate if ALLOWED_RBS_COMPLETE_ANCESTORS.include?(candidate) ||
                                  registry&.rbs_complete_ancestor?(candidate)
            end
            nil
          end

          # Issue #527 slice 1 — the RBS instance definition a Ruby-source class inherits from a CORE or
          # STDLIB ancestor, or nil. `Oj::EasyHash < Hash` answering `Dynamic[top]` to `has_key?` while
          # `{}.has_key?` folds was the largest single opacity family in the 2026-09-01 corpus sweep.
          #
          # Why this is not ADR-43's rejected alternative A. That ADR declined blanket inherited
          # resolution because firing `call.undefined-method` against a PARTIAL gem RBS "would frighten
          # working code". Two things narrow it here. The ancestry is core / stdlib, whose RBS is the
          # method set every negative rule already trusts for a direct receiver of it. And the negative
          # rules do not reach these receivers anyway: `undefined_method_diagnostic` and
          # `arity_envelope_for` gate on `Reflection.rbs_class_known?` of the RECEIVER, which a
          # Ruby-source subclass never is. So the risk this arm carries is not a new firing but a
          # WRONG PRECISE TYPE propagating one hop — which is what the declines below are about.
          #
          # The declines, in order of what they protect:
          #
          # * `class_name` itself RBS-known — the direct lookup already had authority.
          # * an ADR-26 plugin-declared open receiver, whose surface is larger than its declarations.
          # * the subclass or a nearer SOURCE ancestor declares the name (ADR-110): the runtime calls
          #   the project's `def`, and resolving the inherited declaration would answer about a method
          #   that never runs. Asked of both discovery tables, because neither sees the whole of what a
          #   `def` / `attr_*` / `define_method` / `alias` contributes, and both suppress on budget
          #   exhaustion rather than answering "not declared" from an unfinished walk.
          # * the walked ancestor, or the class the declaration is actually written on, is not core /
          #   stdlib. That is what keeps `class MyController < ActionController::Base` on `Dynamic[top]`
          #   (no RBS at all), and a subclass of an RBS-shipping GEM there too — slice 3's question.
          # * an ADR-17 `pre_eval:` patch declares the name on the receiver or on any ancestor of the
          #   owner: the project has replaced the very method whose declaration this would adopt.
          #
          # Type variables are NOT inferred: a `Nominal[SubHash]` receiver carries no type arguments, so
          # `build_type_vars` yields the empty map and `Hash[K, V]`'s free variables degrade to
          # `Dynamic[top]` per the translator's contract. `SubHash#keys` is `Array[Dynamic[top]]`, which
          # is exactly what a raw `Hash` receiver already answers — honest rather than a loss.
          def core_stdlib_ancestor_method(environment, class_name, kind, method_name, scope)
            return nil if scope.nil? || kind != :instance
            return nil if environment.nil?

            memo = core_stdlib_memo(environment, scope)
            key = [class_name.to_s, method_name.to_sym]
            return memo[key] if memo&.key?(key)

            answer = compute_core_stdlib_ancestor_method(environment, class_name, method_name, scope)
            memo[key] = answer if memo
            answer
          end

          # Issue #1173 — the include-edge sibling of {#core_stdlib_ancestor_method}: a discovered
          # class's `include M` where M is RBS-known (a project `sig/`, bundled core / stdlib, or a
          # shipped gem signature) resolves M's declaration here. Ruby inserts an included module into
          # the ancestor chain outright, so adopting its declaration is the dispatch the runtime
          # performs — unlike the superclass arm there is no "which classes may be read as complete"
          # question, only the usual shadow guards: a project `def` on the receiver or a nearer
          # ancestor, an outside-the-body `include` / `class_eval` mark (#992), or an ADR-17 `pre_eval:`
          # patch each mean the declaration found is not the method that runs.
          #
          # The walk reuses {ExternalAncestorResolution} with `mixins: true` — an include edge precedes
          # the superclass edge at each BFS node, matching the MRO — and the answer is adopted ONLY
          # when the resolved owner is an RBS module (`environment.rbs_module?`). A superclass-owned
          # answer keeps declining: a non-core ancestor class is the gap #527's superclass slice
          # deferred, and the walk's ordering already gave every include edge its chance first.
          #
          # `kind` is `:instance` only: an `include`d module's `def self.x` is not callable on the
          # includer (the singleton side is a separate #527 item). `self` needs no help here —
          # `dispatch_one` keys `self` / `instance` on the RECEIVER's class name, so a `-> self`
          # module method answers the includer, matching CRuby.
          def included_module_method(environment, class_name, kind, method_name, scope)
            return nil if scope.nil? || kind != :instance
            return nil if environment.nil?

            memo = mixin_ancestor_memo(environment, scope)
            key = [class_name.to_s, method_name.to_sym]
            return memo[key] if memo&.key?(key)

            answer = compute_included_module_method(environment, class_name, method_name, scope)
            memo[key] = answer if memo
            answer
          end

          # The declines are conjunctive and ordered as {compute_core_stdlib_ancestor_method}'s are:
          # the two walks that read the project's tables run LAST, only once an RBS declaration is
          # actually in hand, because they read `Scope#superclass_of` / `#includes_of` and would file a
          # file-granular ancestry edge for every call site otherwise.
          def compute_included_module_method(environment, class_name, method_name, scope)
            return nil if Rigor::Reflection.rbs_class_known?(class_name, environment: environment)
            return nil if environment.plugin_registry&.open_receiver?(class_name)

            definition, owner = Inference::ExternalAncestorResolution.resolve(
              class_name, method_name, :instance,
              scope: scope, environment: environment, record_dependencies: false, mixins: true
            )
            return nil if definition.nil?
            return nil unless environment.rbs_module?(owner)
            return nil if returns_the_walked_ancestry?(definition, owner, environment)
            return nil if dynamic_surface_through_ancestors?(scope, class_name)
            return nil if project_patched_through_ancestors?(environment, scope, class_name, owner, method_name)
            return nil if source_declares_through_ancestors?(scope, class_name, method_name)

            definition
          end

          # The same one-slot memo shape as {#core_stdlib_memo}; see there for why it is one slot keyed
          # on the discovery index's identity, and why a recording run bypasses it.
          MIXIN_ANCESTOR_MEMO_KEY = :__rigor_mixin_ancestor_dispatch__
          private_constant :MIXIN_ANCESTOR_MEMO_KEY

          def mixin_ancestor_memo(environment, scope)
            return nil if Rigor::Analysis::DependencyRecorder.active?

            discovery = scope.discovery
            slot = Thread.current[MIXIN_ANCESTOR_MEMO_KEY]
            unless slot && slot[0].equal?(discovery) && slot[1].equal?(environment)
              slot = [discovery, environment, {}]
              Thread.current[MIXIN_ANCESTOR_MEMO_KEY] = slot
            end
            slot[2]
          end

          # The declines are conjunctive, so their ORDER is free — and it is chosen so the two that walk
          # the project's tables run LAST, only once a core / stdlib declaration is actually in hand.
          # Every unresolved call on a Ruby-source receiver reaches here (`Widget.new.price` on a plain
          # project class), and those walks read `Scope#superclass_of` / `#includes_of`, which file an
          # ADR-46 ancestry edge. Running them unconditionally turned every cross-class METHOD call into
          # a file-granular ancestry dependency — coarser than the symbol edge ADR-46 slice 4 files, and
          # pinned against by `dependency_recorder_spec`. Reached at all, the edge is genuine: this
          # answer does depend on the project not declaring the name on that ancestry.
          def compute_core_stdlib_ancestor_method(environment, class_name, method_name, scope)
            return nil if Rigor::Reflection.rbs_class_known?(class_name, environment: environment)
            return nil if environment.plugin_registry&.open_receiver?(class_name)

            definition, owner = Inference::ExternalAncestorResolution.resolve(
              class_name, method_name, :instance,
              scope: scope, environment: environment, record_dependencies: false, mixins: false
            )
            return nil if definition.nil?
            return nil unless core_or_stdlib_owned?(environment, owner, definition)
            return nil if returns_the_walked_ancestry?(definition, owner, environment)
            return nil if dynamic_surface_through_ancestors?(scope, class_name)
            return nil if project_patched_through_ancestors?(environment, scope, class_name, owner, method_name)
            return nil if source_declares_through_ancestors?(scope, class_name, method_name)

            definition
          end

          # The blocker this slice was first written without. CRuby PRESERVES THE SUBCLASS where core /
          # stdlib RBS names the base class: `SubHash#merge` returns a `SubHash`, `SubSet#flatten` a
          # `SubSet`, `SubPathname#basename` a `SubPathname`, `SubDate#+` a `SubDate` — verified against
          # the interpreter. Adopting the declaration answers `Nominal[Hash]`, and because `Hash` IS
          # RBS-known the negative rules then read it as a CLOSED surface: `sub.merge({}).own_method`
          # drew an `error`-severity `call.undefined-method` on working code. That is ADR-5's failure
          # exactly, one hop downstream — the propagation this slice's own boundary section names.
          #
          # RBS cannot distinguish the two families. `String#upcase: () -> String` really does return a
          # plain `String` for a `String` subclass (Ruby 3.0 changed that), while `Hash#merge: () ->
          # Hash[K, V]` really does return the subclass, and the two declarations are the same shape.
          # So the answer is DECLINE, which is master's `Dynamic[top]` and therefore provably cannot
          # regress a corpus target — rather than substituting the receiver as if the declaration read
          # `-> self`. That substitution would be right for `merge` and wrong for `upcase`, and its
          # wrongness is not purely a false negative: a `Nominal[SubStr]` that is really a `String`
          # narrows `is_a?` guards and can reach `clause.unreachable` on a branch the runtime takes.
          #
          # `-> self` and `-> instance` returns are NOT affected and keep their precision: those already
          # resolve against the receiver (`SubHash#clear` → `SubHash`, `SubStr#force_encoding` →
          # `SubStr`, `MyError#exception` → `MyError`), which is what CRuby does.
          #
          # The test looks for the owner ANYWHERE in the return type, type arguments included. A first
          # draft unwrapped only the top level, unions and optionals, on the reasoning that a class named
          # inside `Array[...]` describes the elements rather than the returned object — true, and beside
          # the point, because the ELEMENTS are subclass instances too. `Pathname#children: () ->
          # Array[Pathname]` hands back an array of `SubPath`s (likewise `entries`, `each_child`,
          # `ascend`, `descend`, `find`; only `glob` yields a plain `Pathname`), so
          # `sub.children.first.own_method` fired the same `call.undefined-method` one level down.
          # `Date#step`, `Date#upto` and `Set#classify` are the same family and escaped only by the shape
          # of their declarations.
          #
          # The cost of the deeper walk is in the direction WD7 already accepts: `SubStr#chars` →
          # `Array[String]` now declines although CRuby really does yield plain `String`s. `keys`,
          # `to_a` and `classify` are unaffected, their arguments being type variables or `self`.
          #
          # An `Alias` that expands to the owner is not followed; that is a known gap in the FN direction.
          def returns_the_walked_ancestry?(definition, owner, environment)
            names = [owner.to_s.delete_prefix("::"), *rbs_instance_ancestor_names(owner, environment)].to_set
            method_types = definition.respond_to?(:method_types) ? definition.method_types : nil
            return false if method_types.nil?

            method_types.any? do |method_type|
              return_type = method_type.type.respond_to?(:return_type) ? method_type.type.return_type : nil
              mentions_class?(return_type, names)
            end
          rescue StandardError
            # A signature whose return type cannot be read is a gap, and a gap declines.
            true
          end

          # Whether any of `names` appears as a class instance anywhere in `type`, descending through
          # every child an RBS type exposes — union members, the inside of an optional, and type
          # ARGUMENTS. See {returns_the_walked_ancestry?}.
          def mentions_class?(type, names, depth = 0)
            return false if type.nil? || depth > RETURN_TYPE_UNWRAP_DEPTH
            return true if own_class_name_matches?(type, names)
            return false unless type.respond_to?(:each_type)

            type.each_type.any? { |child| mentions_class?(child, names, depth + 1) }
          end

          def own_class_name_matches?(type, names)
            type.is_a?(::RBS::Types::ClassInstance) && names.include?(type.name.to_s.delete_prefix("::"))
          end

          # A guard against a pathological or cyclic signature, not a semantic limit: real return types
          # nest a level or two (`Array[Pathname]`, `Hash[Symbol, Array[String]]`).
          RETURN_TYPE_UNWRAP_DEPTH = 8
          private_constant :RETURN_TYPE_UNWRAP_DEPTH

          # Issue #992's surface mark: a `Klass.include(M)` / `.prepend(M)` / `class_eval` written
          # OUTSIDE the class body, which `ScopeIndexer` records as `ENVELOPE_DYNAMIC_MARK` because it
          # can add members the in-body walks never see. `class Extended < Hash; end` followed by
          # `Extended.include(Ext)` where `Ext#empty?` returns `42` must not adopt `Hash#empty?`. Asked
          # of the receiver and of every SOURCE ancestor between it and the owner, because a mark on an
          # intermediate reaches the receiver just as well.
          def dynamic_surface_through_ancestors?(scope, class_name)
            return true if dynamic_surface?(scope, class_name)

            each_source_ancestor_candidate(scope, class_name) do |candidate|
              return true if dynamic_surface?(scope, candidate)
            end
            false
          end

          def dynamic_surface?(scope, class_name)
            scope.parameter_envelopes_of(class_name).key?(Scope::DiscoveryIndex::ENVELOPE_DYNAMIC_MARK)
          end

          # ADR-110's precedence, asked of both tables the project's own members land in. Either one
          # answering true is a decline; both suppress (answer true) when their shared
          # `Scope::ANCESTOR_WALK_LIMIT` budget runs out, and record a `BudgetTrace` hit there.
          def source_declares_through_ancestors?(scope, class_name, method_name)
            return true if scope.discovered_method_through_ancestors?(class_name, method_name, :instance)

            !scope.user_def_through_ancestors(class_name, method_name).first.nil?
          end

          # Both ends of the declaration have to be core / stdlib: the ancestor the walk asked (`Hash`,
          # `StringScanner`) and the class the declaration is written on (`Exception` for
          # `StandardError#message`, `Comparable` for a `clamp`). Either being a gem's or the project's
          # own RBS is slice 3's question, not this one's.
          def core_or_stdlib_owned?(environment, owner, definition)
            loader = environment.rbs_loader
            return false if loader.nil? || !loader.respond_to?(:core_or_stdlib_class?)
            return false unless loader.core_or_stdlib_class?(owner)

            declared_on = definition.respond_to?(:defined_in) ? definition.defined_in : nil
            return false if declared_on.nil?

            loader.core_or_stdlib_class?(declared_on.to_s)
          end

          # ADR-17 — a `pre_eval:` file that reopens the receiver, any SOURCE ancestor between it and the
          # owner, or any RBS ancestor of the owner, and redefines the name. The declaration this arm
          # would adopt is then not the method that runs. The source chain is the half the first draft
          # missed: `class Middle < Hash; end; class Leaf < Middle; end` with a `pre_eval:`
          # `class Middle; def key?(k) = 42; end` answered `bool` for a call that returns `42`.
          def project_patched_through_ancestors?(environment, scope, class_name, owner, method_name)
            patched = environment.project_patched_methods
            return false if patched.nil? || patched.empty?

            owners = [class_name.to_s.delete_prefix("::"), *rbs_instance_ancestor_names(owner, environment)]
            each_source_ancestor_candidate(scope, class_name) { |candidate| owners << candidate }
            owners.any? do |name|
              !patched.lookup(class_name: name, method_name: method_name, kind: :instance).nil?
            end
          end

          # Memo for the whole decision. Every call site of a class asks the same `(class, method)`
          # question, and the answer is a pure function of the frozen discovery index and the
          # environment, so it is cacheable on their identity. A run that is RECORDING ADR-46
          # dependency edges bypasses it: the shadow probes above read the project's method tables, and
          # a memo would swallow that edge for every file after the first.
          #
          # ONE slot, replaced rather than accumulated — see {ExternalAncestorResolution}'s twin for
          # the measurement. A `Scope` hands each analysed file its own discovery index, so an
          # identity-keyed store would pin every file's index, and every RBS definition resolved
          # against it, for the length of the run.
          CORE_STDLIB_ANCESTOR_MEMO_KEY = :__rigor_core_stdlib_ancestor_dispatch__
          private_constant :CORE_STDLIB_ANCESTOR_MEMO_KEY

          def core_stdlib_memo(environment, scope)
            return nil if Rigor::Analysis::DependencyRecorder.active?

            discovery = scope.discovery
            slot = Thread.current[CORE_STDLIB_ANCESTOR_MEMO_KEY]
            unless slot && slot[0].equal?(discovery) && slot[1].equal?(environment)
              slot = [discovery, environment, {}]
              Thread.current[CORE_STDLIB_ANCESTOR_MEMO_KEY] = slot
            end
            slot[2]
          end

          # BFS over the scope's as-written ancestry tables — include edges first, then the
          # superclass, matching the MRO — yielding every ancestor-name candidate. The tables store
          # names AS WRITTEN — `"::API::Base"`, bare `"Base"` — so each hop resolves through the
          # nesting-aware `ancestor_name_candidates` rather than a raw lookup. Deliberately
          # NOT `external_ancestor_name_candidates`: that walk records `ancestry_sources` edges via
          # `record_class_dependency`, which would mislabel a dispatch lookup as an ancestry edge.
          #
          # Issue #1173 — the walk follows include edges too, because a shadow guard that reads only
          # the superclass chain misses the nearer half of the ancestry: `class C < Base; include M;
          # end` chains `C → M → Base`, and a `def`, an outside-the-body mark, or a `pre_eval:` patch
          # on a source `M` all outrank `Base`'s declaration. A candidate that names a project class /
          # module continues the walk ({Scope#known_user_class?} — a module that defines nothing and
          # mixes nothing in still gates what the arm may adopt); an RBS-known or unresolved one is
          # yielded for the caller's guards but its ancestry is the RBS side's business. The include
          # table is read RAW (`scope.discovered_includes`), the same reason the superclass table is:
          # `Scope#includes_of` files `record_class_dependency` on every read — a miss included —
          # and this walk runs for every unresolved call on a project class (`Widget.new`), so the
          # reader would turn each one into an ancestry edge ADR-46 slice 4 keeps at symbol
          # granularity (`dependency_recorder_spec`).
          def each_source_ancestor_candidate(scope, class_name)
            supers = scope.discovered_superclasses
            includes = scope.discovered_includes
            queue = [class_name.to_s]
            seen = {}
            until queue.empty?
              current = queue.shift
              next if current.nil? || seen[current]

              seen[current] = true
              ((includes[current] || []) + [supers[current]].compact).each do |raw|
                scope.ancestor_name_candidates(current, raw).each do |candidate|
                  yield candidate
                  queue << candidate if scope.known_user_class?(candidate)
                end
              end
            end
          end

          # The extend-edge twin of `allowed_rbs_complete_ancestor` (manifest `rbs_complete_extends:`).
          # `extend M` lifts M's INSTANCE surface onto the extending class object's singleton, so a
          # singleton call on a Ruby-source class can resolve through a module the class — or one of
          # its discovered superclasses — extends. Returns the first resolved candidate name that a
          # loaded plugin allow-lists, or nil. Same guards as the superclass bridge, minus the
          # RBS-known receiver exit: the direct lookup has already missed by the time this runs, and
          # a class that is BOTH source-defined and RBS-known (`class F` in `sig/` plus `extend T::Sig`
          # in the body) still carries the source edge — the runtime ancestry contains the module
          # either way, so withholding the bridge would leave a real `sig` opaque. A nearer source
          # `def self.x` still shadows any bridged module method.
          def allowed_rbs_complete_extended_module(environment, class_name, method_name, scope,
                                                   call_node = nil)
            return nil if scope.nil?

            registry = environment&.plugin_registry
            return nil if registry.nil?

            supers = scope.discovered_superclasses
            extends = scope.discovered_extends
            queue = [class_name.to_s]
            seen = {}
            until queue.empty?
              current = queue.shift
              next if current.nil? || seen[current]

              seen[current] = true
              # The class's own `def self.x` sits ahead of every `extend` — once it has run.
              # `singleton_def_shadows_call?` orders the def against the call site, so a `def self.sig`
              # written AFTER this `sig {}` does not suppress the bridge.
              return nil if scope.singleton_def_shadows_call?(current, method_name, call_node)

              resolved = rbs_complete_extended_module_for(current, extends, environment, scope,
                                                          registry, method_name, call_node)
              return nil if resolved.equal?(EXTEND_OWNER_STOP)
              return resolved if resolved

              raw = supers[current]
              scope.ancestor_name_candidates(current, raw).each { |c| queue << c } if raw
            end
            nil
          end

          # One walk hop of `allowed_rbs_complete_extended_module`. Each `extend` edge binds to the
          # first resolution candidate that exists at runtime. If that owner DEFINES `method_name`:
          # an allow-listed RBS module is the answer; a project class or a non-allow-listed RBS name
          # owns the call, so the hop returns {EXTEND_OWNER_STOP} and the outer walk must not search
          # later extends or superclasses (a nested `Outer::CustomSig` would otherwise fall through
          # to `T::Sig` and type the call as `nil`). An owner that does not define the method yields
          # to the next extended module — Ruby's singleton ancestry searches every extend in turn.
          def rbs_complete_extended_module_for(current, extends, environment, scope, registry,
                                               method_name, call_node)
            each_extended_module_name(current, extends, environment) do |mod_name|
              owner = scope.ancestor_name_candidates(current, mod_name).find do |candidate|
                scope.known_user_class?(candidate) ||
                  Rigor::Reflection.rbs_class_known?(candidate, environment: environment)
              end
              next if owner.nil?
              next unless extend_owner_defines?(owner, method_name, call_node, scope, environment)

              project_owned = scope.known_user_class?(owner)
              return owner if !project_owned && registry.rbs_complete_extends?(owner)

              return EXTEND_OWNER_STOP
            end
            nil
          end

          def extend_owner_defines?(owner, method_name, call_node, scope, environment)
            return true if scope.instance_def_shadows_call?(owner, method_name, call_node)

            !lookup_method_on(environment, owner, :instance, method_name).nil?
          end

          # Sentinel: a nearer `extend` answers `method_name`, so the allow-list must not continue.
          EXTEND_OWNER_STOP = :__rbs_complete_extends_stop__
          private_constant :EXTEND_OWNER_STOP

          # The module names `current` extends, source table first (`discovered_extends`, stored in
          # singleton-ancestor search order — nearest edge first) then the RBS side
          # (`singleton_extended_modules`, already qualified) — an RBS superclass like `T::Struct`
          # declares `extend T::Props::ClassMethods` in signature, and a source subclass inherits it.
          def each_extended_module_name(current, extends, environment, &)
            (extends[current] || []).each(&)
            (environment&.singleton_extended_modules(current) || []).each(&)
          end

          # Slice 4 phase 2d substitution map. Zips the class's declared type-parameter names against the
          # receiver's `type_args`. Returns an empty hash when either side is empty or when the receiver
          # carries MORE arguments than the class declares -- in every such case free variables in the
          # method's return type degrade to `Dynamic[Top]` per the translator's contract.
          #
          # Issue #1121 -- FEWER arguments than parameters is not a disagreement, it is the partial
          # application RBS itself licenses for a class whose trailing parameters declare a default:
          # `Enumerator::Lazy[out E, out R = void]` is spelled `Enumerator::Lazy[Elem]` by the very
          # signature that hands one back (`Enumerable#lazy: () -> Enumerator::Lazy[Elem]`). Withholding
          # the whole map there dropped the element binding on every lazy-enumerator receiver, so the
          # block parameter of `lazy.map { |x| … }` was `Dynamic[top]` and the chain could not recover the
          # element type. The supplied prefix MUST bind in declaration order and the omitted trailing names
          # stay unbound (`Dynamic[top]`), exactly as any other free variable does.
          def build_type_vars(environment, class_name, receiver_args)
            return NO_TYPE_VARS if receiver_args.empty?

            param_names = Rigor::Reflection.class_type_param_names(class_name, environment: environment)
            return NO_TYPE_VARS if param_names.empty?
            return NO_TYPE_VARS if receiver_args.size > param_names.size

            param_names.first(receiver_args.size).zip(receiver_args).to_h
          end

          # The shared empty substitution map: most receivers carry no type arguments, and the translator
          # only ever reads the map (#775).
          NO_TYPE_VARS = {}.freeze
          private_constant :NO_TYPE_VARS

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
            # fallback returns the caller's type, not Object. `dispatch_one` also routes the receiver's
            # type-argument-bearing projection through it ({SelfSubstitute}, #1092).
            self_type = self_type_override || resolved_self_type

            candidates = OverloadSelector.select_candidates(
              method_definition,
              arg_types: args,
              # A `Dynamic` self (#1092) is a return-side answer; overload selection and ReceiverAffinity
              # read the static facet, as they did before the substitute carried the wrapping.
              self_type: self_type.is_a?(Type::Dynamic) ? self_type.static_facet : self_type,
              instance_type: instance_type,
              type_vars: type_vars,
              block_required: !block_type.nil?,
              environment: environment
            )
            return nil if candidates.empty?

            call_site = [class_name, method_name, kind]
            record_dispatch_provenance(method_definition, candidates.first, scope, call_node, call_site)
            join_candidate_returns(
              candidates,
              method_definition: method_definition,
              self_type: self_type, instance_type: instance_type, type_vars: type_vars,
              args: args, block_type: block_type, scope: scope, call_node: call_node, call_site: call_site,
              alias_expander: environment.rbs_loader
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
          # Issue #521 — more than one candidate means a `Dynamic[Top]` argument made the overloads
          # indistinguishable; pinning the first answered a wrong precise type the runtime can contradict
          # (`[true] * n` read as String). The join is the candidates' return union wrapped in `Dynamic`,
          # not the bare union: the untyped argument may satisfy constraints (kwarg shapes, value pins)
          # that exclude arms statically-indistinguishable here, so a bare union licenses the negative
          # rules to fire on arms the runtime never takes — measured immediately as three false positives
          # on this repository's own `lib` (`Integer(v)` joining the `exception: bool` nil arm). The
          # `Dynamic[T]` carrier keeps the candidate set visible without that license (ADR-5).
          # A candidate whose return does not translate leaves the join incomplete — decline (fail-soft
          # to Dynamic downstream) rather than answer a join missing an arm the runtime can take.
          # rubocop:disable-next Metrics/ParameterLists
          def join_candidate_returns(candidates, method_definition:, self_type:, instance_type:, type_vars:, args:,
                                     block_type:, scope:, call_node:, call_site:, alias_expander: nil)
            returns = candidates.map do |method_type|
              full_type_vars = compose_type_vars(method_type, type_vars, args, block_type, scope, call_node, call_site)
              returned = RbsTypeTranslator.translate(
                method_type.type.return_type,
                self_type: self_type,
                instance_type: instance_type,
                type_vars: full_type_vars,
                alias_expander: alias_expander
              )
              next returned unless combining_overload?(method_definition, method_type, call_site)

              class_level_sum(returned, method_type, args)
            end
            return returns.first if returns.size == 1
            return nil if returns.any?(&:nil?)

            distinct = returns.uniq
            return distinct.first if distinct.size == 1

            Type::Combinator.dynamic(Type::Combinator.union(*distinct))
          end

          def compose_type_vars(method_type, type_vars, args, block_type, scope, call_node, call_site)
            vars = compose_block_type_vars(method_type, type_vars, block_type, args,
                                           scope: scope, call_node: call_node, call_site: call_site)
            compose_arg_type_vars(method_type, vars, args, scope: scope, call_node: call_node,
                                                           call_site: call_site)
          end

          # Whether the overload is one `Enumerable` declares for `sum`, whose declared return the tier reads
          # at class level ({#class_level_sum}). Every overload spells its return as the sides the method adds
          # together, as a union or as one variable that covers both: `() -> (E | Integer)`,
          # `[T] () { (E) -> T } -> (Integer | T)`, `[T] (?T) -> (E | T)` and `[U] (?U) { (E) -> U } -> U`.
          # A value is not closed under that addition, so the value-pinned bindings of `E` (from the
          # receiver), `T` (from the argument, issue #303) and the block's type do not describe the result:
          # `[1, 2].each.sum(0.0)` is `3.0`, which `0.0 | 1 | 2` misses. `Array#fetch: [T] (int, T default)
          # -> (E | T)` is spelled the same way but
          # returns the default object itself, so the signature alone cannot tell the two apart and the
          # declaring module does. A class that declares its own `sum` states its own contract and keeps it.
          def combining_overload?(method_definition, method_type, call_site)
            return false unless call_site[1] == :sum

            type_def = OptimisticOrigin.matching_type_def(method_definition, method_type)
            !type_def.nil? && type_def.defined_in.to_s.delete_prefix("::") == "Enumerable"
          end

          # Apart from the range shortcut ({#range_coerced_seed?}), CRuby's `enum_sum` adds each value to an
          # accumulator that starts at the seed. Between two of these classes `+` answers the later one
          # (`1 + 0.5` and `0.5 + 1` are Floats, `1 + 1r` is a Rational), so the accumulator's class only ever
          # moves up this order.
          SUM_PROMOTION_RANKS = { "Integer" => 0, "Rational" => 1, "Float" => 2, "Complex" => 3 }.freeze
          private_constant :SUM_PROMOTION_RANKS

          # CRuby's seed when the call passes none.
          SUM_DEFAULT_SEED = ["Integer"].freeze
          private_constant :SUM_DEFAULT_SEED

          # The seeds CRuby's integer-range shortcut adds to with plain `+` ({#range_coerced_seed?}).
          RANGE_ADDED_SEEDS = Set["Integer", "Float"].freeze
          private_constant :RANGE_ADDED_SEEDS

          # The class-level reading of a `sum` overload's translated return, or `Dynamic[top]` when a member
          # widens to none of the value classes {#value_classes} admits. A class, not a value, is what the
          # addition keeps closed: `sum` over `0.0` and `1 | 2` is `3.0`, a Float, and over `1.5 | 2.5` is
          # `4.0`.
          #
          # The union of the members' classes would still read wider than the runtime, because the seed
          # promotes every value it absorbs: `ints.each.sum(0.0)` is always a Float, and `Float | Integer`
          # fires `def.return-type-mismatch` against a declared `-> Float` on correct code. So each class is
          # taken as the class the accumulator reaches from each seed class ({#promoted_class}), and the seed
          # itself stays for a receiver that yields nothing: `ints.each.sum(0.0)` reads `Float`, and
          # `floats.each.sum(0)` reads `Float | Integer`, whose Integer is the empty receiver's `0`.
          def class_level_sum(type, method_type, args)
            return nil if type.nil?

            members = value_classes(type)
            return Type::Combinator.untyped if members.nil?

            seeds = sum_seed_classes(method_type, args)
            return Type::Combinator.untyped if seeds.nil? || range_coerced_seed?(method_type, seeds)

            reached = seeds.flat_map { |seed| members.map { |member| promoted_class(seed, member) } }
            Type::Combinator.union(*(seeds | reached).map { |name| Type::Combinator.nominal_of(name) })
          end

          # Whether CRuby may skip the accumulator and read the seed as a Float. With no block and a seed that
          # is not a Float, `enum_sum` sums a range with Integer endpoints by Gauss's formula and adds the
          # result to the seed. An Integer seed takes plain `+`; any other goes through `Integer#coerce`, which
          # converts it with `Float()`: `(1..3).sum(0r)` is `6.0` and `(1..3).sum("1.5")` is `7.5`. Any object
          # that answers `begin`, `end` and `exclude_end?` takes the same path, so the receiver's class cannot
          # rule it out.
          def range_coerced_seed?(method_type, seeds)
            method_type.block.nil? && seeds.any? { |seed| !RANGE_ADDED_SEEDS.include?(seed) }
          end

          # The classes of the value `sum` starts from: the argument when the overload takes one and the call
          # passes it, and CRuby's `0` otherwise.
          def sum_seed_classes(method_type, args)
            fun = method_type.type
            return SUM_DEFAULT_SEED if args.empty? || !fun.respond_to?(:required_positionals)
            return SUM_DEFAULT_SEED if fun.required_positionals.empty? && fun.optional_positionals.empty?

            value_classes(args.first)
          end

          # The class the accumulator reaches when a `member` value is added to a `seed`-class one. `+` does not
          # add a String and a number (`"" + 1` and `1 + ""` raise), so such a pair keeps the member's class,
          # which reads wider than the runtime rather than narrower. The range shortcut that does convert a
          # String seed never reaches here ({#range_coerced_seed?}).
          def promoted_class(seed, member)
            seed_rank = SUM_PROMOTION_RANKS[seed]
            member_rank = SUM_PROMOTION_RANKS[member]
            return member if seed_rank.nil? || member_rank.nil?

            seed_rank > member_rank ? seed : member
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
          #
          # The block alone does not decide a variable that a parameter's type also names once the call
          # passes an argument. `Enumerable#sum: [U] (?U) { (E) -> U } -> U` adds the block's values to the
          # argument, `Enumerable#inject: [A] (A initial) { (A, E) -> A } -> A` returns the argument for an
          # empty receiver, and `Hash#transform_keys: [K2] (hash[_Key, K2]) { (K) -> K2 } -> Hash[K2, V]`
          # takes a mapping hit's value without yielding. `Dynamic[block_type]` would not do: a `Dynamic`
          # receiver dispatches through its static facet and answers exactly, so a facet that misses the
          # runtime value is wrong one call later (`(h.sum(0.0) { |_k, v| v } / h.size).nan?` read
          # `Integer#nan?`). Nor would joining in the argument as it stands, since
          # `[1, 2].each.sum(0.0) { |x| x }` is `3.0`, which neither side contains. The variable is bound
          # to {#shared_value_class} where both sides have one, and to `Dynamic[top]` otherwise. The key
          # stays in the map either way so {#compose_arg_type_vars} does not bind the variable from the
          # argument alone.
          def compose_block_type_vars(method_type, type_vars, block_type, args, scope:, call_node:, call_site:)
            return type_vars if block_type.nil?

            block_var_name = method_type_block_return_variable(method_type)
            return type_vars if block_var_name.nil?
            return type_vars.merge(block_var_name => block_type) unless
              argument_reaches_variable?(method_type, block_var_name, args)

            shared = shared_value_class(method_type, block_var_name, args, block_type, call_node)
            bound = shared && arg_binding_permitted?(scope, call_node, call_site) ? shared : Type::Combinator.untyped
            type_vars.merge(block_var_name => bound)
          end

          # Whether an argument the call passes may land in a parameter whose type names `name`, anywhere
          # inside it (`hash[_Key, K2]` names `K2`). The argument count is not matched against the
          # parameter list: a `*splat` argument stands for any number of arguments, and keyword arguments
          # arrive as one more entry in `args`, so any argument counts as reaching every parameter.
          def argument_reaches_variable?(method_type, name, args)
            return false if args.empty?

            method_type.type.each_param.any? { |param| mentions_variable?(param.type, name) }
          end

          # The one value class that the arguments landing in `name`'s parameters and the block's type all
          # share, or nil to leave the variable `Dynamic[top]`. A class, not a value, because a combining
          # method keeps a class closed and not a value: `[1, 2].each.sum(1) { |x| -x }` is `-2`, which
          # neither `1` nor `-1 | -2` contains. RBS reads `[U] (?U) { (E) -> U } -> U` the same way, as a
          # `U` that covers the argument and the block alike. One class and not a union of several, because
          # `sum` absorbs: over Integers, `sum(0.0)` answers a Float every time, and `Float | Integer` would
          # fire `def.return-type-mismatch` against a declared `-> Float`.
          #
          # The block's type is one typing of its body, so it covers every call only when nothing the block
          # receives depends on the variable ({#block_receives_variable?}). The argument binding's gate
          # applies ({#arg_binding_permitted?}), since this reads the argument. The positions must be static
          # ({#arguments_at_variable}), and every side must widen to a class ({#value_classes}). The block's
          # type is trusted as far as the engine trusts it, so a hash filled through an alias, which reads
          # narrower than it is, binds its narrower class here too.
          def shared_value_class(method_type, name, args, block_type, call_node)
            return nil if block_receives_variable?(method_type.block, name)

            reaching = arguments_at_variable(method_type, name, args, call_node)
            return nil if reaching.nil?

            sides = [*reaching, block_type].map { |type| value_classes(type) }
            return nil unless sides.all?

            classes = sides.flatten(1).uniq
            classes.size == 1 ? Type::Combinator.nominal_of(classes.first) : nil
          end

          # Whether the block's parameters or its `self` name the variable, as `inject`'s accumulator
          # (`{ (A, E) -> A }`) and `produce`'s previous element (`{ (T prev) -> T }`) do. Such a parameter
          # holds the argument on the first call and the block's own result after it, and the pass that
          # typed the block typed it once, as whatever reached it: the RBS probe leaves it untyped, but
          # `IteratorDispatch` hands an Array receiver's `inject` the seed, and a `&:+` block then reads
          # `0.+`, so `[1.5, 2].inject(0, &:+)`, which is `3.5`, would bind `Integer`.
          def block_receives_variable?(block, name)
            return true if block.self_type && mentions_variable?(block.self_type, name)

            block.type.each_param.any? { |param| mentions_variable?(param.type, name) }
          end

          # The arguments that land in a positional parameter whose whole type is `name`, or nil when the
          # call's positions or the signature's shape leave that open. The call must pass plain positional
          # arguments: after a `*splat` that turns out empty, the next argument lands one parameter earlier,
          # and a forwarded `...` or keyword arguments may land anywhere. The signature must name `name` only
          # as a whole leading positional parameter's type, and have no trailing positional parameter at
          # all. One that names the variable takes its argument from the end of the list, which pairing the
          # leading parameters with the arguments in order would miss; one that does not is declined too,
          # conservatively.
          def arguments_at_variable(method_type, name, args, call_node)
            return nil unless plain_positional_arguments?(call_node, args.size)

            fun = method_type.type
            return nil unless fun.respond_to?(:trailing_positionals) && fun.trailing_positionals.empty?
            return nil if named_outside_positionals?(fun, name)

            positionals = fun.required_positionals + fun.optional_positionals
            positionals.zip(args).each_with_object([]) do |(param, arg), reaching|
              type = param.type
              next unless mentions_variable?(type, name)
              return nil unless type.is_a?(RBS::Types::Variable)

              reaching << arg unless arg.nil?
            end
          end

          def plain_positional_arguments?(call_node, count)
            return false unless call_node.is_a?(Prism::CallNode)

            arguments = call_node.arguments&.arguments || EMPTY_ARGUMENT_NODES
            arguments.size == count && arguments.none? do |argument|
              case argument
              when Prism::SplatNode, Prism::ForwardingArgumentsNode, Prism::KeywordHashNode then true
              else false
              end
            end
          end

          def named_outside_positionals?(fun, name)
            others = [fun.rest_positionals, fun.rest_keywords].compact +
                     fun.required_keywords.values + fun.optional_keywords.values
            others.any? { |param| mentions_variable?(param.type, name) }
          end

          # The class names `type`'s union members widen to, or nil when a member widens to none of
          # {CLOSED_VALUE_CLASSES}.
          def value_classes(type)
            members = type.is_a?(Type::Union) ? type.members : [type]
            classes = members.map { |member| value_class(member) }
            classes.all? ? classes : nil
          end

          # A literal widens to its value's class, a bounded number to `Integer` or `Float`, and a refinement
          # or a difference to its base's class. Everything else declines: a generic class (`[] + [:a]`
          # concatenates elements rather than keeping either side's), a carrier with no class (a tuple, a
          # hash shape, `Dynamic`), and `nil` or `NilClass`, whose arm would fire
          # `call.possible-nil-receiver` where `Array#max` and `#first` bet on a non-empty receiver.
          def value_class(type)
            case type
            when Type::Nominal then closed_value_class(type.class_name)
            when Type::Constant then closed_value_class(type.value.class.name)
            when Type::IntegerRange then "Integer"
            when Type::FloatRange then "Float"
            when Type::Refined, Type::Difference then value_class(type.base)
            end
          end

          def closed_value_class(class_name)
            name = class_name&.delete_prefix("::")
            CLOSED_VALUE_CLASSES.include?(name) ? name : nil
          end

          # A signature nested past {RETURN_TYPE_UNWRAP_DEPTH} counts as naming the variable, which is the
          # untyped answer.
          def mentions_variable?(type, name, depth = 0)
            return true if depth > RETURN_TYPE_UNWRAP_DEPTH
            return type.name == name if type.is_a?(::RBS::Types::Variable)
            return false unless type.respond_to?(:each_type)

            type.each_type.any? { |child| mentions_variable?(child, name, depth + 1) }
          end

          # Issue #303 — bind method-level type parameters from ARGUMENT positions, layering on top of the
          # receiver-derived and block-derived `type_vars` exactly as {#compose_block_type_vars} does, so
          # `Ractor.make_shareable("x")` (`[T] (T) -> T`) answers `"x"` instead of `Dynamic[top]`.
          #
          # Envelope, deliberately the narrowest sound shape:
          #
          # * only a positional parameter (required or optional) whose declared type is EXACTLY
          #   `RBS::Types::Variable`, plus the one container shape issue #834 admits (see
          #   {#range_element_binding}) — no general container walk, so `(Array[T]) -> T` still degrades;
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

              name, bound = param_binding(param, arg, declared, type_vars)
              next if name.nil?

              bound = Type::Combinator.widen_value_pinned(bound) if upper_bounded?(method_type, name)
              bindings[name] = bindings.key?(name) ? Type::Combinator.union(bindings[name], bound) : bound
            end
          end

          # Issue #1347 — a variable that declares an upper bound (`[T < X]`) binds the argument widened off its
          # value-pinned members. The bound constrains a class, and `Rational#*: [T < Numeric](T) -> T` returns a
          # value of the argument's class, not the argument, so `r * 0.5` read the literal `0.5`. An unbounded
          # variable keeps the literal (`Ractor.make_shareable("x")` is `"x"`); a bounded identity return
          # (`String#setbyte`) gives its literal up. Any bound counts: `upper_bound` answers only a class, singleton
          # or interface bound, so an alias, union, intersection or optional bound is read through
          # `upper_bound_type` where the rbs version has it.
          def upper_bounded?(method_type, name)
            method_type.type_params.any? do |type_param|
              type_param.name == name &&
                (type_param.respond_to?(:upper_bound_type) ? type_param.upper_bound_type : type_param.upper_bound)
            end
          end

          # The `(variable name, bound type)` a positional parameter contributes, or {NO_BINDING} when it
          # contributes none. The bare-variable shape is tried first because it is the overwhelmingly
          # common one; the `Range[A]` shape is reached only when the parameter is not a bare variable.
          def param_binding(param, arg, declared, type_vars)
            name = variable_param_name(param, declared, type_vars)
            unless name.nil?
              return NO_BINDING if no_static_evidence?(arg)

              return [name, arg]
            end

            range_element_binding(param, arg, declared, type_vars)
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

          # Issues #834 / #862 — the one container position the envelope admits: a `Range[A]` parameter
          # against a Range argument that names its own element. `Comparable#clamp: [A] (Range[A]) ->
          # (self | A)` otherwise leaves `A` unbound and `i.clamp(1..9)` answers `Dynamic[top] | Integer`,
          # even though the argument names the element outright. It stays Range-only because the
          # justification does not generalise: a Range is immutable and its element type is fixed at
          # construction, whereas an `Array[T]` argument's carrier may have been widened long before the
          # call reached here.
          def range_element_binding(param, arg, declared, type_vars)
            declared_type = param.type
            return NO_BINDING unless declared_type.is_a?(RBS::Types::ClassInstance)
            return NO_BINDING unless RANGE_TYPE_NAMES.include?(declared_type.name.to_s)
            return NO_BINDING unless declared_type.args.size == 1

            element = declared_type.args.first
            return NO_BINDING unless element.is_a?(RBS::Types::Variable)
            return NO_BINDING unless declared.include?(element.name)
            return NO_BINDING if type_vars.key?(element.name)

            bound = range_argument_element(arg)
            bound.nil? ? NO_BINDING : [element.name, bound]
          end

          # The element a Range argument names, or nil when it names none.
          #
          # Two carriers qualify. A `Constant<Range>` contributes its endpoints lifted to their classes
          # ({RangeConstant.element_type}), not the two values, so `clamp(1..9)` answers `Integer` rather
          # than a `1 | 9` the runtime contradicts for every receiver already inside the bracket. A
          # `Nominal[Range, [T]]` (issue #862 — `1..ARGV.size` has no literal endpoint to read, so
          # `ExpressionTyper` hands back the nominal carrier) contributes `T` itself.
          #
          # A nominal carrier qualifies only when `T` is a Nominal or a union of Nominals. `untyped`, a
          # `Dynamic`, or a still-unbound type variable would launder an unknown into the result — the
          # caller's `self | A` would read as `self | unknown` while claiming to be inferred — so those
          # keep degrading as an unbound variable does.
          def range_argument_element(arg)
            return RangeConstant.element_type(arg) unless arg.is_a?(Type::Nominal)
            return nil unless RANGE_TYPE_NAMES.include?(arg.class_name)
            return nil unless arg.type_args.size == 1

            element = arg.type_args.first
            nominal_only?(element) ? element : nil
          end

          def nominal_only?(type)
            case type
            when Type::Nominal then true
            when Type::Union then type.members.all?(Type::Nominal)
            else false
            end
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

          def probe_block_param_types(receiver:, method_name:, args:, environment:, scope: nil)
            args ||= []
            case receiver
            when Type::Union then probe_block_param_types_union(receiver, method_name, args, environment, scope)
            else                  probe_block_param_types_one(receiver, method_name, args, environment, scope)
            end
          end

          # For a union receiver we keep the conservative answer: only return block param types when every
          # member resolves the same arity and types (otherwise the call sites would have to thread
          # per-member binders, which the slice does not support yet). Mismatches degrade to the empty
          # array so the binder defaults all params to Dynamic[Top].
          def probe_block_param_types_union(receiver, method_name, args, environment, scope)
            results = receiver.members.map do |member|
              probe_block_param_types_one(member, method_name, args, environment, scope)
            end
            return [] if results.empty?
            return [] unless results.all? { |r| r == results.first }

            results.first
          end

          def probe_block_param_types_one(receiver, method_name, args, environment, scope)
            descriptor = receiver_descriptor(receiver)
            return [] unless descriptor

            class_name, kind, receiver_args = descriptor
            method_definition = lookup_method(environment, class_name, kind, method_name, scope)
            return [] unless method_definition

            type_vars = build_type_vars(environment, class_name, receiver_args)
            extract_block_param_types(
              method_definition,
              class_name: class_name,
              kind: kind,
              args: args,
              type_vars: type_vars,
              environment: environment,
              receiver: receiver,
              receiver_args: receiver_args,
              method_name: method_name
            )
          rescue StandardError
            []
          end

          # rubocop:disable Metrics/ParameterLists
          def extract_block_param_types(method_definition, class_name:, kind:, args:, type_vars:,
                                        environment: nil, receiver: nil, receiver_args: [],
                                        method_name: nil)
            # rubocop:enable Metrics/ParameterLists
            instance_type = Type::Combinator.nominal_of(class_name)
            self_type =
              case kind
              when :singleton then Type::Combinator.singleton_of(class_name)
              else                 instance_type
              end

            # Issue #1130 — a block parameter that receives `self` (`Object#tap` yields it) must see the
            # receiver's type arguments through the SAME {SelfSubstitute} verdict the return path applies
            # (#1092), so `ints.tap { |a| }` binds `a` to `Array[Integer]` rather than the raw `Array`.
            # The block path reuses only the keep-vs-degrade verdict, NOT the return path's value-pin
            # widening: the block parameter is a destructure source, so the receiver's OWN type arguments
            # (pinned constants included — `[1, 2].tap { |a, b| }` auto-splats the element union
            # `1 | 2` per slot, the parity an explicit `a, b = [1, 2]` gets) are the substitution the
            # binder should see. A verdict decline (an element-changing mutator like `map!`) keeps the
            # raw nominal, so that receiver's block parameter still arrives without its type arguments.
            substitute = SelfSubstitute.for(receiver, receiver_args, method_name, args, nil)
            self_type = Type::Combinator.nominal_of(class_name, type_args: receiver_args) if substitute

            method_type = OverloadSelector.select(
              method_definition,
              arg_types: args,
              # Overload selection reads a `Dynamic` self's static facet, mirroring the return path;
              # the substitution verdict here is built from the receiver's type arguments alone.
              self_type: self_type.is_a?(Type::Dynamic) ? self_type.static_facet : self_type,
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
              type_vars: type_vars,
              alias_expander: environment.rbs_loader
            )
          end

          # `RBS::Types::Block#type` is normally an `RBS::Types::Function` carrying the block's parameter
          # list; some signatures use `RBS::Types::UntypedFunction` (a `(?)` block) which exposes no
          # parameter types -- we treat it as "no information" and return an empty array so the binder
          # defaults every slot.
          def translate_block_positional_params(block, self_type:, instance_type:, type_vars:, alias_expander: nil)
            fun = block.type
            return [] unless fun.respond_to?(:required_positionals)

            params = fun.required_positionals + fun.optional_positionals
            params.map do |param|
              RbsTypeTranslator.translate(
                param.type,
                self_type: self_type,
                instance_type: instance_type,
                type_vars: type_vars,
                alias_expander: alias_expander
              )
            end
          end
        end
      end
    end
  end
end
