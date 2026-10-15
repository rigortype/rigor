# frozen_string_literal: true

require "prism"

require_relative "../type"

module Rigor
  module Inference
    # Issue #1889 — `instance_variable_set` called on `self` writes an instance variable that no write node shows.
    # Left unseen, the binding the call site holds outlived it: `@n = 0; instance_variable_set(:@n, 5)` kept `@n`
    # on `0`, and a block that wrote `@n` only this way never entered the captured-binding name set, so
    # `[1, 2].inject(0) { |a, e| instance_variable_set(:@n, @n + 1); a + @n }` folded to a constant.
    #
    # A call counts when its receiver is implicit or `self` and it passes exactly two positional arguments. A
    # Symbol or String literal naming an instance variable (`:@n`, `"@n"`; Ruby accepts both) is a write of that
    # variable ({.literal_name}). Any other first argument names an ivar the analysis cannot see, so every ivar the
    # scope binds may have been written ({.apply}). `obj.instance_variable_set` writes another object's ivar and
    # does not count; neither does the reflective `send(:instance_variable_set, …)`.
    module ReflectiveIvarWrite
      METHOD_NAME = :instance_variable_set
      private_constant :METHOD_NAME

      IVAR_NAME = /\A@[A-Za-z_]\w*\z/
      private_constant :IVAR_NAME

      module_function

      # True when `node` is an `instance_variable_set` on `self` that this module reads as a write.
      def self_write?(node)
        return false unless node.is_a?(Prism::CallNode) && node.name == METHOD_NAME
        return false unless node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)

        arguments = node.arguments&.arguments
        !arguments.nil? && arguments.size == 2 && arguments.none? { |arg| splat_or_keywords?(arg) }
      end

      # `:@n` for `instance_variable_set(:@n, v)` or `instance_variable_set("@n", v)` on `self`, else nil (a
      # non-literal name, a name Ruby would reject, or a call {.self_write?} does not take).
      def literal_name(node)
        return nil unless self_write?(node)

        name = node.arguments.arguments.first
        text =
          case name
          when Prism::SymbolNode, Prism::StringNode then name.unescaped
          end
        text && IVAR_NAME.match?(text) ? text.to_sym : nil
      end

      # The value argument of a call {.self_write?} takes.
      def value_node(node)
        node.arguments.arguments[1]
      end

      # `scope` after `node` runs. A literal name binds that ivar to `value_type`, as `@n = v` does. A non-literal
      # name joins `Dynamic[top]` into every ivar `scope` binds that is not on its ADR-58 declaration seed: any one
      # of them may now hold the value, and joining the value's own type instead would report a method the old
      # value has but the new one lacks. A declaration-seeded ivar is left on its seed, whose mark keeps its nil
      # from being diagnostic fuel.
      def apply(node, scope)
        return scope unless self_write?(node)

        name = literal_name(node)
        if name
          scope.with_ivar(name, yield).without_ivar_guard(name)
        else
          floor = Type::Combinator.untyped
          scope.ivars.reduce(scope) do |acc, (ivar, type)|
            next acc if scope.declaration_sourced?(:ivar, ivar)

            acc.with_ivar(ivar, Type::Combinator.union(type, floor)).without_ivar_guard(ivar)
          end
        end
      end

      def splat_or_keywords?(arg)
        arg.is_a?(Prism::SplatNode) || arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::BlockArgumentNode)
      end
    end
  end
end
