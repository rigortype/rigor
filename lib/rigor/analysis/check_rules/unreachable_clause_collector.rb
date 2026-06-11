# frozen_string_literal: true

require "prism"

module Rigor
  module Analysis
    module CheckRules
      # ADR-47 — collects `case`/`when` clauses proven unreachable. The flow
      # engine already narrows the case subject across `when` branches
      # (`Narrowing.case_when_scopes`), and the per-clause `body_scope` it
      # produces is recorded in `scope_index` keyed on the `WhenNode` (the
      # evaluator enters the clause under that scope). So a clause whose
      # narrowed subject local is `Type::Bot` is one the engine's own
      # narrowing proves no reaching value can match — a stale `when`,
      # mis-ordered clauses, or a type that moved out from under a branch.
      #
      # WD1 (per-clause disjointness) — the narrow, high-value core. Fires
      # ONLY on the safe shape:
      #
      # - the subject is a `case <local>` (a `LocalVariableReadNode`, the
      #   only shape `case_when_scopes` narrows — no narrowing ⇒ no firing),
      # - every `when` condition is a class/module constant (`when String` /
      #   `when MyClass`), the shape the narrowing recognises — `when nil` /
      #   ranges / regexps / arbitrary expressions are out of scope here,
      # - the subject's type at case entry is a concrete carrier, never
      #   `Type::Dynamic` (disjointness is never provable under gradual
      #   `Dynamic`, preserving the gradual guarantee) and never already
      #   `Type::Bot` (dead code, not a clause error),
      # - and the clause's narrowed `body_scope` subject is `Type::Bot`.
      #
      # The false-positive envelope mirrors `flow.always-truthy-condition`:
      # clauses inside loops / blocks are skipped (mutation tracking through
      # those is incomplete), and the rule reads the engine's own narrowing
      # rather than recomputing it, so the diagnostic and the body typing
      # can never diverge.
      class UnreachableClauseCollector
        LOOP_OR_BLOCK_NODE_CLASSES = [
          Prism::WhileNode, Prism::UntilNode, Prism::ForNode, Prism::BlockNode
        ].freeze

        # A trailing `else` whose body only re-raises / aborts is a
        # deliberate defensive guard ("this should be unreachable — shout
        # if it ever isn't"), NOT dead code the author wants removed.
        # Flagging it would push the author to delete a safety net, which
        # the false-positive discipline forbids. WD1's `when` shapes don't
        # carry this idiom (a stale `when` is a real redundancy), so the
        # skip is `else`-only.
        DEFENSIVE_EXIT_CALLS = %i[raise fail throw abort exit].freeze

        # @!attribute kind
        #   @return [Symbol] `:disjoint` (this clause's type is disjoint
        #     from the still-possible subject), `:prior_exhaustion` (an
        #     earlier clause already covered the subject), or
        #     `:exhausted_else` (every subject value is covered, so the
        #     `else` never runs).
        Result = Data.define(:clause, :body, :subject_name, :condition_source, :kind, :keyword)

        # ADR-53 Track B — the node classes the shared {RuleWalk}
        # dispatches to this collector (outside loop / block bodies).
        NODE_CLASSES = [Prism::CaseNode, Prism::CaseMatchNode].freeze

        def initialize(scope_index)
          @scope_index = scope_index
          @results = []
        end

        # Legacy single-collector walk — kept as the oracle the
        # ADR-53 Track B equivalence harness compares {RuleWalk}
        # against; deleted when Track B completes.
        # @return [Array<Result>] one entry per provably-dead `when` clause.
        def collect(root)
          walk(root, in_loop_or_block: false)
          @results.freeze
        end

        # {RuleWalk} entry point: the per-node logic of the legacy walk,
        # invoked under the same traversal contract.
        def visit(node)
          collect_case(node)
        end

        def results
          @results.freeze
        end

        private

        def walk(node, in_loop_or_block:)
          return unless node.is_a?(Prism::Node)

          visit(node) if case_like?(node) && !in_loop_or_block

          child_in_loop_or_block = in_loop_or_block || enters_loop_or_block?(node)
          node.compact_child_nodes.each { |child| walk(child, in_loop_or_block: child_in_loop_or_block) }
        end

        # `case/when` is a `CaseNode`; `case/in` is a `CaseMatchNode`. Both
        # carry `predicate` + `conditions` + `else_clause` and the engine
        # narrows both through `eval_case_when_branches`.
        def case_like?(node)
          node.is_a?(Prism::CaseNode) || node.is_a?(Prism::CaseMatchNode)
        end

        def enters_loop_or_block?(node)
          LOOP_OR_BLOCK_NODE_CLASSES.any? { |klass| node.is_a?(klass) }
        end

        def collect_case(node)
          subject = node.predicate
          return unless subject.is_a?(Prism::LocalVariableReadNode)

          entry_type = entry_subject_type(node, subject.name)
          # Only meaningful for a concrete subject type: a `Dynamic` subject
          # can never be proven disjoint (the gradual guarantee), and an
          # already-`Bot` subject is dead code, not a clause-ordering error.
          return if entry_type.nil? || entry_type.is_a?(Type::Bot) || entry_type.is_a?(Type::Dynamic)

          keyword = node.is_a?(Prism::CaseMatchNode) ? "in" : "when"
          node.conditions.each do |clause|
            case clause
            when Prism::WhenNode then collect_when(clause, subject.name)
            when Prism::InNode then collect_in(clause, subject.name)
            end
          end
          collect_else(node.else_clause, subject.name, keyword)
        end

        def entry_subject_type(case_node, subject_name)
          scope = @scope_index[case_node]
          scope&.local(subject_name)
        end

        def collect_when(clause, subject_name)
          return if clause.statements.nil? # empty body → no useful location
          return unless all_constant_conditions?(clause)

          scope = @scope_index[clause]
          return if scope.nil?
          return unless scope.local(subject_name).is_a?(Type::Bot)

          @results << Result.new(
            clause: clause, body: clause.statements, subject_name: subject_name,
            condition_source: clause.conditions.map(&:slice).join(", "),
            kind: when_clause_kind(clause, subject_name), keyword: "when"
          )
        end

        # A dead `when` is `:prior_exhaustion` when the subject was
        # already narrowed to `bot` BEFORE this clause (an earlier clause
        # covered it) — read from the entry scope the engine recorded on
        # the clause's first condition node (ADR-47 WD2). Otherwise the
        # subject was still concrete entering the clause and THIS clause's
        # type is disjoint from it.
        def when_clause_kind(clause, subject_name)
          entry = @scope_index[clause.conditions.first]
          return :prior_exhaustion if entry && entry.local(subject_name).is_a?(Type::Bot)

          :disjoint
        end

        # ADR-47 WD3a — a dead `case/in` clause. The body scope reaches
        # `bot` either because a bare class pattern (`in C` / `in C => x`)
        # is disjoint from the still-possible subject (the engine narrows
        # those soundly, like `when C`), or because an earlier clause
        # already exhausted the subject (prior-exhaustion — true for ANY
        # pattern downstream of a covering set). Non-bare patterns are not
        # narrowed, so their body is `bot` ONLY under prior-exhaustion;
        # they never produce a spurious `:disjoint`.
        def collect_in(clause, subject_name)
          return if clause.statements.nil?

          scope = @scope_index[clause]
          return if scope.nil?
          return unless scope.local(subject_name).is_a?(Type::Bot)

          @results << Result.new(
            clause: clause, body: clause.statements, subject_name: subject_name,
            condition_source: clause.pattern.slice,
            kind: in_clause_kind(clause, subject_name), keyword: "in"
          )
        end

        def in_clause_kind(clause, subject_name)
          entry = @scope_index[clause.pattern]
          return :prior_exhaustion if entry && entry.local(subject_name).is_a?(Type::Bot)

          :disjoint
        end

        # The trailing `else` is dead when every subject value is covered
        # by the `when` clauses — the final falsey scope (recorded on the
        # `else` node) narrows the subject to `bot`. Defensive `else`
        # bodies (a bare `raise` / `fail` / `throw`) are deliberate
        # guards, not removable dead code, so they are skipped.
        def collect_else(else_clause, subject_name, keyword)
          return if else_clause.nil? || else_clause.statements.nil?
          return if defensive_else?(else_clause)

          scope = @scope_index[else_clause]
          return if scope.nil?
          return unless scope.local(subject_name).is_a?(Type::Bot)

          @results << Result.new(
            clause: else_clause, body: else_clause.statements, subject_name: subject_name,
            condition_source: nil, kind: :exhausted_else, keyword: keyword
          )
        end

        def defensive_else?(else_clause)
          body = else_clause.statements.body
          return false unless body.size == 1

          stmt = body.first
          stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? &&
            DEFENSIVE_EXIT_CALLS.include?(stmt.name)
        end

        def all_constant_conditions?(clause)
          conditions = clause.conditions
          !conditions.empty? &&
            conditions.all? { |c| c.is_a?(Prism::ConstantReadNode) || c.is_a?(Prism::ConstantPathNode) }
        end
      end
    end
  end
end
