# frozen_string_literal: true

require "prism"
require_relative "../diagnostic"
require_relative "rule_ids"

module Rigor
  module Analysis
    module CheckRules
      # ADR-116 WD1 — `flow.unreachable-branch`: an `if` / `unless` whose predicate is a literal of known
      # truthiness and whose dead branch is observable.
      #
      # The entry point is {.diagnostic}, called by `CheckRules.main_pass_node_diagnostics`. It reads no
      # other rule module and calls nothing in `CheckRules`. The `unreachable_clause` collector is a
      # different rule and lives in {UnreachableClauseCollector}.
      module UnreachableBranch
        module_function

        # v0.1.2 — `flow.unreachable-branch`. Fires when an `IfNode` / `UnlessNode` whose predicate is a
        # literal `true` / `false` / `nil` (or a literal numeric / string / symbol whose Ruby truthiness is
        # known at-a-glance) has an observable dead branch. The diagnostic points at the dead branch (not
        # the predicate) so the squiggle lands on the code that never runs.
        #
        # Conservative envelope — by deliberate v0.1.2 design:
        # - Only **literal-shaped** predicates fire. Inferred-constant predicates (`x.method?` that happens
        #   to fold to `Constant<bool>`) are intentionally skipped — Rigor's loop / mutation /
        #   RBS-strictness modelling is incomplete enough that an inferred constant can be a false positive
        #   (e.g. accumulator `arr << x` doesn't widen the carrier; defensive `module.name.nil?` checks
        #   against anonymous-class nil that the RBS `Module#name -> String` sig hides). The literal-only
        #   envelope captures the clear "user wrote `if false`" case without false alarms.
        # - Empty dead branches (e.g. `if false; end` with no body) are skipped — there is no useful
        #   location to point at.
        # - Postfix-`if` / `unless` modifiers with a literal predicate ARE flagged (`expr if false` body
        #   never runs, exactly like the block form).
        # - Elsif chains (`subsequent` is itself an `IfNode`) ARE flagged — the entire downstream chain is
        #   unreachable when the outer predicate is a constant literal.
        #
        # Inferred-constant predicates are the `flow.always-truthy-condition` rule's ({AlwaysTruthyConditionCollector}).
        def diagnostic(path, node, scope_index)
          scope = scope_index[node]
          return nil if scope.nil?

          polarity = literal_predicate_polarity(node.predicate)
          return nil if polarity.nil?

          dead_branch = unreachable_branch_for(node, polarity == :truthy)
          return nil if dead_branch.nil?

          build_unreachable_branch_diagnostic(path, dead_branch, polarity)
        end

        TRUTHY_LITERAL_NODES = [
          Prism::TrueNode, Prism::IntegerNode, Prism::FloatNode,
          Prism::StringNode, Prism::SymbolNode, Prism::RegularExpressionNode
        ].freeze
        private_constant :TRUTHY_LITERAL_NODES

        FALSEY_LITERAL_NODES = [Prism::FalseNode, Prism::NilNode].freeze
        private_constant :FALSEY_LITERAL_NODES

        # Returns `:truthy` / `:falsey` for a syntactically-literal predicate, or nil for anything else.
        # `TrueNode`, `FalseNode`, `NilNode` are the unambiguous cases. Numeric / string / symbol literals
        # are always truthy in Ruby (any non-`false` / non-`nil` value is truthy, including `0` and `""`).
        def literal_predicate_polarity(predicate)
          return :truthy if TRUTHY_LITERAL_NODES.any? { |klass| predicate.is_a?(klass) }
          return :falsey if FALSEY_LITERAL_NODES.any? { |klass| predicate.is_a?(klass) }

          nil
        end

        # Returns the dead-branch node for a literal-predicate if/unless, or nil when no observable branch
        # is dead.
        def unreachable_branch_for(node, truthy)
          dead =
            case node
            when Prism::IfNode then truthy ? node.subsequent : node.statements
            when Prism::UnlessNode then truthy ? node.statements : node.else_clause
            end
          dead unless dead.nil?
        end

        def build_unreachable_branch_diagnostic(path, dead_branch, polarity)
          Diagnostic.from_node(
            dead_branch,
            rule: RULE_UNREACHABLE_BRANCH,
            path: path,
            message: "unreachable branch: literal predicate is always #{polarity}",
            severity: :warning
          )
        end

        private_class_method :literal_predicate_polarity, :unreachable_branch_for,
                             :build_unreachable_branch_diagnostic
      end
    end
  end
end
