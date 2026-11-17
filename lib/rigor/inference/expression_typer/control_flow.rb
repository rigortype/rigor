# frozen_string_literal: true

require "prism"

require_relative "../../type"
require_relative "../clause_widening"
require_relative "../error_info"
require_relative "../loop_value_record"
require_relative "../narrowing"

module Rigor
  module Inference
    class ExpressionTyper
      # Typers of the control-flow nodes in value position: `if` / `unless`, `and` / `or`, `case` (with the three-valued
      # `when` certainty), `begin` / `rescue` and `expr rescue fallback`. Reads `scope` and `tracer`; calls back
      # {ExpressionTyper#type_of}, {ExpressionTyper#statements_or_nil} and {ExpressionTyper#typer_under}. The entries
      # are `type_of_conditional`, `type_of_and_or`, `type_of_case`, `type_of_begin`, `type_of_rescue`,
      # `type_of_rescue_modifier`; every other method is private to the module (ADR-116 C3). State is passed, not
      # shared: each entry takes the values it reads from the typer as trailing positional parameters (`scope`,
      # `tracer`) and the typer itself (`typer`) when it calls back.
      module ControlFlow
        module_function

        # `if` / `unless` in value position — the ternary `c ? a : b`, a modifier `(a unless c)`, or a
        # conditional written as an argument, a receiver, or a literal element. Issue #1003: this handler used
        # to type both arms in the receiver scope and union them, so the predicate's narrowing reached a
        # statement-position conditional (through `StatementEvaluator#eval_if`) and never a value-position
        # one: `f.finite? ? f : 0.0` read `0.0 | Float` while the `if` statement bound `0.0 | finite-float`.
        # It delegates to the statement evaluator instead of re-deriving the edges, so the two positions share
        # one narrowing application, one branch elision (ADR-47 WD5 version guards, the ADR-101
        # optimistic-carrier decline) and one terminating-arm rule, and cannot drift apart again. Only the
        # value is read; the post-scope belongs to whichever walk owns the statement.
        def type_of_conditional(node, scope, tracer)
          LoopValueRecord.fetch(node, scope) || LoopValueRecord.miss { scope.evaluate(node, tracer: tracer).first }
        end

        # `a && b` / `a || b` in value position. Issue #1016: this handler used to type both operands in the
        # receiver scope, so `x.finite? && x` read `Float | false` while the statement form bound
        # `false | finite-float`. Like `type_of_conditional`, it delegates to the statement evaluator, which owns
        # the RHS narrowing, the constant short-circuit and its issue #313 optimistic-carrier decline.
        def type_of_and_or(node, scope, tracer)
          scope.evaluate(node, tracer: tracer).first
        end

        # Three-valued evaluation of `case predicate when pattern` dispatch. For each `when` clause we ask:
        # under static types, does `pattern === predicate` definitely match (`:yes`), definitely not match
        # (`:no`), or possibly match (`:maybe`)? Walking in source order:
        #
        # - `:yes` — this branch fires, subsequent branches are unreachable. Result = union(prior `:maybe`
        #   branches, this `:yes` branch).
        # - `:no`  — branch dropped.
        # - `:maybe` — branch is a candidate, continue.
        #
        # If no `:yes` was reached, the else clause (or `Constant[nil]` when absent) is added to the candidate
        # set.
        #
        # The `case ... in` pattern-matching form (`CaseMatchNode`) and the predicate-less form (`case; when
        # c1; ...`) bypass the `===` analysis: pattern matching has richer semantics, and a predicate-less
        # `case` reduces to a `if c1; ...; elsif c2` chain. Issue #1495 — like {.type_of_conditional}, that
        # chain delegates to the statement evaluator, which narrows each arm by its conditions' edges, so
        # `[case; when x.nil? then "n"; else x end]` reads `"n" | String` as the statement form does.
        # Issue #1429 — each arm is typed under the subject's clause narrowing (`Narrowing.case_when_scopes`), the
        # scope the statement evaluator runs the arm in: `when Symbol then n` on `n: Integer | Symbol` answers
        # `Symbol`, and the `else` arm reads the subject every earlier clause has ruled out.
        def type_of_case(node, scope, tracer, typer)
          return type_of_case_simple_union(node, typer) if node.is_a?(Prism::CaseMatchNode)
          return scope.evaluate(node, tracer: tracer).first if node.predicate.nil?

          subject_type = typer.type_of(node.predicate)
          candidates = []
          reached_yes = false
          clause_scope = scope

          node.conditions.each do |when_node|
            conditions = when_node.respond_to?(:conditions) ? when_node.conditions : []
            body_scope, next_scope = Narrowing.case_when_scopes(node.predicate, conditions, clause_scope)
            certainty = case_when_branch_certainty(subject_type, when_node, scope, typer)
            candidates << case_arm_type(when_node, body_scope, scope, tracer, typer) unless certainty == :no
            if certainty == :yes
              reached_yes = true
              break
            end
            clause_scope = next_scope
          end

          candidates << case_arm_type(node.else_clause, clause_scope, scope, tracer, typer) unless reached_yes
          Type::Combinator.union(*candidates)
        end

        # The value of one `case` arm (`nil` for an absent `else`), typed under `arm_scope`.
        def case_arm_type(arm, arm_scope, scope, tracer, typer)
          return Type::Combinator.constant_of(nil) if arm.nil?

          arm_scope.equal?(scope) ? typer.type_of(arm) : arm_scope.type_of(arm, tracer: tracer)
        end

        def type_of_case_simple_union(node, typer)
          branch_types = node.conditions.map { |branch| typer.type_of(branch) }
          Type::Combinator.union(*branch_types, type_of_case_else(node, typer))
        end

        def type_of_case_else(node, typer)
          return Type::Combinator.constant_of(nil) if node.else_clause.nil?

          typer.type_of(node.else_clause)
        end

        # Combines per-pattern certainty across a `when` clause's conditions (`when a, b, c` ≡ `a === s || b
        # === s || c === s`). `:yes` if any pattern is `:yes`; `:no` if all are `:no`; `:maybe` otherwise.
        def case_when_branch_certainty(subject_type, when_node, scope, typer)
          return :maybe unless when_node.respond_to?(:conditions)

          results = when_node.conditions.map { |c| case_when_pattern_certainty(subject_type, c, scope, typer) }
          return :maybe if results.empty?
          return :yes if results.include?(:yes)
          return :no if results.all?(:no)

          :maybe
        end

        # Static three-valued certainty for `pattern === subject`. Specialises two pattern shapes:
        #
        # - **Class / Module reference** (`Integer`, `Foo::Bar`): reduce to `subject.is_a?(class)` via
        #   `Narrowing.narrow_class` / `narrow_not_class`. A Bot truthy fragment means no inhabitant matches
        #   (`:no`); a Bot falsey fragment means every inhabitant matches (`:yes`).
        # - **Value-equality literal** (numeric / String / Symbol / true / false / nil) against a
        #   `Constant[c]` subject: the static comparison `pattern_value === c` is exact. Other subject
        #   carriers stay `:maybe` because the runtime value isn't pinned.
        #
        # Other pattern shapes (Range, Regexp, custom `===`) stay `:maybe` — the existing union fallback
        # handles them.
        #
        # The class reference is resolved through {Narrowing.lexical_class_name}, the walk the narrowing
        # side of the same `case` already uses (#655). Matching on the as-written spelling instead made a
        # SHADOWED name confidently wrong rather than merely unresolved: `when Random` inside
        # `Bar::Nested` names `Bar::Nested::Random`, the environment answered the core `::Random` the
        # spelling matches at top level, and a subject that is a core `Random` then made the arm certain
        # — dropping the `else` Ruby actually takes and typing the expression as a branch that never
        # runs. The documented argument that an unresolvable pattern can only lose certainty holds for an
        # unresolvable name and not for a shadowed one.
        def case_when_pattern_certainty(subject_type, pattern_node, scope, typer)
          class_name = Narrowing.lexical_class_name(pattern_node, scope)
          if class_name
            return Narrowing.class_pattern_certainty(subject_type, class_name, environment: scope.environment,
                                                                               scope: scope)
          end

          literal = literal_pattern_value(pattern_node, typer)
          return Narrowing.value_pattern_certainty(subject_type, literal[:value]) if literal

          :maybe
        end

        # Returns `{ value: v }` when `pattern_node` types to a `Constant[v]` of a value-equality-safe class
        # (so `===` reduces to `==`), else nil. Wrapped in a hash so a literal `nil` / `false` value doesn't
        # collide with the "no literal" signal.
        def literal_pattern_value(pattern_node, typer)
          type = typer.type_of(pattern_node)
          return nil unless type.is_a?(Type::Constant)
          return nil unless Narrowing::VALUE_EQUALITY_CLASSES.any? { |klass| type.value.is_a?(klass) }

          { value: type.value }
        end

        # `begin; body; rescue R => e; r1; rescue; r2; else; e; ensure; f; end`. The result is the union of
        # every value-producing branch: the body (or the else-clause when present, since it replaces the body's
        # value when no exception fires), plus each rescue body in the rescue chain. The ensure clause runs but
        # does not contribute to the begin's value.
        def type_of_begin(node, scope, typer)
          rescue_clause = node.rescue_clause
          else_clause = node.else_clause

          primary_type =
            if else_clause
              typer.type_of(else_clause)
            elsif node.statements
              typer.statements_or_nil(node.statements)
            else
              Type::Combinator.constant_of(nil)
            end

          rescue_types = rescue_chain_types(rescue_clause, node.statements, scope, typer)
          Type::Combinator.union(primary_type, *rescue_types)
        end

        # Issue #1360 — the evaluator binds `$!` in a rescue clause it enters; a clause typed here, such as one in a
        # `begin` passed as an argument, reads `$!`, `$@` and `$?` unbound rather than an enclosing clause's.
        #
        # Issue #1839 — it also reads each name the `body` writes as `Dynamic[top]` ({ClauseWidening}), as the
        # evaluator's rescue clause does: `[begin; conn = make; work; rescue; conn; end]` holds the connection, not the
        # entry's `nil`.
        def rescue_chain_types(rescue_node, body, scope, typer)
          arm_scope = rescue_arm_scope(scope)
          writes = ClauseWidening.writes([body])
          types = []
          current = rescue_node
          while current
            arm_typer = typer.typer_under(ClauseWidening.widen(arm_scope, writes, current.statements) || arm_scope)
            types << arm_typer.send(:statements_or_nil, current.statements)
            current = current.subsequent
          end
          types
        end

        def type_of_rescue(node, scope, typer)
          typer.typer_under(rescue_arm_scope(scope)).send(:statements_or_nil, node.statements)
        end

        def rescue_arm_scope(scope) = scope.forget_error_info.forget_last_status

        # `expr rescue fallback` is RescueModifierNode in Prism. The result is `expr`'s type when no exception
        # is raised and `fallback`'s type otherwise; both paths are reachable, so the result is their union. Issue #1360
        # — `fallback` runs with `$!` and `$@` bound to the `StandardError` it rescued ({ErrorInfo.modifier_entry}).
        def type_of_rescue_modifier(node, scope, typer)
          fallback = node.rescue_expression
          fallback_type =
            if ErrorInfo.read_in?(fallback)
              typer.typer_under(ErrorInfo.modifier_entry(scope, fallback)).type_of(fallback)
            else
              typer.type_of(fallback)
            end
          Type::Combinator.union(typer.type_of(node.expression), fallback_type)
        end

        private_class_method :case_arm_type, :type_of_case_simple_union, :type_of_case_else,
                             :case_when_branch_certainty, :case_when_pattern_certainty, :literal_pattern_value,
                             :rescue_chain_types, :rescue_arm_scope
      end
    end
  end
end
