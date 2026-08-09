# frozen_string_literal: true

require "prism"

module Rigor
  module Analysis
    module CheckRules
      # ADR-58 WD1 — the shared "is this value's optionality declaration-sourced?" predicate.
      #
      # A `nil` whose only provenance is a declaration (the class-ivar index seed of a ctor `@x = nil`, a
      # non-definitely-assigned ivar read) is real type information but not diagnostic fuel: the working
      # program's cross-method invariant is assumed per the robustness principle ([ADR-5]). Every negative rule
      # that would fire *because of* such a nil must therefore consult the same provenance question, and get the
      # same answer.
      #
      # Before issue #324 each rule spelled the lookup itself, and they drifted: `call.possible-nil-receiver`
      # read the `:local` mark (so `r = @right; r.key` was excused — ADR-58's own motivating shape), while both
      # `call.argument-type-mismatch` gates opened by requiring a literal `Prism::InstanceVariableReadNode`, so
      # `c = @count; sink.take_int(c)` fired on the same value with the same provenance. This module is that one
      # question, asked in one place.
      #
      # **The mark is deliberately NOT transitive.** `Scope#with_declaration_sourced_local`
      # ({Inference::StatementEvaluator#eval_local_write}) stamps `:local` only when the RHS is a *pure read of a
      # currently declaration-sourced ivar*, so a second hop (`c = @count; d = c`) and an `||=` rewrite land on
      # the plain `with_local` path and carry no mark.
      #
      # A branch join is NOT one of those cases, contrary to what this comment claimed when it landed: both
      # arms of `if c then r = @count else r = @count end` stamp `(:local, :r)`, and `join_declaration_sourced`
      # INTERSECTS, so the mark survives. Only an *asymmetric* join drops it, and by that intersection rather
      # than by reaching `with_local`. The normative statement — establishment, drop, join and the full list of
      # unmarked shapes, each verified against the implementation — is
      # `docs/internal-spec/inference-engine.md` § "Declaration-sourced provenance mark (ADR-58)"; keep this
      # comment subordinate to it.
      #
      # So `marked?` matches exactly the two node shapes the scope actually models and invents no propagation
      # of its own; anything flow-live keeps firing.
      module DeclarationSourcedGuard
        module_function

        # True when `node` is a direct read of a binding whose optionality is purely declaration-sourced. Any
        # flow-live touch (a method-local `@x = nil` write, a failed-guard narrowing, a rebinding local write)
        # drops the mark upstream, so this returns false there and the caller fires exactly as before.
        def marked?(node, scope)
          case node
          when Prism::InstanceVariableReadNode then scope.declaration_sourced?(:ivar, node.name)
          when Prism::LocalVariableReadNode then scope.declaration_sourced?(:local, node.name)
          else false
          end
        end
      end
    end
  end
end
