# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class LispEval < Rigor::Plugin::Base
      # Static interpreter that walks a literal Lisp-style
      # expression encoded as a Prism AST and returns a tag
      # naming the type the runtime evaluation would produce.
      #
      # Tags are kept as plain Symbols (`:integer`, `:float`,
      # `:bool`) and translated to Rigor type carriers at the
      # plugin boundary; that keeps the grammar table easy to
      # read and the type API surface contained to one site.
      #
      # The accepted grammar is intentionally small:
      #
      #   expr     ::= literal | form
      #   literal  ::= IntegerLiteral | FloatLiteral | true | false
      #   form     ::= [op, arg, *]
      #   op       ::= :+ | :- | :* | :/  (numeric arithmetic)
      #              | :< | :> | :<= | :>= | :==  (comparison)
      #              | :and | :or | :not  (boolean)
      #              | :if   (conditional)
      #
      # Every expression that does not fit the grammar — a
      # non-literal element, an unknown operator, a wrong arity
      # — yields {UnknownExpression} so the caller can decide
      # whether to stay silent or to publish a diagnostic.
      class Interpreter
        # Static type tags the interpreter produces.
        INTEGER = :integer
        FLOAT = :float
        BOOL = :bool

        NUMERIC = [INTEGER, FLOAT].freeze

        # Produced when the expression is well-formed but its
        # operands violate the operator's domain.
        TypeError = Struct.new(:message, :node, keyword_init: true) do
          def error? = true
        end

        # Produced when the expression is outside the supported
        # grammar. Distinct from {TypeError} so the plugin can
        # stay silent on user code that is just not a Lisp
        # literal.
        UnknownExpression = Struct.new(:reason, :node, keyword_init: true) do
          def error? = false
        end

        # Returns one of:
        #   - a tag Symbol (`:integer`, `:float`, `:bool`) — success
        #   - an Array of tag Symbols — successful union (`:if` branches)
        #   - {TypeError} — well-formed but ill-typed
        #   - {UnknownExpression} — outside the supported grammar
        def evaluate(node)
          case node
          when Prism::IntegerNode then INTEGER
          when Prism::FloatNode then FLOAT
          when Prism::TrueNode, Prism::FalseNode then BOOL
          when Prism::ArrayNode then evaluate_form(node)
          else
            UnknownExpression.new(
              reason: "expected an integer, float, boolean, or [:op, ...] form, got #{describe_node(node)}",
              node: node
            )
          end
        end

        private

        def evaluate_form(node)
          elements = node.elements
          return UnknownExpression.new(reason: "empty literal `[]` is not a Lisp form", node: node) if elements.empty?

          op_node = elements.first
          unless op_node.is_a?(Prism::SymbolNode)
            return UnknownExpression.new(reason: "first element is not a symbol literal", node: op_node)
          end

          operator = op_node.unescaped.to_sym
          args = elements[1..]

          case operator
          when :+, :-, :*, :/ then evaluate_arith(operator, args, node)
          when :<, :>, :<=, :>=, :== then evaluate_compare(operator, args, node)
          when :and, :or then evaluate_boolean_binop(operator, args, node)
          when :not then evaluate_not(args, node)
          when :if then evaluate_if(args, node)
          else
            UnknownExpression.new(reason: "unknown operator #{operator.inspect}", node: op_node)
          end
        end

        def evaluate_arith(operator, args, node)
          return arity_error(operator, 2, args.size, node) if args.size != 2

          left = evaluate(args[0])
          right = evaluate(args[1])
          return left if propagate?(left)
          return right if propagate?(right)

          unless numeric?(left) && numeric?(right)
            return TypeError.new(
              message: "`#{operator}` expects numeric operands, got #{describe(left)} and #{describe(right)}",
              node: node
            )
          end

          numeric_join(left, right)
        end

        def evaluate_compare(operator, args, node)
          return arity_error(operator, 2, args.size, node) if args.size != 2

          left = evaluate(args[0])
          right = evaluate(args[1])
          return left if propagate?(left)
          return right if propagate?(right)

          unless numeric?(left) && numeric?(right)
            return TypeError.new(
              message: "`#{operator}` expects numeric operands, got #{describe(left)} and #{describe(right)}",
              node: node
            )
          end

          BOOL
        end

        def evaluate_boolean_binop(operator, args, node)
          return arity_error(operator, 2, args.size, node) if args.size != 2

          left = evaluate(args[0])
          right = evaluate(args[1])
          return left if propagate?(left)
          return right if propagate?(right)

          unless boolean?(left) && boolean?(right)
            return TypeError.new(
              message: "`#{operator}` expects boolean operands, got #{describe(left)} and #{describe(right)}",
              node: node
            )
          end

          BOOL
        end

        def evaluate_not(args, node)
          return arity_error(:not, 1, args.size, node) if args.size != 1

          inner = evaluate(args[0])
          return inner if propagate?(inner)
          unless boolean?(inner)
            return TypeError.new(
              message: "`not` expects a boolean operand, got #{describe(inner)}",
              node: node
            )
          end

          BOOL
        end

        def evaluate_if(args, node)
          return arity_error(:if, 3, args.size, node) if args.size != 3

          cond = evaluate(args[0])
          return cond if propagate?(cond)
          unless boolean?(cond)
            return TypeError.new(
              message: "`if` condition must be boolean, got #{describe(cond)}",
              node: node
            )
          end

          then_branch = evaluate(args[1])
          return then_branch if propagate?(then_branch)

          else_branch = evaluate(args[2])
          return else_branch if propagate?(else_branch)

          tag_union(then_branch, else_branch)
        end

        def arity_error(operator, expected, actual, node)
          plural = expected == 1 ? "argument" : "arguments"
          TypeError.new(
            message: "`#{operator}` expects exactly #{expected} #{plural}, got #{actual}",
            node: node
          )
        end

        def propagate?(result)
          result.is_a?(TypeError) || result.is_a?(UnknownExpression)
        end

        def numeric?(tag)
          NUMERIC.include?(tag) || (tag.is_a?(Array) && tag.all? { |t| NUMERIC.include?(t) })
        end

        def boolean?(tag)
          tag == BOOL || (tag.is_a?(Array) && tag.all? { |t| t == BOOL })
        end

        def numeric_join(left, right)
          tags = Array(left) | Array(right)
          tags.include?(FLOAT) ? FLOAT : INTEGER
        end

        def tag_union(left, right)
          members = (Array(left) | Array(right)).uniq
          members.size == 1 ? members.first : members
        end

        def describe(tag)
          case tag
          when Array then tag.map { |t| describe(t) }.join(" | ")
          when Symbol then tag.to_s.capitalize.then { |s| s == "Bool" ? "bool" : s }
          else tag.inspect
          end
        end

        def describe_node(node)
          node.nil? ? "nil" : node.class.name.split("::").last
        end
      end
    end
  end
end
