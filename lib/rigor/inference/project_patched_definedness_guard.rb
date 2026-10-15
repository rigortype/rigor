# frozen_string_literal: true

require "prism"

require_relative "../source/node_children"

module Rigor
  module Inference
    module ProjectPatchedScanner
      # Finds the `def`s of a `pre_eval:` file written under a definedness guard naming the same method
      # (`def foo = 1 unless method_defined?(:foo)`): polyfills that run only when nothing bound the name before.
      module DefinednessGuard
        DEFINEDNESS_PREDICATES = %i[
          method_defined? private_method_defined? public_method_defined? protected_method_defined? respond_to?
        ].freeze
        INSTANCE_METHOD_LISTS = %i[
          instance_methods public_instance_methods private_instance_methods protected_instance_methods
        ].freeze
        private_constant :DEFINEDNESS_PREDICATES, :INSTANCE_METHOD_LISTS

        module_function

        # The `def` nodes (by identity) that sit on the "name not yet defined" side of a definedness guard naming the
        # same method: `def foo = 1 unless method_defined?(:foo)`, or the same inside an `unless` / `if !` block.
        def defs(root)
          found = {}.compare_by_identity
          collect_guarded(root, found)
          found
        end

        def collect_guarded(node, found)
          return unless node.is_a?(Prism::Node)

          if node.is_a?(Prism::IfNode) || node.is_a?(Prism::UnlessNode)
            name, negated = definedness_guard(node.predicate)
            mark_guarded_defs(undefined_branch(node, negated), name, found) if name
          end
          node.rigor_each_child { |child| collect_guarded(child, found) }
        end
        private_class_method :collect_guarded

        # `[method_name, negated]` for a predicate like `method_defined?(:m)` / `!respond_to?(:m)`, else nil.
        def definedness_guard(predicate)
          predicate = predicate.body if predicate.is_a?(Prism::ParenthesesNode) && predicate.body
          predicate = predicate.body.first if predicate.is_a?(Prism::StatementsNode) && predicate.body.size == 1
          if predicate.is_a?(Prism::CallNode) && predicate.name == :! && predicate.receiver
            name, negated = definedness_guard(predicate.receiver)
            return name && [name, !negated]
          end
          name = guard_method_name(predicate)
          name && [name, false]
        end
        private_class_method :definedness_guard

        def guard_method_name(call)
          return unless call.is_a?(Prism::CallNode)

          listed = %i[include? member?].include?(call.name)
          listed &&= call.receiver.is_a?(Prism::CallNode) && INSTANCE_METHOD_LISTS.include?(call.receiver.name)
          return unless listed || DEFINEDNESS_PREDICATES.include?(call.name)

          arg = call.arguments&.arguments&.first
          arg.unescaped.to_sym if arg.is_a?(Prism::SymbolNode) || arg.is_a?(Prism::StringNode)
        end
        private_class_method :guard_method_name

        # The branch that runs when the guarded name is NOT defined yet.
        def undefined_branch(node, negated)
          branch_when_true = node.is_a?(Prism::IfNode) ? node.statements : node.else_clause
          branch_when_false = node.is_a?(Prism::IfNode) ? node.subsequent : node.statements
          # The predicate is true when the name is defined (unless negated).
          negated ? branch_when_true : branch_when_false
        end
        private_class_method :undefined_branch

        def mark_guarded_defs(node, name, found)
          return unless node.is_a?(Prism::Node)

          found[node] = true if node.is_a?(Prism::DefNode) && node.name == name
          node.rigor_each_child { |child| mark_guarded_defs(child, name, found) } unless node.is_a?(Prism::DefNode)
        end
        private_class_method :mark_guarded_defs
      end
    end
  end
end
