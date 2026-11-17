# frozen_string_literal: true

require "prism"
require "rbs"
require_relative "../../reflection"
require_relative "../../rbs_extended"
require_relative "../../type"
require_relative "../../inference/acceptance"
require_relative "../../inference/rbs_type_translator"
require_relative "../../inference/method_dispatcher/singleton_type_params"
require_relative "../diagnostic"
require_relative "declaration_sourced_guard"
require_relative "nil_receiver"
require_relative "receiver_predicates"
require_relative "rule_ids"
require_relative "wrong_arity"

module Rigor
  module Analysis
    module CheckRules
      # ADR-116 WD1 — `call.argument-type-mismatch` (v0.0.2 #4): an explicit-receiver call whose positional
      # argument the RBS parameter at its position provably rejects, on the single-overload exact channel and
      # the multi-overload nil / non-nil channels, with the declines the rule has accumulated.
      #
      # The entry point is {.diagnostic}, called by `CheckRules.call_node_diagnostics`. It reads
      # {ReceiverPredicates}, {DeclarationSourcedGuard}, {NilReceiver} (`union_contains_nil?`,
      # `nil_class_has_method?`) and {WrongArity} (`plain_positional_call?`), and calls nothing in
      # `CheckRules`.
      # rubocop:disable-next Metrics/ModuleLength
      module ArgumentType
        module_function

        # v0.0.2 #4 — argument-type-mismatch diagnostic.
        # Walks a call's positional arguments and checks each
        # against the matching parameter's RBS type via
        # `Rigor::Inference::Acceptance`. Emits an `:error`
        # for the first argument whose type the parameter
        # does NOT accept under the gradual mode.
        #
        # Conservative envelope (matches the wrong-arity rule
        # plus a few additional skips):
        # - Receiver must be Nominal / Singleton / Constant
        #   (the same `concrete_class_name` test).
        # - Method must be in RBS.
        # - Overloads: a single method type is checked exactly; with several, an argument is a mismatch only
        #   when every overload rejects it ({#multi_overload_argument_mismatch}).
        # - The overload checked must have NO
        #   rest_positionals and NO trailing positionals —
        #   the two shapes under which argument N no longer
        #   binds to positional parameter N. Keyword
        #   parameters do not disqualify it (#673).
        # - The call must use plain positional arguments
        #   (no splat / kw / block-pass / forwarded).
        # - Per-argument: skip when EITHER side is `Dynamic`
        #   (the call cannot be statically refuted).
        # Ruby's universal-equality methods accept any object
        # per the `Object#==(other) → bool` /
        # `Object#eql?(other) → bool` contract. Even when a
        # subclass overrides `==` to compare specific shapes
        # (URI::Generic#==(URI::Generic), Time#==(Time), …),
        # the runtime convention is to RETURN false for
        # type-mismatched arguments rather than raise. RBS sigs
        # that declare a tight parameter type therefore over-
        # specify; checking arguments against them produces
        # spurious mismatches such as
        #   `URI::Generic#==(URI::Generic)`
        #   called with `URI::HTTP | nil`
        # tdiary-core's `config_uri == referer_uri` (where
        # `referer_uri` is `URI.parse(...) if condition`, hence
        # union-with-nil) is the canonical case. Skip arg
        # checking on these methods entirely; the call is
        # well-formed by Ruby's contract.
        UNIVERSAL_EQUALITY_METHODS = %i[== != eql? equal? <=>].to_set.freeze
        private_constant :UNIVERSAL_EQUALITY_METHODS

        # ADR-64 WD1 — the binary arithmetic / bit / ordering operators
        # dispatch through Ruby's `coerce` protocol (and `<=>` for the
        # comparisons): `5 + Money.new` is valid at runtime because
        # `Integer#+` calls `Money#coerce(5)`, even though no RBS `Integer#+`
        # overload lists `Money`. A non-`Numeric` argument to them is therefore
        # NOT statically refutable — any user type may define `coerce` — so the
        # *non-nil* argument-type-mismatch channel excludes them (a fixed
        # allow-list, modelled on {UNIVERSAL_EQUALITY_METHODS}, not `coerce`
        # detection). `nil` never coerces, so the nil channel stays in force
        # here; the exclusion applies to the non-nil case only. `<=>` and the
        # `==` family are already excluded wholesale by
        # {UNIVERSAL_EQUALITY_METHODS}.
        COERCE_DISPATCH_METHODS = %i[+ - * / % ** & | ^ << >> < > <= >=].to_set.freeze
        private_constant :COERCE_DISPATCH_METHODS

        def diagnostic(path, call_node, facts, lexical_sites = nil)
          return nil if call_node.receiver.nil?
          return nil if UNIVERSAL_EQUALITY_METHODS.include?(call_node.name)
          return nil unless WrongArity.plain_positional_call?(call_node)

          scope = facts.scope
          return nil if scope.nil?

          receiver_type = facts.receiver_type
          class_name = ReceiverPredicates.concrete_class_name(receiver_type)
          return nil if class_name.nil?

          # NOTE: unlike the undefined-method / wrong-arity
          # rules, we deliberately do NOT skip when
          # `discovered_method?` matches. When the user
          # supplies BOTH a `def` and an RBS sig, the sig is
          # the authoritative parameter contract and we
          # should validate calls against it.
          return nil unless Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
          return nil unless ReceiverPredicates.definition_available?(receiver_type, class_name, scope)

          method_def = ReceiverPredicates.receiver_signature(facts)
          return nil if method_def.nil?

          param_overrides = Rigor::RbsExtended.param_type_override_map(method_def, environment: scope.environment)
          mismatch = argument_mismatch(method_def.method_types, call_node, scope, param_overrides, facts.scope_index)
          return nil if mismatch.nil?
          return nil if argument_report_withheld?(receiver_type, class_name, call_node, mismatch, scope, lexical_sites)

          build_argument_type_diagnostic(path, call_node, class_name, mismatch)
        end

        # The declines `call.argument-type-mismatch` asks only once an argument mismatches.
        def argument_report_withheld?(receiver_type, class_name, call_node, mismatch, scope, lexical_sites)
          return true if inferred_param_mismatch_verdict?(call_node, mismatch, scope)

          kind = receiver_type.is_a?(Type::Singleton) ? :singleton : :instance
          ReceiverPredicates.refined_redefinition_in_effect?(class_name, call_node, scope, kind, lexical_sites)
        end

        # ADR-67 WD6b — an argument-type-mismatch verdict resting on an open-call-site lower bound, on
        # either side of the call. The ARGUMENT side: the mismatching argument is an inferred-parameter
        # local, so firing against it is an FP by construction. The RECEIVER side: when the receiver roots
        # at an inferred parameter, the method whose parameter contract the argument was checked against
        # was itself resolved through a lower-bound type, so the whole verdict is speculative. The 2026-07-30
        # self-check surfaced the receiver half as a guard hole: seeding `env : RBS::Environment` activated
        # this rule on `env.unload(culprits)` and flagged a correct Array argument against `unload`'s
        # declared `Set[Pathname]` — an upstream signature stricter than its implementation, exactly the FP
        # class WD6b exists to suppress. The other guarded rules already declined on a param-rooted
        # receiver; this brings argument-type-mismatch in line.
        def inferred_param_mismatch_verdict?(call_node, mismatch, scope)
          ReceiverPredicates.inferred_param_argument?(mismatch[:node], scope) ||
            ReceiverPredicates.inferred_param_receiver?(call_node, scope)
        end

        # Single overload → the exact per-argument acceptance (unchanged).
        # Multiple overloads → the nil channel (a pure-`nil` argument every
        # overload rejects) plus, on non-coerce methods, the non-nil channel
        # (a single-concrete-class argument every overload rejects). See
        # {#multi_overload_argument_mismatch}.
        #
        # Each argument is typed from its own index entry, which is the call's unless an earlier operand moved
        # the scope it was entered from (issue #1256): `(k = 0; 5)[k]` checks `k` as the `0` it holds there.
        def argument_mismatch(method_types, call_node, scope, param_overrides, scope_index)
          mismatch =
            if method_types.size == 1
              first_argument_mismatch(method_types.first, call_node, scope, param_overrides, scope_index)
            else
              multi_overload_argument_mismatch(method_types, call_node, scope, param_overrides, scope_index)
            end
          return nil if mismatch && keyword_bearing?(method_types) && nil_tainted?(mismatch[:actual])

          mismatch
        end

        # Issue #673 widened {#argument_check_eligible?} to admit keyword-bearing signatures, whose
        # POSITIONAL arguments had gone unchecked. The widening is staged, and this is the half held
        # back: on such a signature only an argument refuted on its CLASS fires; one carrying `nil`
        # does not.
        #
        # Measured, not assumed. Across redmine, mastodon, tdiary-core, faraday, liquid and
        # rubocop-ast the widening produced exactly two new verdicts, both on correct code and both
        # resting on nullability: `Addrinfo.foreach(host, nil, nil, :STREAM)` (redmine — a nil service
        # is legal at runtime; rbs declares the parameter `String | ::Integer`) and
        # `Nokogiri::HTML5(html)` guarded by `return if html.nil?` one line above (mastodon — the guard
        # is on a method call, so the type stays `Dynamic[top]?`). Zero class-refuted new verdicts were
        # false. Nullability is the property a hand-written signature most often over-declares, so it
        # stays behind the old envelope until it has evidence of its own.
        #
        # Signatures WITHOUT keywords are untouched: `"a" + nil` fires exactly as before.
        def keyword_bearing?(method_types)
          method_types.any? do |method_type|
            function = method_type.type
            next false unless function.respond_to?(:required_keywords)

            !function.required_keywords.empty? || !function.optional_keywords.empty? ||
              !function.rest_keywords.nil?
          end
        end

        def nil_tainted?(actual)
          ReceiverPredicates.nil_member?(actual) ||
            (actual.is_a?(Type::Union) && NilReceiver.union_contains_nil?(actual))
        end

        # Multi-overload argument-type-mismatch. The dispatcher's per-overload
        # acceptance plumbing is not run here; instead the FP-safe shape mirrors
        # the "absent on every arm" union-undefined-method rule: an argument is
        # a mismatch only when EVERY overload's matching positional param
        # rejects it.
        #
        # Two channels, both gated on a positively-refuted argument:
        # - **nil** (any method): a pure `nil` no overload admits is a
        #   guaranteed `TypeError` — `nil` never coerces.
        # - **non-nil** (ADR-64, non-coerce methods only): an argument that
        #   types to a single concrete RBS-known class that no overload admits.
        #   Excludes {COERCE_DISPATCH_METHODS} (`5 + Money.new` is valid via
        #   `coerce`), restricts to a single concrete class (WD3 — a union arg
        #   stays deferred), and decides acceptance on the RBS param type
        #   ({#param_accepts_arg_class?}) so it sees through the `int` / `string`
        #   interface-aliases the translator degrades.
        def multi_overload_argument_mismatch(method_types, call_node, scope, param_overrides, scope_index)
          functions = method_types.map(&:type)
          return nil unless functions.all? { |function| argument_check_eligible?(function) }

          coerce_method = COERCE_DISPATCH_METHODS.include?(call_node.name)
          arguments = call_node.arguments&.arguments || []
          arguments.each_with_index do |arg, index|
            params = checkable_overload_params(method_types, index, param_overrides, scope)
            next if params.nil?

            mismatch = overload_argument_mismatch(arg, params, param_overrides,
                                                  argument_scope(arg, scope, scope_index), coerce_method)
            return mismatch if mismatch
          end
          nil
        end

        # The mismatch (or nil) for one argument against the parameter every overload has at its position. Issue
        # #1362 — a builtin global's seed, or its copy, is judged by the file's writes to the global.
        def overload_argument_mismatch(arg, params, param_overrides, arg_scope, coerce_method)
          written = DeclarationSourcedGuard.written_type(arg, arg_scope)
          arg_type = written || arg_scope.type_of(arg)
          if ReceiverPredicates.nil_member?(arg_type) # pure nil only — not a `T | nil` union
            nil_arg_overload_mismatch(arg, arg_type, params, param_overrides, arg_scope, written: !written.nil?)
          elsif !coerce_method
            non_nil_arg_overload_mismatch(arg, arg_type, params, param_overrides, arg_scope)
          end
        end

        # The parameter set at `index` that a verdict may rest on, or nil when there is none — the two
        # reasons being arity divergence (an overload with no param there, which is `call.wrong-arity`'s
        # concern) and an overload whose param names a class carrying no definition ({#stub_typed_param?},
        # issue #661). Both channels below fire only when EVERY overload rejects, so either one is enough
        # to unseat that premise.
        def checkable_overload_params(method_types, index, param_overrides, scope)
          params = overload_positional_params(method_types, index)
          return nil if params.nil?
          return nil if params.any? { |param| stub_typed_param?(param, param_overrides, scope) }

          params
        end

        # The nil channel: a pure `nil` argument no overload admits (ADR-58
        # parity excuses a declaration-sourced ivar nil).
        def nil_arg_overload_mismatch(arg, arg_type, params, param_overrides, scope, written: false)
          return nil if !written && declaration_sourced_nil_argument?(arg, scope)
          return nil if params.any? { |param| param_admits_nil?(param, param_overrides, scope) }

          { node: arg, name: nil, expected: overload_param_expected_label(params), actual: arg_type }
        end

        # The non-nil channel (ADR-64 WD2/WD3): a single-concrete-class
        # argument no overload admits, on a non-coerce method.
        def non_nil_arg_overload_mismatch(arg, arg_type, params, param_overrides, scope)
          return class_object_overload_mismatch(arg, arg_type, params, param_overrides, scope) if
            arg_type.is_a?(Type::Singleton)
          return nil unless single_concrete_arg_class?(arg_type, scope)
          return nil if params.any? { |param| param_accepts_arg_class?(param, arg_type, param_overrides, scope) }

          { node: arg, name: nil, expected: overload_param_expected_label(params), actual: arg_type }
        end

        # Issue #2828 — the class-object twin of the non-nil channel. A `singleton(T)` overload the `resolv` overlay
        # prepends turned `getresources(d, String)`'s one-overload check (`expected singleton(Resolv::DNS::Query)`)
        # into this multi-overload one, which declined every class object. It fires only when every overload's
        # parameter at the position is a `singleton(...)` (a `singleton(T)` read through its class bound, see
        # `SingletonTypeParams.selection_param`) that provably refuses the argument's class; any other parameter
        # shape admits.
        def class_object_overload_mismatch(arg, arg_type, params, param_overrides, scope)
          return nil unless Rigor::Reflection.rbs_class_known?(arg_type.class_name, scope: scope)
          return nil unless params.all? do |param|
            !param_overrides[param.name] && param.type.is_a?(RBS::Types::ClassSingleton)
          end
          return nil unless params.all? { |param| class_singleton_refuses?(param.type, arg_type, scope) }

          expected = params.map { |param| param.type.to_s.sub("singleton(::", "singleton(") }.uniq.join(" | ")
          { node: arg, name: nil, expected: expected, actual: arg_type }
        end

        def class_singleton_refuses?(rbs_type, arg_type, scope)
          translated = translate_param_type(rbs_type, scope.environment)
          translated.is_a?(Type::Singleton) && Inference::Acceptance.accepts(translated, arg_type, mode: :gradual).no?
        end

        # The matching positional RBS param across every overload, or nil when
        # any overload has no param at `index` (arity divergence — the
        # wrong-arity rule's concern, not this one's).
        def overload_positional_params(method_types, index)
          params = method_types.map do |method_type|
            function = method_type.type
            param = (function.required_positionals + function.optional_positionals)[index]
            param && resolve_param_bounds(param, method_type)
          end
          params.any?(&:nil?) ? nil : params
        end

        # Substitutes each bounded method-level type parameter for its bound, so
        # `[I < _ToInt] (I index) -> …` is walked as `(_ToInt index) -> …`. A bare
        # `Variable` is undecidable to the acceptance walk and admits everything,
        # which silently disables both channels for the whole overload; the bound
        # constrains the argument exactly as an ordinary param of that type would.
        # Load-bearing since rbs 4.1 rewrote core signatures into this form
        # (`Array#fetch`'s block overload is `[I < _ToInt, T] (I index) { … }`).
        def resolve_param_bounds(param, method_type)
          param = Inference::MethodDispatcher::SingletonTypeParams.selection_param(param, method_type)
          bounded = method_type.type_params.select(&:upper_bound)
          return param if bounded.empty?

          substitution = RBS::Substitution.build(bounded.map(&:name), bounded.map(&:upper_bound))
          param.map_type { |type| type.sub(substitution) }
        end

        # ADR-26 WD8's PARAMETER-side twin (issue #661). `sig/app.rbs` declaring
        # `(ActiveSupport::TimeWithZone) -> void` in a project that never brings ActiveSupport's RBS in
        # names a class that carries no definition anywhere in the environment. Rigor still refuted
        # `App.take_twz(Time.now)` against it — `expected ActiveSupport::TimeWithZone, got Time` on a call
        # that works — because the acceptance walk compares nominals and `Time`'s ancestry does not list a
        # name nothing declares.
        #
        # WD8 already declines the two signature rules on such a RECEIVER, on the ground that there is
        # nothing authoritative to check the call against. It is the same one position over: with no
        # ancestry there is no fact that could make an argument satisfy the parameter either, so the
        # rejection is the missing signature restated as an error rather than a finding about the program.
        # Under AGENTS.md's false-positives-outrank-worst-case rule the honest answer is to decline, and
        # the report it costs is one the analyzer never had evidence for.
        #
        # Both shapes the missing name arrives in are covered, deliberately as ONE criterion. A name an
        # INSTANCE-method signature references is minted as an empty stub so the class builds
        # ({Environment::RbsLoader.stub_missing_referenced_types}) and reads back as RBS-known; the same
        # name in a SINGLETON signature is not, because that pass mirrors rbs's own membership test and
        # `validate_type_params` never reaches singleton members. That asymmetry is an artifact of which
        # pass ran, not of what is knowable, and the issue's own repro is the singleton half.
        #
        # A `rigor:v1:param` override is a real Rigor type the author wrote against the call site's own
        # method, so it is consulted first and checked normally.
        def stub_typed_param?(param, param_overrides, scope)
          return false if param_overrides[param.name]

          undefined_param_class?(param.type, scope)
        end

        # Only the arms a verdict can rest on directly: a union member, an optional's inner type, an
        # expanded alias, and the class instance / singleton itself. Deliberately NOT recursive into type
        # ARGUMENTS — `Array[Missing]` is still refuted by an `Integer` argument on the `Array` alone, and
        # declining there would be a lost report bought for nothing.
        def undefined_param_class?(rbs_type, scope)
          case rbs_type
          when RBS::Types::Union then rbs_type.types.any? { |member| undefined_param_class?(member, scope) }
          when RBS::Types::Optional then undefined_param_class?(rbs_type.type, scope)
          when RBS::Types::Alias
            expanded = scope.environment&.rbs_loader&.expand_type_alias(rbs_type)
            !expanded.nil? && undefined_param_class?(expanded, scope)
          when RBS::Types::ClassInstance, RBS::Types::ClassSingleton
            name = rbs_type.name
            ReceiverPredicates.synthesized_stub_receiver?(name, scope) ||
              !Rigor::Reflection.rbs_class_known?(name.to_s, scope: scope)
          else false
          end
        end

        # The class names whose instances `nil` IS — `NilClass` and every
        # ancestor. A parameter typed as any other class instance rejects nil.
        NIL_COMPATIBLE_CLASS_NAMES = %w[NilClass Object BasicObject Kernel].to_set.freeze
        private_constant :NIL_COMPATIBLE_CLASS_NAMES

        # Does this parameter admit a `nil` argument? Decided on the RBS
        # parameter type (a `rigor:v1:param` override takes precedence).
        # Conservative throughout: any case we cannot decide returns true
        # (admits → do not fire), so the rule never fires on uncertainty.
        def param_admits_nil?(param, param_overrides, scope)
          override = param_overrides[param.name]
          return rigor_type_admits_nil?(override) if override

          rbs_type_admits_nil?(param.type, scope)
        end

        # The `rigor:v1:param` override variant — a refinement
        # (`non-empty-string`) rejects nil; an explicit nil / nilable union /
        # gradual override admits it.
        def rigor_type_admits_nil?(type)
          return true if type.is_a?(Type::Dynamic) || type.is_a?(Type::Top)
          return true if ReceiverPredicates.nil_member?(type)
          return NilReceiver.union_contains_nil?(type) if type.is_a?(Type::Union)

          false
        end

        # Walks the RBS parameter type. The load-bearing cases are `Alias`
        # (`string` = `String | _ToStr`) and `Interface` (`_ToStr`), which
        # {Inference::RbsTypeTranslator} degrades to `untyped` — the reason a
        # `nil` argument is invisible after translation (the interface-alias
        # gap). Resolving them here recovers the rejection. Only a concrete
        # class instance that is not a `nil` ancestor, and an interface
        # NilClass does not satisfy, return false; everything else admits.
        def rbs_type_admits_nil?(rbs_type, scope)
          case rbs_type
          when RBS::Types::Union then rbs_type.types.any? { |member| rbs_type_admits_nil?(member, scope) }
          when RBS::Types::Alias
            expanded = scope.environment&.rbs_loader&.expand_type_alias(rbs_type)
            expanded.nil? || rbs_type_admits_nil?(expanded, scope)
          when RBS::Types::ClassInstance
            NIL_COMPATIBLE_CLASS_NAMES.include?(rbs_type.name.to_s.delete_prefix("::"))
          when RBS::Types::Interface then interface_admits_nil?(rbs_type, scope)
          else true # Optional / bases / variable / tuple / record / proc / literal / intersection → conservative admit
          end
        end

        # An interface parameter (`_ToStr`) admits nil only when NilClass
        # implements every method it requires (`to_str`, `to_int`, … — which
        # NilClass does not, so `string` / `int` params reject nil; a
        # hypothetical `_ToS` would admit, since NilClass#to_s exists).
        # Unresolvable → conservative true.
        def interface_admits_nil?(rbs_type, scope)
          loader = scope.environment&.rbs_loader
          return true if loader.nil?

          methods = loader.interface_method_names(rbs_type.name.to_s)
          return true if methods.nil? || methods.empty?

          methods.all? { |method_name| NilReceiver.nil_class_has_method?(method_name, scope) }
        end

        # ADR-64 WD3 — the non-nil channel fires only on an argument that types
        # to a single concrete, RBS-known class. A union arg mirrors the
        # union-receiver story and stays deferred; a class/module object
        # (`Singleton`) has a special acceptance surface and is skipped; a
        # non-RBS project class is skipped because its conversion protocol (a
        # duck-typed `to_int` / `to_str`) is invisible to us, so we cannot
        # refute acceptance.
        def single_concrete_arg_class?(arg_type, scope)
          return false if arg_type.is_a?(Type::Union)
          return false if arg_type.is_a?(Type::Singleton)

          class_name = ReceiverPredicates.concrete_class_name(arg_type)
          return false if class_name.nil?

          Rigor::Reflection.rbs_class_known?(class_name, scope: scope)
        end

        # ADR-64 WD2 — does this parameter accept the (non-nil) argument?
        # The non-nil generalization of {#param_admits_nil?}: decided on the RBS
        # parameter type (a `rigor:v1:param` override takes precedence) so it
        # sees through the `int` / `string` interface-aliases the translator
        # degrades to gradual. Conservative throughout — any case we cannot
        # decide returns true (accepts → do not fire).
        def param_accepts_arg_class?(param, arg_type, param_overrides, scope)
          override = param_overrides[param.name]
          return rigor_type_accepts_arg?(override, arg_type) if override

          rbs_type_accepts_arg?(param.type, arg_type, scope)
        end

        # The `rigor:v1:param` override variant — a Rigor `Type`, so the
        # acceptance engine decides directly (gradual; only a proven rejection
        # refutes). Dynamic / Top admit unconditionally.
        def rigor_type_accepts_arg?(param_type, arg_type)
          return true if param_type.is_a?(Type::Dynamic) || param_type.is_a?(Type::Top)

          !Inference::Acceptance.accepts(param_type, arg_type, mode: :gradual).no?
        end

        # Walks the RBS parameter type, mirroring {#rbs_type_admits_nil?}. The
        # load-bearing cases are `Alias` / `Interface` (`int` = `Integer |
        # _ToInt`), which the translator degrades to gradual — resolving them
        # here recovers the rejection. A faithfully-translated `ClassInstance`
        # is handed to the acceptance engine; everything undecidable admits.
        def rbs_type_accepts_arg?(rbs_type, arg_type, scope)
          case rbs_type
          when RBS::Types::Union then rbs_type.types.any? { |member| rbs_type_accepts_arg?(member, arg_type, scope) }
          when RBS::Types::Alias
            expanded = scope.environment&.rbs_loader&.expand_type_alias(rbs_type)
            expanded.nil? || rbs_type_accepts_arg?(expanded, arg_type, scope)
          when RBS::Types::ClassInstance then class_instance_accepts_arg?(rbs_type, arg_type, scope)
          when RBS::Types::Interface then interface_accepts_arg?(rbs_type, arg_type, scope)
          else true # bases / variable / tuple / record / proc / literal / intersection / optional → conservative admit
          end
        end

        # A `ClassInstance` param (`Integer`, `Numeric`, …) is translated
        # faithfully (no interface degradation), so the acceptance engine — the
        # canonical RBS-ancestry / generic-aware subtype check — decides it.
        # Only a proven rejection refutes; an unresolvable class is `:maybe`,
        # which admits.
        def class_instance_accepts_arg?(rbs_type, arg_type, scope)
          translated = translate_param_type(rbs_type, scope.environment)
          return true if translated.is_a?(Type::Dynamic) || translated.is_a?(Type::Top)

          !Inference::Acceptance.accepts(translated, arg_type, mode: :gradual).no?
        end

        # An interface param (`_ToInt`) accepts the arg only when the arg's
        # class implements every method it requires (`to_int`, …). The non-nil
        # mirror of {#interface_admits_nil?}: ask the arg class, not NilClass.
        # Unresolvable anywhere → conservative true (admit).
        def interface_accepts_arg?(rbs_type, arg_type, scope)
          loader = scope.environment&.rbs_loader
          return true if loader.nil?

          methods = loader.interface_method_names(rbs_type.name.to_s)
          return true if methods.nil? || methods.empty?

          class_name = ReceiverPredicates.concrete_class_name(arg_type)
          return true if class_name.nil?

          methods.all? { |method_name| arg_class_has_method?(class_name, method_name, scope) }
        end

        # The non-nil mirror of {NilReceiver.nil_class_has_method?}, but conservative on
        # the unknown side: an unresolvable definition returns true (the class
        # *might* implement the method — e.g. a metaprogrammed conversion), so
        # the channel never fires on uncertainty.
        def arg_class_has_method?(class_name, method_name, scope)
          definition = Rigor::Reflection.instance_definition(class_name, scope: scope)
          return true if definition.nil?

          !definition.methods[method_name.to_sym].nil?
        end

        # A readable "expected" label for a multi-overload mismatch — the RBS
        # parameter type(s) as written (`string`, or the per-overload set), since
        # the translated Rigor type degrades the interface-alias the rejection
        # hinges on. Shared by the nil and non-nil channels.
        def overload_param_expected_label(params)
          params.map { |param| param.type.to_s.delete_prefix("::") }.uniq.join(" | ")
        end

        # ADR-58 parity for the nil channel: a declaration-sourced read that
        # types as nil is the same not-diagnostic-fuel case the union path
        # gates in {#declaration_sourced_nil_only_mismatch?}; suppress it here
        # too so a ctor-seeded `@x = nil` read passed as an argument does not
        # fire on a working program's cross-method invariant. Issue #324 —
        # delegates to {DeclarationSourcedGuard}, so a local copy of the ivar
        # (`c = @count`) is excused on the same terms `possible-nil-receiver`
        # already excused it.
        def declaration_sourced_nil_argument?(arg, scope)
          DeclarationSourcedGuard.marked?(arg, scope)
        end

        def first_argument_mismatch(method_type, call_node, scope, param_overrides, scope_index)
          function = method_type.type
          return nil unless argument_check_eligible?(function)

          params = function.required_positionals + function.optional_positionals
          arguments = call_node.arguments&.arguments || []
          arguments.each_with_index do |arg, index|
            param = params[index]
            next if param.nil? # arity mismatch is the wrong-arity rule's concern.

            mismatch = single_argument_mismatch(param, arg, argument_scope(arg, scope, scope_index), param_overrides)
            return mismatch if mismatch
          end
          nil
        end

        # The scope `arg` is checked from: its own index entry ({#argument_mismatch}), else the call's.
        def argument_scope(arg, call_scope, scope_index)
          scope_index[arg] || call_scope
        end

        # The mismatch (or nil) for one positional argument against one
        # parameter. The nil channel decides a pure `nil` argument on the RBS
        # parameter type — seeing through the `string` / `int` interface-alias
        # the translator degrades to gradual (so `"a" + nil` fires), excusing a
        # declaration-sourced ivar nil (ADR-58 parity). The non-nil channel is
        # the original translated-acceptance check, with a `rigor:v1:param`
        # override taking precedence over the RBS-declared type.
        def single_argument_mismatch(param, arg, scope, param_overrides)
          return nil if stub_typed_param?(param, param_overrides, scope)

          # Issue #1362 (ADR-58 parity, ADR-117 Decision point 2) — a read of a builtin global still on its declared
          # seed, or a local copied from one, is judged by the file's writes to the global, as the argument was
          # before the join: the declared members are not diagnostic fuel.
          written = DeclarationSourcedGuard.written_type(arg, scope)
          return written_argument_mismatch(param, arg, written, scope, param_overrides) if written

          read_argument_mismatch(param, arg, scope, param_overrides)
        end

        # {#single_argument_mismatch} for an argument that reads no builtin global's seed directly.
        def read_argument_mismatch(param, arg, scope, param_overrides)
          arg_type = scope.type_of(arg)

          if ReceiverPredicates.nil_member?(arg_type)
            return nil if declaration_sourced_nil_argument?(arg, scope)
            return nil if param_admits_nil?(param, param_overrides, scope)

            return { node: arg, name: param.name, expected: overload_param_expected_label([param]), actual: arg_type }
          end

          param_type = param_overrides[param.name] || translate_param_type(param.type, scope.environment)
          return nil if param_type.is_a?(Type::Dynamic) || param_type.is_a?(Type::Top)
          return nil if arg_type.is_a?(Type::Dynamic) || arg_type.is_a?(Type::Top)
          return nil if gradual_narrowing_accepted?(arg, arg_type, param_type, scope)
          return nil unless argument_genuinely_mismatches?(arg, arg_type, param_type, scope)
          # Issue #1362 — a value that mixes such a global with something else (`c ? $stdout : StringIO.new`) is judged
          # without the declared members the file never writes, as it was before the join.
          return nil if DeclarationSourcedGuard.declared_only_rejection?(arg_type, param_type, scope) do |stripped|
            !plain_argument_rejects?(param, stripped, scope, param_overrides)
          end

          { node: arg, name: param.name, expected: param_type, actual: arg_type }
        end

        # The mismatch for an argument judged by `written`, the file's writes to the builtin globals it reads the
        # seeds of, through the channels {#single_argument_mismatch} runs, without the ADR-58 withholding: before
        # the join the global carried no mark.
        def written_argument_mismatch(param, arg, written, scope, param_overrides)
          return nil unless plain_argument_rejects?(param, written, scope, param_overrides)

          expected =
            if ReceiverPredicates.nil_member?(written)
              overload_param_expected_label([param])
            else
              param_overrides[param.name] || translate_param_type(param.type, scope.environment)
            end
          { node: arg, name: param.name, expected: expected, actual: written }
        end

        # True when `param` rejects an argument of type `type` on the terms of {#single_argument_mismatch}'s nil and
        # non-nil channels, without the ADR-58 withholding.
        def plain_argument_rejects?(param, type, scope, param_overrides)
          return !param_admits_nil?(param, param_overrides, scope) if ReceiverPredicates.nil_member?(type)

          param_type = param_overrides[param.name] || translate_param_type(param.type, scope.environment)
          return false if param_type.is_a?(Type::Dynamic) || param_type.is_a?(Type::Top)
          return false if type.is_a?(Type::Dynamic) || type.is_a?(Type::Top)

          Inference::Acceptance.accepts(param_type, type, mode: :gradual).no?
        end

        # Issue #2656 — a local a class guard narrowed from a `Dynamic` value
        # ({DeclarationSourcedGuard.gradual_narrowed?}) is judged by its class, not by the literals the parameter
        # names: `mode(x) if x.is_a?(String)` with `mode: ("r" | "w")` is accepted, as the gradual value was, while
        # `num(x) if x.is_a?(String)` with `num: (1 | 2)` still reports, since no String is ever `1` or `2`. The
        # parameter's value-pinned members are widened to their classes ({Type::Combinator.widen_value_pinned}) and
        # the narrowed type is judged against that. The overload path ({#non_nil_arg_overload_mismatch}) already
        # judges by class, so it needs no such reading.
        #
        # A literal member of the narrowed type did not come from the gradual value (`x = h[:m] || "r"` narrows to
        # `"r" | String`), so it is judged against the parameter as written.
        def gradual_narrowing_accepted?(arg, arg_type, param_type, scope)
          return false unless DeclarationSourcedGuard.gradual_narrowed?(arg, scope)

          members = arg_type.is_a?(Type::Union) ? arg_type.members : [arg_type]
          literals, rest = members.partition { |member| member.is_a?(Type::Constant) }
          if literals.any? { |member| Inference::Acceptance.accepts(param_type, member, mode: :gradual).no? }
            return false
          end
          return true if rest.empty?

          widened = Type::Combinator.widen_value_pinned(param_type)
          !Inference::Acceptance.accepts(widened, Type::Combinator.union(*rest), mode: :gradual).no?
        end

        # The parameter rejects the argument AND the rejection is not a
        # withheld declaration-sourced-nil case.
        def argument_genuinely_mismatches?(arg, arg_type, param_type, scope)
          return false unless rejects_beyond_class_objects?(param_type, arg_type)

          # ADR-58 (N2 extension) — the same declaration-sourced-nil-is-not-
          # diagnostic-fuel criterion that governs `possible-nil-receiver`
          # applies here. When the only reason the argument is rejected is a
          # *declaration-sourced* nil constituent (the class-ivar index seed
          # of a ctor `@x = nil` / a non-definitely-assigned ivar read), and
          # the argument type with that nil removed WOULD be accepted, the
          # working program's cross-method invariant is assumed and we do not
          # fire. Flow-live nil (a method-local `@x = nil` write, a failed-
          # guard narrowing) drops the provenance mark upstream and still
          # fires. The argument's type is unchanged — only the firing
          # decision is gated.
          !declaration_sourced_nil_only_mismatch?(arg, arg_type, param_type, scope)
        end

        # Issue #2855 — the parameter rejects the argument, and not only for its `Class` / `Module` members. An
        # unparameterised `Class` or `Module` nominal ({Acceptance.class_or_module_nominal?}) against a parameter
        # that admits class objects (`singleton(X)`, alone or in a union) is a class object whose identity inference
        # lost — a `const_get` result kept by `is_a?(Class)`, an `is_a?(Module)` guard — so it is withheld. The rest
        # of the argument is still judged: `Class | Integer` against `singleton(X)` reports for its `Integer`.
        # Acceptance itself keeps answering `no`, so overload selection is unchanged.
        def rejects_beyond_class_objects?(param_type, arg_type)
          return false unless Inference::Acceptance.accepts(param_type, arg_type, mode: :gradual).no?
          return true unless admits_class_objects?(param_type)

          members = arg_type.is_a?(Type::Union) ? arg_type.members : [arg_type]
          rest = members.reject { |member| Inference::Acceptance.class_or_module_nominal?(member) }
          return true if rest.size == members.size

          Inference::Acceptance.accepts(param_type, Type::Combinator.union(*rest), mode: :gradual).no?
        end

        def admits_class_objects?(param_type)
          case param_type
          when Type::Singleton then true
          when Type::Union then param_type.members.any?(Type::Singleton)
          else false
          end
        end

        # True when `arg` is a declaration-sourced read whose rejection is
        # caused solely by its nil constituent: stripping nil from the argument
        # type yields a type the parameter accepts (gradual mode). Mirrors the
        # `possible-nil-receiver` WD1 gate — since issue #324 through the very
        # same {DeclarationSourcedGuard} predicate, so the ivar read and its
        # local copy (`c = @count`) are one case rather than two spellings that
        # can drift apart again.
        def declaration_sourced_nil_only_mismatch?(arg, arg_type, param_type, scope)
          return false unless DeclarationSourcedGuard.marked?(arg, scope)
          return false unless arg_type.is_a?(Type::Union)
          return false unless NilReceiver.union_contains_nil?(arg_type)

          non_nil = Type::Combinator.union(*arg_type.members.reject { |m| ReceiverPredicates.nil_member?(m) })
          return false if non_nil.is_a?(Type::Bot)

          result = Inference::Acceptance.accepts(param_type, non_nil, mode: :gradual)
          # Issue #2855 — a `Class?` ivar against `singleton(X)` is withheld as its `Class` alone would be.
          # Issue #2863 — a `maybe` (a project class the host process has not loaded, so its ancestry is unresolved:
          # `singleton(Circle)` against `singleton(Shape)`) is not a rejection either: the non-nil part alone would not
          # fire, so the nil is the only reason and it is withheld.
          !result.no? || !rejects_beyond_class_objects?(param_type, non_nil)
        end

        # What this rule needs is that argument N binds to positional
        # parameter N, so the only disqualifiers are the two shapes that
        # break that mapping: a rest positional (arguments past it belong
        # to the rest, not to a later parameter) and trailing positionals
        # (the last arguments bind backwards from the end).
        #
        # Issue #673 — a keyword parameter used to disqualify the whole
        # signature, which silently unchecked the POSITIONAL arguments of
        # every keyword-bearing signature in the bundle:
        # `time.beginning_of_week("monday")` fired while
        # `time.next_week("monday")`, `(?Symbol, ?same_time: bool)`, did not,
        # though both raise the same way at runtime. Keywords cannot shift a
        # positional argument's index, and a call that PASSES keywords never
        # reaches here at all — `WrongArity.plain_positional_call?` rejects a
        # `KeywordHashNode` argument (`**opts` included) before the signature
        # is consulted.
        def argument_check_eligible?(function)
          # See `WrongArity.arity_eligible?`: `UntypedFunction` lacks
          # the per-arity accessors. Treat it as ineligible
          # for argument-type-mismatch diagnostics.
          return false unless function.respond_to?(:required_keywords)

          function.rest_positionals.nil? && function.trailing_positionals.empty?
        end

        def translate_param_type(rbs_type, environment)
          Inference::RbsTypeTranslator.translate(rbs_type, alias_expander: environment&.rbs_loader)
        rescue StandardError
          Type::Combinator.untyped
        end

        def build_argument_type_diagnostic(path, call_node, class_name, mismatch)
          method_label = "`#{call_node.name}' on #{class_name}"
          parameter_label = mismatch[:name] ? "parameter `#{mismatch[:name]}' of #{method_label}" : method_label
          expected = mismatch[:expected]
          expected_description = expected.is_a?(String) ? expected : expected.describe(:short)
          message = "argument type mismatch at #{parameter_label}: " \
                    "expected #{expected_description}, " \
                    "got #{mismatch[:actual].describe(:short)}"
          Diagnostic.from_node(
            mismatch[:node],
            rule: RULE_ARGUMENT_TYPE,
            path: path,
            message: message,
            severity: :error,
            receiver_type: class_name,
            method_name: call_node.name.to_s
          )
        end

        private_class_method :argument_report_withheld?, :inferred_param_mismatch_verdict?, :argument_mismatch,
                             :keyword_bearing?, :nil_tainted?, :multi_overload_argument_mismatch,
                             :overload_argument_mismatch, :checkable_overload_params, :nil_arg_overload_mismatch,
                             :non_nil_arg_overload_mismatch, :class_object_overload_mismatch,
                             :class_singleton_refuses?, :overload_positional_params, :resolve_param_bounds,
                             :stub_typed_param?, :undefined_param_class?, :param_admits_nil?, :rigor_type_admits_nil?,
                             :rbs_type_admits_nil?, :interface_admits_nil?, :single_concrete_arg_class?,
                             :param_accepts_arg_class?, :rigor_type_accepts_arg?, :rbs_type_accepts_arg?,
                             :class_instance_accepts_arg?, :interface_accepts_arg?, :arg_class_has_method?,
                             :overload_param_expected_label, :declaration_sourced_nil_argument?,
                             :first_argument_mismatch, :argument_scope, :single_argument_mismatch,
                             :read_argument_mismatch, :written_argument_mismatch, :plain_argument_rejects?,
                             :gradual_narrowing_accepted?, :argument_genuinely_mismatches?,
                             :rejects_beyond_class_objects?, :admits_class_objects?,
                             :declaration_sourced_nil_only_mismatch?, :argument_check_eligible?,
                             :translate_param_type, :build_argument_type_diagnostic
      end
    end
  end
end
