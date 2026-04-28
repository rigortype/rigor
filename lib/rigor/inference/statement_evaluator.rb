# frozen_string_literal: true

require "prism"

require_relative "../type"

module Rigor
  module Inference
    # Statement-level evaluator that complements `Rigor::Inference::ExpressionTyper`
    # by threading an immutable {Rigor::Scope} through control-flow constructs.
    # The output is the pair `[Rigor::Type, Rigor::Scope]`: the type that the
    # evaluated node produces, and the scope that callers should observe
    # AFTER the node has run.
    #
    # Slice 3 phase 2 ships the evaluator surface and the scope-threading
    # rules for the canonical statement-y nodes:
    #
    # - sequential evaluation across `Prism::StatementsNode`/`ProgramNode`,
    # - local-variable assignment (`Prism::LocalVariableWriteNode`) binding
    #   the rvalue's type into the post-scope,
    # - branching constructs (`IfNode`, `UnlessNode`, `CaseNode`,
    #   `CaseMatchNode`, `BeginNode`/`RescueNode`/`EnsureNode`,
    #   `WhileNode`/`UntilNode`, `AndNode`/`OrNode`) that evaluate each
    #   branch under a forked scope and merge the results with
    #   nil-injection on half-bound names,
    # - pass-through helpers for `ParenthesesNode`, `ElseNode`,
    #   `WhenNode`/`InNode`, and `RescueNode`.
    #
    # Anything outside the catalogue defers to `Rigor::Scope#type_of` and
    # returns the receiver scope unchanged. This matches the Slice 1
    # fail-soft policy: an unrecognised statement-level node MUST NOT
    # raise and MUST keep the scope intact.
    #
    # The class is stateful (`@scope`, `@tracer`) but every public call
    # returns fresh values; the receiver scope MUST never be mutated.
    # Recursive evaluation always allocates a new instance with the
    # forked scope so different branches stay isolated.
    #
    # See docs/internal-spec/inference-engine.md for the public contract
    # and docs/adr/4-type-inference-engine.md for the slice rationale.
    # rubocop:disable Metrics/ClassLength
    class StatementEvaluator
      # Hash-based dispatch keeps `evaluate` linear and lets future slices
      # add control-flow node kinds without growing a single case
      # statement past RuboCop's cyclomatic budget. Anonymous Prism
      # subclasses are not expected.
      HANDLERS = {
        Prism::StatementsNode => :eval_statements,
        Prism::ProgramNode => :eval_program,
        Prism::LocalVariableWriteNode => :eval_local_write,
        Prism::IfNode => :eval_if,
        Prism::UnlessNode => :eval_unless,
        Prism::ElseNode => :eval_else,
        Prism::CaseNode => :eval_case,
        Prism::CaseMatchNode => :eval_case,
        Prism::WhenNode => :eval_when_or_in,
        Prism::InNode => :eval_when_or_in,
        Prism::BeginNode => :eval_begin,
        Prism::RescueNode => :eval_rescue,
        Prism::EnsureNode => :eval_ensure,
        Prism::WhileNode => :eval_loop,
        Prism::UntilNode => :eval_loop,
        Prism::AndNode => :eval_and_or,
        Prism::OrNode => :eval_and_or,
        Prism::ParenthesesNode => :eval_parentheses
      }.freeze
      private_constant :HANDLERS

      # @param scope [Rigor::Scope]
      # @param tracer [Rigor::Inference::FallbackTracer, nil]
      # @param on_enter [#call, nil] optional `(node, scope) ->` callable
      #   invoked once at the start of every {#evaluate} call (the node
      #   itself, *before* its handler runs). Threaded through every
      #   recursive `sub_eval` so the tooling that builds a per-node
      #   scope index (`Rigor::Inference::ScopeIndexer`) can record the
      #   entry scope for every Prism node the evaluator visits without
      #   the StatementEvaluator carrying any additional state itself.
      def initialize(scope:, tracer: nil, on_enter: nil)
        @scope = scope
        @tracer = tracer
        @on_enter = on_enter
      end

      # Evaluate `node` under the receiver scope. Returns `[type, scope']`
      # where `type` is the value the node produces and `scope'` is the
      # scope observable after the node has run. The receiver scope is
      # never mutated.
      #
      # @param node [Prism::Node]
      # @return [Array(Rigor::Type, Rigor::Scope)]
      def evaluate(node)
        @on_enter&.call(node, @scope)

        handler = HANDLERS[node.class]
        return send(handler, node) if handler

        # Default: the node is treated as a pure expression. Type it
        # through the existing expression typer (which observes the
        # current scope's locals) and leave the scope unchanged.
        [@scope.type_of(node, tracer: @tracer), @scope]
      end

      private

      attr_reader :scope, :tracer

      # Thread the scope through every child statement in declaration
      # order. The body's value is the type of the last statement (or
      # `Constant[nil]` for an empty body); intermediate statements'
      # types are discarded, but their scope effects are preserved.
      def eval_statements(node)
        result_type = Type::Combinator.constant_of(nil)
        current = scope
        node.body.each do |stmt|
          result_type, current = sub_eval(stmt, current)
        end
        [result_type, current]
      end

      def eval_program(node)
        return [Type::Combinator.constant_of(nil), scope] if node.statements.nil?

        sub_eval(node.statements, scope)
      end

      # `name = rvalue` evaluates the rvalue under the entry scope (so
      # earlier assignments in a chained `a = b = expr` propagate
      # left-to-right) and binds `name` to the result type. Compound
      # assignment forms (`+=` etc.) are deferred to a follow-up; for
      # now they degrade to "type the rhs, do not rebind" via the
      # default branch in {#evaluate}.
      def eval_local_write(node)
        rhs_type, post_rhs = sub_eval(node.value, scope)
        [rhs_type, post_rhs.with_local(node.name, rhs_type)]
      end

      # `if pred; t; (elsif/else)?` runs the predicate first (its
      # post-scope is shared by both branches), then evaluates each
      # branch under the post-predicate scope. The branches' result
      # types are unioned and their post-scopes are joined with
      # nil-injection on half-bound names so a name set in one branch
      # but not the other is observable as `T | nil` after the if.
      def eval_if(node)
        _pred_type, post_pred = sub_eval(node.predicate, scope)
        then_type, then_scope = eval_branch_or_nil(node.statements, post_pred)
        else_type, else_scope = eval_branch_or_nil(node.subsequent, post_pred)
        [
          Type::Combinator.union(then_type, else_type),
          join_with_nil_injection(then_scope, else_scope)
        ]
      end

      # `unless pred; t; else; e; end`. Same shape as `if`, but Prism
      # exposes the else-branch as `else_clause` (no elsif chain).
      def eval_unless(node)
        _pred_type, post_pred = sub_eval(node.predicate, scope)
        then_type, then_scope = eval_branch_or_nil(node.statements, post_pred)
        else_type, else_scope = eval_branch_or_nil(node.else_clause, post_pred)
        [
          Type::Combinator.union(then_type, else_type),
          join_with_nil_injection(then_scope, else_scope)
        ]
      end

      def eval_else(node)
        return [Type::Combinator.constant_of(nil), scope] if node.statements.nil?

        sub_eval(node.statements, scope)
      end

      # `case pred; when ...; when ...; else; end` and the pattern-
      # matching variant. The predicate's post-scope is shared with
      # every branch (including the else); branches are evaluated
      # independently and merged with nil-injection so half-bound
      # names degrade to `T | nil`.
      def eval_case(node)
        post_pred = node.predicate ? sub_eval(node.predicate, scope).last : scope

        branch_results = node.conditions.map { |branch| sub_eval(branch, post_pred) }
        else_result =
          if node.else_clause
            sub_eval(node.else_clause, post_pred)
          else
            [Type::Combinator.constant_of(nil), post_pred]
          end

        all_results = [*branch_results, else_result]
        types = all_results.map(&:first)
        scopes = all_results.map(&:last)
        [
          Type::Combinator.union(*types),
          reduce_scopes_with_nil_injection(scopes)
        ]
      end

      def eval_when_or_in(node)
        return [Type::Combinator.constant_of(nil), scope] if node.statements.nil?

        sub_eval(node.statements, scope)
      end

      # `begin; body; rescue ...; else; ensure; end`. The body and the
      # rescue chain are alternative exit paths whose scopes are joined
      # with nil-injection. The else-clause replaces the body's value
      # when present (matching Ruby semantics: else runs only if the
      # body raises no exception). The ensure-clause runs but does not
      # contribute to the value; its scope effects are layered on the
      # joined exit scope so locals bound exclusively in `ensure` stay
      # observable.
      def eval_begin(node)
        primary_type, primary_scope = eval_begin_primary(node)
        rescue_chain = collect_rescue_chain_results(node.rescue_clause, scope)

        if rescue_chain.empty?
          exit_type = primary_type
          exit_scope = primary_scope
        else
          exit_type = Type::Combinator.union(primary_type, *rescue_chain.map(&:first))
          exit_scope = reduce_scopes_with_nil_injection([primary_scope, *rescue_chain.map(&:last)])
        end

        if node.ensure_clause
          _ensure_type, ensure_scope = sub_eval(node.ensure_clause, exit_scope)
          exit_scope = ensure_scope
        end

        [exit_type, exit_scope]
      end

      # `BeginNode#statements` is the primary body; when an else-clause
      # is present, its value replaces the body's per Ruby semantics
      # (the else runs only when no exception was raised), but the
      # body's scope effects still apply because the body did run
      # before the else.
      def eval_begin_primary(node)
        body_type, body_scope =
          if node.statements
            sub_eval(node.statements, scope)
          else
            [Type::Combinator.constant_of(nil), scope]
          end

        if node.else_clause
          else_type, else_scope = sub_eval(node.else_clause, body_scope)
          [else_type, else_scope]
        else
          [body_type, body_scope]
        end
      end

      def collect_rescue_chain_results(rescue_node, entry_scope)
        results = []
        current = rescue_node
        while current
          results << eval_branch_or_nil(current.statements, entry_scope)
          current = current.subsequent
        end
        results
      end

      def eval_rescue(node)
        eval_branch_or_nil(node.statements, scope)
      end

      def eval_ensure(node)
        eval_branch_or_nil(node.statements, scope)
      end

      # `while pred; body; end` / `until pred; body; end`. The body
      # might run zero or more times, so half-bound names degrade to
      # `T | nil` in the post-loop scope. The loop expression itself
      # types as `Constant[nil]` (Slice 3 phase 1), reflecting the
      # common case where no `break VALUE` is observed.
      def eval_loop(node)
        _pred_type, post_pred = sub_eval(node.predicate, scope)
        return [Type::Combinator.constant_of(nil), post_pred] if node.statements.nil?

        _body_type, body_scope = sub_eval(node.statements, post_pred)
        [
          Type::Combinator.constant_of(nil),
          join_with_nil_injection(post_pred, body_scope)
        ]
      end

      # `a && b` / `a || b`. The LHS always runs, the RHS only
      # sometimes runs. Slice 3 phase 2 does not narrow the LHS's
      # truthiness (Slice 6 will), so both exits are reachable: the
      # post-LHS scope (RHS skipped) joins with the post-RHS scope
      # (RHS ran), with nil-injection. The result type is the union
      # of the two operand types.
      def eval_and_or(node)
        left_type, left_scope = sub_eval(node.left, scope)
        right_type, right_scope = sub_eval(node.right, left_scope)
        [
          Type::Combinator.union(left_type, right_type),
          join_with_nil_injection(left_scope, right_scope)
        ]
      end

      # `(body)`. Threads scope through the inner expression so
      # `(x = 1; x + 2)` binds `x` and produces `Constant[3]`.
      def eval_parentheses(node)
        return [Type::Combinator.constant_of(nil), scope] if node.body.nil?

        sub_eval(node.body, scope)
      end

      # ----- helpers -----

      def sub_eval(node, with_scope)
        StatementEvaluator.new(scope: with_scope, tracer: tracer, on_enter: @on_enter).evaluate(node)
      end

      def eval_branch_or_nil(branch_node, branch_scope)
        return [Type::Combinator.constant_of(nil), branch_scope] if branch_node.nil?

        sub_eval(branch_node, branch_scope)
      end

      # Joins two branch scopes at a control-flow merge point. Names
      # bound in only one branch are nil-injected into the other side
      # so the joined scope sees them as `T | nil` rather than dropping
      # them outright. This implements the contract the Slice 3 phase 1
      # `Scope#join` documentation defers to the statement-level
      # evaluator.
      def join_with_nil_injection(scope_a, scope_b)
        nil_const = Type::Combinator.constant_of(nil)
        a_keys = scope_a.locals.keys
        b_keys = scope_b.locals.keys
        a_only = a_keys - b_keys
        b_only = b_keys - a_keys

        aug_a = b_only.reduce(scope_a) { |acc, name| acc.with_local(name, nil_const) }
        aug_b = a_only.reduce(scope_b) { |acc, name| acc.with_local(name, nil_const) }
        aug_a.join(aug_b)
      end

      # Generalises {#join_with_nil_injection} to N branches (case/when,
      # begin/rescue chain). The reduce order does not affect the
      # result because nil-injection commutes with union under
      # `Scope#join`.
      def reduce_scopes_with_nil_injection(scopes)
        scopes.reduce { |a, b| join_with_nil_injection(a, b) }
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
