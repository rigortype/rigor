# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class LispEval < Rigor::Plugin::Base
      # Static interpreter that walks a literal Lisp-style expression encoded as a Prism AST and returns a tag naming
      # the type the runtime evaluation would produce.
      #
      # Tags are kept as plain Symbols (`:integer`, `:float`, `:bool`) and translated to Rigor type carriers at the
      # plugin boundary; that keeps the grammar table easy to read and the type API surface contained to one site.
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
      #              | :let  (binding & destructuring)
      #
      # Every expression that does not fit the grammar — a non-literal element, an unknown operator, a wrong arity —
      # yields {UnknownExpression} so the caller can decide whether to stay silent or to publish a diagnostic.
      class Interpreter
        # Static type tags the interpreter produces.
        INTEGER = :integer
        FLOAT = :float
        BOOL = :bool

        NUMERIC = [INTEGER, FLOAT].freeze

        # Carries both a type tag and an optional concrete value. When `value` is non-nil the result is a precise
        # constant (e.g. `[:+, 1, 2]` → tag `:integer`, value `3`).
        Result = Struct.new(:tag, :value, keyword_init: true) do
          def error? = false
        end

        # Produced when the expression is well-formed but its operands violate the operator's domain.
        TypeError = Struct.new(:message, :node, keyword_init: true) do
          def error? = true
        end

        # Produced when the expression is outside the supported grammar. Distinct from {TypeError} so the plugin can
        # stay silent on user code that is just not a Lisp literal.
        UnknownExpression = Struct.new(:reason, :node, keyword_init: true) do
          def error? = false
        end

        # Returns one of:
        #   - a {Result} (tag + optional value) — success
        #   - an Array of {Result}s — successful union (`:if` branches)
        #   - {TypeError} — well-formed but ill-typed
        #   - {UnknownExpression} — outside the supported grammar
        def evaluate(node, env = {})
          case node
          when Prism::IntegerNode then Result.new(tag: INTEGER, value: node.value)
          when Prism::FloatNode then Result.new(tag: FLOAT, value: node.value)
          when Prism::TrueNode then Result.new(tag: BOOL, value: true)
          when Prism::FalseNode then Result.new(tag: BOOL, value: false)
          when Prism::SymbolNode
            sym = node.unescaped.to_sym
            if env.key?(sym)
              env[sym]
            else
              TypeError.new(message: "unbound variable `#{sym}`", node: node)
            end
          when Prism::ArrayNode then evaluate_form(node, env)
          else
            UnknownExpression.new(
              reason: "expected an integer, float, boolean, symbol, or [:op, ...] form, got #{describe_node(node)}",
              node: node
            )
          end
        end

        private

        def evaluate_form(node, env = {})
          elements = node.elements
          return UnknownExpression.new(reason: "empty literal `[]` is not a Lisp form", node: node) if elements.empty?

          op_node = elements.first
          unless op_node.is_a?(Prism::SymbolNode)
            return UnknownExpression.new(reason: "first element is not a symbol literal", node: op_node)
          end

          operator = op_node.unescaped.to_sym
          args = elements[1..]

          case operator
          when :+, :-, :*, :/ then evaluate_arith(operator, args, node, env)
          when :<, :>, :<=, :>=, :== then evaluate_compare(operator, args, node, env)
          when :and, :or then evaluate_boolean_binop(operator, args, node, env)
          when :not then evaluate_not(args, node, env)
          when :if then evaluate_if(args, node, env)
          when :let then evaluate_let(args, node, env)
          else
            UnknownExpression.new(reason: "unknown operator #{operator.inspect}", node: op_node)
          end
        end

        def evaluate_arith(operator, args, node, env)
          return arity_error(operator, 2, args.size, node) if args.size != 2

          left = evaluate(args[0], env)
          right = evaluate(args[1], env)
          return left if propagate?(left)
          return right if propagate?(right)

          unless numeric?(left) && numeric?(right)
            return TypeError.new(
              message: "`#{operator}` expects numeric operands, got #{describe(left)} and #{describe(right)}",
              node: node
            )
          end

          value = compute_arith_value(operator, left.value, right.value)
          Result.new(tag: numeric_join(left.tag, right.tag), value: value)
        end

        def evaluate_compare(operator, args, node, env)
          return arity_error(operator, 2, args.size, node) if args.size != 2

          left = evaluate(args[0], env)
          right = evaluate(args[1], env)
          return left if propagate?(left)
          return right if propagate?(right)

          unless numeric?(left) && numeric?(right)
            return TypeError.new(
              message: "`#{operator}` expects numeric operands, got #{describe(left)} and #{describe(right)}",
              node: node
            )
          end

          value = compute_compare_value(operator, left.value, right.value)
          Result.new(tag: BOOL, value: value)
        end

        def evaluate_boolean_binop(operator, args, node, env)
          return arity_error(operator, 2, args.size, node) if args.size != 2

          left = evaluate(args[0], env)
          right = evaluate(args[1], env)
          return left if propagate?(left)
          return right if propagate?(right)

          unless boolean?(left) && boolean?(right)
            return TypeError.new(
              message: "`#{operator}` expects boolean operands, got #{describe(left)} and #{describe(right)}",
              node: node
            )
          end

          value = compute_boolean_binop_value(operator, left.value, right.value)
          Result.new(tag: BOOL, value: value)
        end

        def evaluate_not(args, node, env)
          return arity_error(:not, 1, args.size, node) if args.size != 1

          inner = evaluate(args[0], env)
          return inner if propagate?(inner)
          unless boolean?(inner)
            return TypeError.new(
              message: "`not` expects a boolean operand, got #{describe(inner)}",
              node: node
            )
          end

          value = inner.value.nil? ? nil : !inner.value
          Result.new(tag: BOOL, value: value)
        end

        def evaluate_if(args, node, env)
          return arity_error(:if, 3, args.size, node) if args.size != 3

          cond = evaluate(args[0], env)
          return cond if propagate?(cond)
          unless boolean?(cond)
            return TypeError.new(
              message: "`if` condition must be boolean, got #{describe(cond)}",
              node: node
            )
          end

          then_branch = evaluate(args[1], env)
          return then_branch if propagate?(then_branch)

          else_branch = evaluate(args[2], env)
          return else_branch if propagate?(else_branch)

          tag_union(then_branch, else_branch)
        end

        def evaluate_let(args, node, env)
          return arity_error(:let, 2, args.size, node) if args.size != 2

          bindings_node = args[0]
          body_node = args[1]

          child_env = env.dup
          err = extract_all_bindings(bindings_node, child_env, env)
          return err if err

          evaluate(body_node, child_env)
        end

        def extract_all_bindings(bindings_node, child_env, eval_env)
          unless bindings_node.is_a?(Prism::ArrayNode)
            return TypeError.new(message: "`let` bindings must be an array literal", node: bindings_node)
          end

          elements = bindings_node.elements
          return nil if elements.empty?

          if elements.first.is_a?(Prism::SymbolNode)
            extract_single_binding(elements, child_env, eval_env, bindings_node)
          elsif elements.size == 2 && pattern_node?(elements[0]) && !binding_pair?(elements[1])
            extract_pattern_binding(elements[0], elements[1], child_env, eval_env, bindings_node)
          else
            elements.each do |elem|
              unless elem.is_a?(Prism::ArrayNode)
                return TypeError.new(message: "binding entry must be an array", node: elem)
              end

              elem_parts = elem.elements
              if elem_parts.first.is_a?(Prism::SymbolNode)
                err = extract_single_binding(elem_parts, child_env, eval_env, elem)
                return err if err
              elsif elem_parts.size == 2 && pattern_node?(elem_parts[0])
                err = extract_pattern_binding(elem_parts[0], elem_parts[1], child_env, eval_env, elem)
                return err if err
              else
                return TypeError.new(message: "malformed binding entry", node: elem)
              end
            end
            nil
          end
        end

        def extract_single_binding(parts, child_env, eval_env, node)
          return arity_error(:let_binding, 2, parts.size, node) if parts.size != 2

          sym = parts[0].unescaped.to_sym
          val = evaluate(parts[1], eval_env)
          return val if propagate?(val)

          child_env[sym] = val
          nil
        end

        def extract_pattern_binding(pattern_node, val_node, child_env, eval_env, node)
          if pattern_node.is_a?(Prism::SymbolNode)
            val = evaluate(val_node, eval_env)
            return val if propagate?(val)

            child_env[pattern_node.unescaped.to_sym] = val
            return nil
          end

          unless pattern_node.is_a?(Prism::ArrayNode)
            return TypeError.new(message: "pattern must be a symbol or array of symbols", node: pattern_node)
          end

          unless val_node.is_a?(Prism::ArrayNode)
            return TypeError.new(message: "destructuring expects an array value", node: val_node)
          end

          p_elems = pattern_node.elements
          v_elems = val_node.elements

          if p_elems.size != v_elems.size
            return TypeError.new(
              message: "destructuring arity mismatch: pattern expects #{p_elems.size} elements, got #{v_elems.size}",
              node: pattern_node
            )
          end

          p_elems.each_with_index do |p_elem, idx|
            err = extract_pattern_binding(p_elem, v_elems[idx], child_env, eval_env, node)
            return err if err
          end

          nil
        end

        def pattern_node?(node)
          case node
          when Prism::SymbolNode then true
          when Prism::ArrayNode then node.elements.all? { |e| pattern_node?(e) }
          else false
          end
        end

        def binding_pair?(node)
          node.is_a?(Prism::ArrayNode) && node.elements.size == 2 && pattern_node?(node.elements[0])
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

        def numeric?(result)
          NUMERIC.include?(result.tag) || (result.is_a?(Array) && result.all? { |r| NUMERIC.include?(r.tag) })
        end

        def boolean?(result)
          result.tag == BOOL || (result.is_a?(Array) && result.all? { |r| r.tag == BOOL })
        end

        def compute_arith_value(operator, left_val, right_val)
          return nil if left_val.nil? || right_val.nil?

          case operator
          when :+ then left_val + right_val
          when :- then left_val - right_val
          when :* then left_val * right_val
          when :/ then left_val / right_val
          end
        end

        def compute_compare_value(operator, left_val, right_val)
          return nil if left_val.nil? || right_val.nil?

          case operator
          when :<  then left_val < right_val
          when :>  then left_val > right_val
          when :<= then left_val <= right_val
          when :>= then left_val >= right_val
          when :== then left_val == right_val
          end
        end

        def compute_boolean_binop_value(operator, left_val, right_val)
          return nil if left_val.nil? || right_val.nil?

          case operator
          when :and then left_val && right_val
          when :or  then left_val || right_val
          end
        end

        def numeric_join(left_tag, right_tag)
          tags = [left_tag, right_tag].uniq
          tags.include?(FLOAT) ? FLOAT : INTEGER
        end

        def tag_union(left, right)
          members = ([left] | [right]).uniq
          if members.size == 1
            members.first
          else
            members
          end
        end

        def describe(result)
          case result
          when Array then result.map { |r| describe(r) }.join(" | ")
          when Result
            tag_str = case result.tag
                      when Symbol then result.tag.to_s.capitalize.then { |s| s == "Bool" ? "bool" : s }
                      else result.tag.inspect
                      end
            result.value.nil? ? tag_str : "#{tag_str}(#{result.value.inspect})"
          else result.inspect
          end
        end

        def describe_node(node)
          node.nil? ? "nil" : node.class.name.split("::").last
        end
      end
    end
  end
end
