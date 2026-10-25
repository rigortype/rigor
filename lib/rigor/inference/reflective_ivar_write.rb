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
    # A call counts when its receiver is implicit or `self` and it passes any argument ({.self_write?}). With
    # exactly two plain positional arguments, the first a Symbol or String literal naming an instance variable
    # (`:@n`, `"@n"`; Ruby accepts both), it is a write of that variable ({.literal_name}). Any other argument list
    # — a computed name, a splat (`instance_variable_set(*args)`), a keyword hash, or a literal Ruby rejects with
    # `NameError` (`:n`) — names an ivar the analysis cannot see, so every ivar the scope binds may have been
    # written ({.apply}; for a rejected literal this over-approximates, which only widens).
    # `obj.instance_variable_set` writes another object's ivar and does not count; neither does the reflective
    # `send(:instance_variable_set, …)`.
    module ReflectiveIvarWrite
      METHOD_NAME = :instance_variable_set
      private_constant :METHOD_NAME

      IVAR_NAME = /\A@[A-Za-z_]\w*\z/
      private_constant :IVAR_NAME

      REPEATING_KEY = :__rigor_reflective_ivar_write_repeating__
      private_constant :REPEATING_KEY

      module_function

      # True when `node` is an `instance_variable_set` on `self` with at least one argument.
      def self_write?(node)
        return false unless node.is_a?(Prism::CallNode) && node.name == METHOD_NAME
        return false unless node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)

        arguments = node.arguments&.arguments
        !arguments.nil? && !arguments.empty?
      end

      # `:@n` for `instance_variable_set(:@n, v)` or `instance_variable_set("@n", v)` on `self`, else nil.
      def literal_name(node)
        return nil unless self_write?(node)

        arguments = node.arguments.arguments
        return nil unless arguments.size == 2 && arguments.none? { |arg| splat_or_keywords?(arg) }

        name = arguments.first
        text =
          case name
          when Prism::SymbolNode, Prism::StringNode then name.unescaped
          end
        text && IVAR_NAME.match?(text) ? text.to_sym : nil
      end

      # True for a call {.self_write?} takes whose target {.literal_name} cannot name: it may write any ivar.
      def unknown_target?(node)
        self_write?(node) && literal_name(node).nil?
      end

      def value_node(node)
        node.arguments.arguments[1]
      end

      # Runs the block with the evaluator inside a `for` body or a `while` / `until` predicate. A `for` loop has no
      # rebind fixpoint, and a predicate runs before every iteration but is walked once, so a literal-name write there
      # must not replace the binding with one pass's value ({.apply}). A `while` / `until` body does not enter it: its
      # fixpoint widens the ivar (issue #1930).
      def in_repeating_body
        depth = Thread.current[REPEATING_KEY] || 0
        Thread.current[REPEATING_KEY] = depth + 1
        begin
          yield
        ensure
          Thread.current[REPEATING_KEY] = depth
        end
      end

      def repeating_body?
        (Thread.current[REPEATING_KEY] || 0).positive?
      end

      # `scope` after `node` runs. A literal name binds that ivar to the value's type (yielded), as `@n = v` does.
      # Inside a `for` body or a loop predicate ({.in_repeating_body}) the value and untyped are joined into the
      # current binding instead: nothing widens the single pass's value across iterations there. Any other call joins
      # untyped into every ivar `scope` binds: any one of them may now hold the value, and joining the
      # value's own type would report a method the old value has and the new one lacks. An ivar on its ADR-58
      # declaration seed keeps its mark, which stops a nil in the seed from fuelling a nil-receiver diagnostic.
      def apply(node, scope)
        return scope unless self_write?(node)

        name = literal_name(node)
        return bind_literal(scope, name, yield) if name

        floor = Type::Combinator.untyped
        scope.ivars.reduce(scope) do |acc, (ivar, type)|
          widened = Type::Combinator.union(type, floor)
          rebound = acc.with_ivar(ivar, widened).without_ivar_guard(ivar)
          scope.declaration_sourced?(:ivar, ivar) ? rebound.seed_declaration_sourced_ivar(ivar, widened) : rebound
        end
      end

      def bind_literal(scope, name, value)
        type = repeating_body? ? Type::Combinator.union(*scope.ivar(name), value, Type::Combinator.untyped) : value
        scope.with_ivar(name, type).without_ivar_guard(name)
      end

      def splat_or_keywords?(arg)
        arg.is_a?(Prism::SplatNode) || arg.is_a?(Prism::KeywordHashNode) || arg.is_a?(Prism::BlockArgumentNode)
      end
    end
  end
end
