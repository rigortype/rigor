# frozen_string_literal: true

require "prism"

require_relative "../../type"

module Rigor
  module Analysis
    module DependencySourceInference
      # Walker enhancement (ADR-10 § "Open questions"): pulls a
      # **heuristic** return type out of a method body's tail
      # expression. The heuristic is intentionally narrow — only
      # the trivially-decidable shapes contribute. Everything
      # else returns `nil`, which the dispatcher consumes as
      # "fall back to `Dynamic[top]`" (the pre-enhancement
      # behaviour).
      #
      # The contract is a strict floor:
      #
      # - Last statement is a literal scalar (Integer / Float /
      #   Symbol / true / false / nil) → `Constant<value>`.
      # - Last statement is a String literal → `Nominal[String]`
      #   (NOT `Constant<"x">`; a String literal is mutable under
      #   `# frozen_string_literal: false`, so the analyzer cannot
      #   claim object identity).
      # - Last statement is an Array / Hash literal →
      #   `Nominal[Array]` / `Nominal[Hash]` (element-type
      #   inference stays deferred — too expensive for the
      #   heuristic tier).
      # - Last statement is `self` → `nil` (the caller's receiver
      #   nominal would be more accurate but the walker doesn't
      #   carry the receiver context; deferred).
      # - Anything else → `nil`.
      #
      # The dispatcher wraps the returned type in `Dynamic[T]`
      # before returning to the user per ADR-10's `Dynamic`-origin
      # contract. The wrapping is the dispatcher's responsibility,
      # not the heuristic's.
      module ReturnTypeHeuristic
        module_function

        # @param def_node [Prism::DefNode]
        # @return [Rigor::Type, nil] heuristic return type, or
        #   `nil` when the body's tail expression doesn't match
        #   any of the recognised shapes.
        def extract(def_node)
          body = def_node.body
          return nil if body.nil?

          tail = tail_expression(body)
          literal_return_type(tail)
        end

        # Extracts the last evaluated expression of the method
        # body. A `Prism::DefNode`'s body is either a
        # `StatementsNode` (multi-statement body) or a single
        # expression node directly. We dig past `BeginNode` /
        # rescue wrappers to the protected body's tail.
        def tail_expression(node)
          case node
          when Prism::StatementsNode
            tail_expression(node.body.last) unless node.body.empty?
          when Prism::BeginNode
            tail_expression(node.statements) if node.statements
          when nil
            nil
          else
            node
          end
        end
        private_class_method :tail_expression

        # The per-shape heuristic. Per the module docstring,
        # immutable scalar literals fold to `Constant<value>`;
        # mutable container literals (String, Array, Hash) fold
        # to the appropriate Nominal; everything else returns
        # nil.
        def literal_return_type(node)
          case node
          when Prism::IntegerNode, Prism::FloatNode then Type::Combinator.constant_of(node.value)
          when Prism::SymbolNode then symbol_constant(node)
          when Prism::TrueNode then Type::Combinator.constant_of(true)
          when Prism::FalseNode then Type::Combinator.constant_of(false)
          when Prism::NilNode then Type::Combinator.constant_of(nil)
          when Prism::StringNode then Type::Combinator.nominal_of("String")
          when Prism::ArrayNode then Type::Combinator.nominal_of("Array")
          when Prism::HashNode then Type::Combinator.nominal_of("Hash")
          end
        end
        private_class_method :literal_return_type

        # `Prism::SymbolNode#value` returns the Symbol's name as
        # a String. We `.to_sym` it for the Constant carrier so
        # `:foo` is `Constant<:foo>`, not `Constant<"foo">`.
        def symbol_constant(node)
          value = node.value
          return nil if value.nil?

          Type::Combinator.constant_of(value.to_sym)
        end
        private_class_method :symbol_constant
      end
    end
  end
end
