# frozen_string_literal: true

require "prism"
require_relative "../../reflection"
require_relative "../../type"
require_relative "../../inference/key_presence_guard"
require_relative "../diagnostic"
require_relative "declaration_sourced_guard"
require_relative "receiver_predicates"
require_relative "rule_ids"

module Rigor
  module Analysis
    module CheckRules
      # ADR-116 WD1 — `call.possible-nil-receiver` (slice 7 phase 14): a call on a local variable whose type
      # is a union carrying `nil`, to a method `NilClass` does not define, where every non-nil arm does.
      #
      # The entry point is {.diagnostic}, called by `CheckRules.call_node_diagnostics`.
      # {.union_contains_nil?} and {.nil_class_has_method?} are public because `CheckRules`' argument-type
      # rule asks the same two questions. It reads {ReceiverPredicates}, {DeclarationSourcedGuard} and
      # `Inference::KeyPresenceGuard`, and calls nothing in `CheckRules`.
      module NilReceiver
        module_function

        # Slice 7 phase 14 — nil-receiver diagnostic. Fires when
        # the receiver type is a `Type::Union` containing a
        # nil-bearing member (`Constant[nil]` or
        # `Nominal[NilClass]`) AND the called method does not
        # exist on `NilClass`. This is the canonical "you forgot
        # to nil-check before calling X" signal: the engine has
        # proved that on at least one execution path the receiver
        # is nil, and the call would raise NoMethodError.
        #
        # The rule deliberately ignores receivers that are
        # exactly `Constant[nil]` / `Nominal[NilClass]` (those
        # are already covered by `undefined_method_diagnostic`)
        # and union receivers where every member already
        # disqualifies the call (avoid duplicating the
        # undefined-method diagnostic).
        def diagnostic(path, call_node, facts, lexical_sites = nil)
          return nil if call_node.receiver.nil?
          # Safe-navigation calls (`recv&.method`) already
          # short-circuit on nil at runtime, so a nil-bearing
          # receiver is not a bug for them.
          return nil if call_node.safe_navigation?
          # Restrict to direct local-variable reads. Local
          # narrowing (Slice 6 phase 1) is the only narrowing
          # surface that can prove a guard like
          # `return if x.nil?` removed nil from the union, so
          # firing on chained / method-call receivers would
          # produce false positives we cannot suppress.
          return nil unless call_node.receiver.is_a?(Prism::LocalVariableReadNode)

          scope = facts.scope
          return nil if scope.nil?

          # ADR-58 WD1 — a receiver whose `nil` constituent is purely
          # declaration-sourced (the class-ivar index seed of a ctor
          # `@x = nil` written in another method, possibly copied into a
          # local via `r = @right`) does not fire by default: the working
          # program's cross-method invariant is assumed per the robustness
          # principle. The nil stays in the displayed type; only its use as
          # diagnostic fuel is withheld. Any flow-live touch (method-local
          # nil write, failed-guard narrowing) drops the mark upstream, so
          # flow-observed nil keeps firing exactly as before. The receiver
          # is already narrowed to a local read above, so this asks
          # {DeclarationSourcedGuard} exactly what it asked before — but it
          # now asks it through the predicate the argument-type gates share
          # (issue #324), which is what keeps the two rules from drifting.
          #
          # Issue #1362 — a local copied from a global still on its declared seed (`sep = $/`) is asked against the
          # file's writes to that global instead: its declared `nil` is withheld, and one the file writes still fires.
          return nil if DeclarationSourcedGuard.withholds_nil?(call_node.receiver, scope)

          # ADR-67 WD6b — an inferred-parameter receiver's type (incl. any nil constituent unioned in from a
          # nil call site) is an open-call-site lower bound; a possible-nil firing against it is an FP by
          # construction. Decline.
          return nil if scope.inferred_param?(call_node.receiver.name)

          receiver_type = facts.receiver_type
          return nil unless receiver_type.is_a?(Type::Union)

          # The rule only fires when the analyzer has access to
          # an RBS loader; without it, the per-member method-
          # presence checks below cannot rule out a sound call.
          return nil unless Rigor::Reflection.rbs_class_known?("NilClass", scope: scope)

          return nil unless nil_bearing_union_witnesses?(receiver_type, call_node.name, scope)
          return nil if nil_receiver_withheld?(call_node, receiver_type, scope, facts.scope_index, lexical_sites)

          build_nil_receiver_diagnostic(path, call_node)
        end

        # The declines `call.possible-nil-receiver` asks only once a report would fire.
        def nil_receiver_withheld?(call_node, receiver_type, scope, scope_index, lexical_sites)
          # Issue #1703 — a `nil` that only a `key?` guard on the same receiver and key rules out. It re-walks the file
          # once with guards on, and only to withhold this report.
          return true if Inference::KeyPresenceGuard.withholds_nil?(call_node, receiver_type, lexical_sites&.root,
                                                                    scope_index)

          # ADR-121 WD7 — a refinement of `NilClass` (or one Rigor cannot read) in effect may define the name.
          ReceiverPredicates.refined_method_in_effect?("NilClass", call_node, scope, :instance, lexical_sites)
        end

        # The receiver-type half of the rule, factored out of the node-shape
        # guards above: the union must carry nil, must carry a non-nil arm the
        # presence question can be asked of, must support the method on every
        # non-nil arm (so the call is only wrong on the nil path), and the
        # method must be absent from `NilClass` (so the nil path really raises).
        def nil_bearing_union_witnesses?(receiver_type, method_name, scope)
          union_contains_nil?(receiver_type) &&
            union_has_nameable_non_nil_arm?(receiver_type, scope) &&
            union_method_present_on_non_nil?(receiver_type, method_name, scope) &&
            !nil_class_has_method?(method_name, scope)
        end

        def union_contains_nil?(union)
          union.members.any? { |member| ReceiverPredicates.nil_member?(member) }
        end

        # Possible-nil may witness only where the presence question below is
        # ANSWERABLE. `method_present_anywhere?` reports "present" for a
        # nameless arm (Dynamic / Top / Bot) — the permissive polarity the
        # union-undefined-method rule's FP safety rests on — so a union whose
        # non-nil arms are ALL nameless satisfied that gate vacuously and fired
        # on every method name, including names defined on no class anywhere.
        # That inverted the intent: the gate suppressed exactly where knowledge
        # exists (`String | nil` calling a nonexistent method stays silent) and
        # permitted exactly where none does. Requiring one nameable concrete
        # arm restores the polarity without touching the shared helper:
        # `String | nil` keeps firing, and so does `Dynamic | String | nil` —
        # the nameless arm stays permissive inside the all-arms check, which is
        # only about the arms' method surface. That union no longer arises from
        # a merge re-joining the narrowed edges of one untyped local, which
        # binds it back to `Dynamic[top]` (issue #1840,
        # `Inference::UntypedRejoin`); it still does when the program writes
        # the `nil` (`x = nil if c`) and no `nil?` edge strips it before the
        # re-joining merge, or when the arms are not a narrowing of one
        # untyped value.
        def union_has_nameable_non_nil_arm?(union, scope)
          union.members.any? do |m|
            next false if ReceiverPredicates.nil_member?(m)

            class_name = ReceiverPredicates.concrete_class_name(m)
            next false if class_name.nil?

            # Issue #574 — nameable is not the same as ANSWERABLE. `method_present_anywhere?` reports
            # "present" for a named arm nothing knows the surface of, purely because nothing is known —
            # which is the same vacuity this gate's docstring says it exists to prevent, one level in. A
            # plugin-minted nominal like `ActionController::Parameters` ships no RBS and has no project
            # source, so it counted as a full witness and `q = params[:q]; q.strip` fired at ERROR severity
            # on correct Rails code.
            Rigor::Reflection.rbs_class_known?(class_name, scope: scope) ||
              scope.discovered_classes.key?(class_name)
          end
        end

        # The non-nil members must collectively support the
        # method (i.e. for every non-nil member, the method
        # exists on its class via RBS or in-source discovery).
        # Without this guard, the rule would also fire on calls
        # that are unsound on the non-nil branch — that is the
        # `undefined_method_diagnostic` rule's job, and we want
        # exactly one diagnostic per offending call site.
        def union_method_present_on_non_nil?(union, method_name, scope)
          non_nil_members = union.members.reject { |m| ReceiverPredicates.nil_member?(m) }
          return false if non_nil_members.empty?

          non_nil_members.all? { |m| ReceiverPredicates.method_present_anywhere?(m, method_name, scope) }
        end

        def nil_class_has_method?(method_name, scope)
          definition = Rigor::Reflection.instance_definition("NilClass", scope: scope)
          return false if definition.nil?

          !definition.methods[method_name.to_sym].nil?
        end

        def build_nil_receiver_diagnostic(path, call_node)
          Diagnostic.from_message_loc(
            call_node,
            rule: RULE_NIL_RECEIVER,
            path: path,
            message: "possible nil receiver: `#{call_node.name}' is undefined on NilClass",
            severity: :error,
            method_name: call_node.name.to_s
          )
        end

        private_class_method :nil_receiver_withheld?, :nil_bearing_union_witnesses?, :union_has_nameable_non_nil_arm?,
                             :union_method_present_on_non_nil?, :build_nil_receiver_diagnostic
      end
    end
  end
end
