# frozen_string_literal: true

require "prism"

require_relative "../../reflection"
require_relative "../../source/node_children"
require_relative "../../type"

module Rigor
  module Analysis
    module CheckRules
      # Issue #3036 — answers, for a call node `flow.always-raises` proved raises, whether an enclosing
      # `begin` (or `def … rescue … end`, which Prism wraps in the same `BeginNode`) catches the raise
      # before it escapes. When a rescue clause may catch the raised class the exception flows to the
      # handler, so the rule stays silent.
      #
      # The check is deliberately conservative in BOTH directions:
      #
      # - it suppresses only when a clause NAMES a class the raised class orders at-or-below
      #   (`rescue ZeroDivisionError`, `rescue StandardError`, `rescue Exception`, or a bare `rescue`,
      #   which is `StandardError`), resolved through the typer so lexical constant lookup applies. An
      #   exception reference that is not a constant (`rescue *ERRORS`, `rescue klass`) contributes no
      #   coverage, and an unresolvable / `:unknown` ordering keeps the diagnostic — a wrong silence is
      #   worse than a kept finding.
      # - it never crosses a body boundary ({BODY_BOUNDARIES}): a `def`, `->`, or block body runs when
      #   called, not while the `begin` body evaluates, and `BEGIN` / `END` blocks run on their own
      #   schedule, so an outer rescue cannot be proven to see their raise. Class / module bodies are
      #   NOT boundaries — they evaluate inline, so their raises DO reach the enclosing rescue.
      #
      # Prism nodes carry no parent pointers, so ancestry is answered from a `node => parent` table
      # built lazily on the first query: a file with no zero-division candidate never pays for it.
      class AlwaysRaisesShield
        # The exception class the rule proves today — Integer `/# % div modulo divmod` by a literal
        # zero divisor. A rescue catches it when the clause names the class itself or an ancestor.
        RAISED_CLASS = "ZeroDivisionError"

        # The implicit class of a bare `rescue` / `rescue => e`.
        BARE_RESCUE_CLASS = "StandardError"

        # Node classes whose bodies do not execute inside the enclosing `begin` — see the class
        # comment. Mirrors the deferred-body set `Inference::ScopeIndexer` already tracks.
        BODY_BOUNDARIES = [
          Prism::DefNode, Prism::LambdaNode, Prism::BlockNode,
          Prism::PreExecutionNode, Prism::PostExecutionNode
        ].freeze

        def initialize(root)
          @root = root
          @parent_map = nil
        end

        # True when `node` sits in the protected body of a `begin` whose rescue chain may catch
        # {RAISED_CLASS}. `scope` is the scope recorded for `node`; it resolves the clause's exception
        # constants lexically. A nil scope or a node outside `root`'s subtree answers false.
        def rescued?(node, scope)
          return false if scope.nil?

          parents = parent_map
          child = node
          current = parents[node]
          while current
            return true if protected_body?(current, child, scope)
            return false if BODY_BOUNDARIES.any? { |klass| current.is_a?(klass) }

            child = current
            current = parents[current]
          end
          false
        end

        private

        # True when `node` is a `begin` whose protected body (`statements`) contains `child` — the
        # ascent arrived through the body rather than through a rescue / else / ensure clause, whose
        # raises this `begin` does not catch — and whose rescue chain may catch {RAISED_CLASS}. When
        # the chain does NOT catch, the ascent continues: an outer `begin` may still.
        def protected_body?(node, child, scope)
          return false unless node.is_a?(Prism::BeginNode)
          return false unless child.equal?(node.statements)
          return false if node.rescue_clause.nil?

          rescue_chain_catches?(node.rescue_clause, scope)
        end

        # Any clause of the `rescue … rescue …` chain may catch — clauses are tried in order and the
        # first match wins, so one catching clause is enough.
        def rescue_chain_catches?(clause, scope)
          while clause
            return true if rescue_clause_catches?(clause, scope)

            clause = clause.subsequent
          end
          false
        end

        # One `rescue` clause catches {RAISED_CLASS} when any class it names orders at-or-above the
        # raised class. A bare `rescue` names {BARE_RESCUE_CLASS}.
        def rescue_clause_catches?(clause, scope)
          exceptions = clause.exceptions
          return class_catches?(BARE_RESCUE_CLASS, scope) if exceptions.empty?

          exceptions.any? do |exception|
            class_name = exception_class_name(exception, scope)
            class_name && class_catches?(class_name, scope)
          end
        end

        # The class a rescue exception reference names, or nil when it is not a constant path (a splat,
        # a dynamic expression) or does not resolve to a class object. Only `Type::Singleton` counts:
        # the rescue operand is the class itself, and an instance-typed constant cannot be proven to
        # match.
        def exception_class_name(node, scope)
          return nil unless node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)

          type = scope.type_of(node)
          type.class_name if type.is_a?(Type::Singleton)
        end

        # `class_ordering(raised, rescued)`: `:equal` / `:subclass` mean the rescued class IS the raised
        # class or an ancestor of it — the clause catches. `:superclass`, `:disjoint`, and `:unknown`
        # all keep the diagnostic.
        def class_catches?(rescued_class, scope)
          %i[equal subclass].include?(
            Rigor::Reflection.class_ordering(RAISED_CLASS, rescued_class, scope: scope)
          )
        end

        # `node => parent` for every descendant of `root`, built on first use. Iterative so a deeply
        # nested file cannot overflow the stack the way a recursive walk could.
        def parent_map
          @parent_map ||= begin
            parents = {}
            stack = [@root]
            until stack.empty?
              node = stack.pop
              node.rigor_each_child do |child|
                parents[child] = node
                stack << child
              end
            end
            parents
          end
        end
      end
    end
  end
end
