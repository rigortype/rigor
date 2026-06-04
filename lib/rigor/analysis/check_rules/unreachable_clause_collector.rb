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

        Result = Data.define(:clause, :subject_name, :condition_source)

        def initialize(scope_index)
          @scope_index = scope_index
          @results = []
        end

        # @return [Array<Result>] one entry per provably-dead `when` clause.
        def collect(root)
          walk(root, in_loop_or_block: false)
          @results.freeze
        end

        private

        def walk(node, in_loop_or_block:)
          return unless node.is_a?(Prism::Node)

          collect_case(node) if node.is_a?(Prism::CaseNode) && !in_loop_or_block

          child_in_loop_or_block = in_loop_or_block || enters_loop_or_block?(node)
          node.compact_child_nodes.each { |child| walk(child, in_loop_or_block: child_in_loop_or_block) }
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

          node.conditions.each do |clause|
            collect_when(clause, subject.name) if clause.is_a?(Prism::WhenNode)
          end
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
            clause: clause, subject_name: subject_name,
            condition_source: clause.conditions.map(&:slice).join(", ")
          )
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
