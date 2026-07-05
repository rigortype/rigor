# frozen_string_literal: true

require "prism"

module Rigor
  module Source
    # Extracts literal Symbol/String values from Prism call arguments.
    #
    # The "is this argument a literal `:sym` or `"str"`, and if so what Symbol does it name?" question
    # recurs across the analyzer (sig-gen observation, attr-accessor generation, synthetic-method scanning)
    # and across nearly every DSL plugin (`state :draft`, `has_one_attached :avatar`,
    # `validate_presence_of(:name)`, …). This module is the one place that answers it, so the
    # `node.unescaped.to_sym if SymbolNode || StringNode` shape is written once rather than copied per call
    # site.
    #
    # `#unescaped` (not `#value`) is used deliberately so an interpolation- free `"foo"` / `:foo`
    # round-trips to `:foo` consistently for both node kinds.
    #
    # The surface is a small grid over two axes — which node kinds are accepted (`SymbolNode` only, or
    # `SymbolNode`/`StringNode`) and what the caller wants back (the interned `Symbol`, or the raw `String`
    # name). The SymbolNode-only forms ({.symbol} / {.symbol_name}) exist so a DSL that distinguishes `state
    # :draft` from `state "draft"` keeps that distinction instead of silently widening to accept the string
    # literal.
    #
    # | accepts            | → Symbol            | → String                 |
    # | ------------------ | ------------------- | ------------------------ |
    # | `:sym` only        | {.symbol}           | {.symbol_name}           |
    # | `:sym` or `"str"`  | {.symbol_or_string} | {.symbol_or_string_name} |
    module Literals
      module_function

      # The Symbol a literal `Prism::SymbolNode` / `Prism::StringNode` names, or `nil` for any other node
      # (including `nil`).
      #
      # @param node [Prism::Node, nil]
      # @return [Symbol, nil]
      def symbol_or_string(node)
        return nil unless node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)

        node.unescaped.to_sym
      end

      # The String a literal `Prism::SymbolNode` / `Prism::StringNode` names, or `nil` for any other node
      # (including `nil`). The String-returning sibling of {.symbol_or_string} — for callers that key on the
      # raw name rather than the interned Symbol (route helpers, factory names, filter targets).
      # `#unescaped` round-trips an interpolation-free `:foo` / `"foo"` to `"foo"` for both kinds.
      #
      # @param node [Prism::Node, nil]
      # @return [String, nil]
      def symbol_or_string_name(node)
        return nil unless node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)

        node.unescaped
      end

      # The Symbol a literal `Prism::SymbolNode` names, or `nil` for any other node (including a
      # `Prism::StringNode` and `nil`). Stricter than {.symbol_or_string}: a DSL that accepts only `:draft`
      # and not `"draft"` keeps that distinction by reaching for this rather than the Symbol-or-String form.
      #
      # @param node [Prism::Node, nil]
      # @return [Symbol, nil]
      def symbol(node)
        return nil unless node.is_a?(Prism::SymbolNode)

        node.unescaped.to_sym
      end

      # The String a literal `Prism::SymbolNode` names, or `nil` for any other node (including a
      # `Prism::StringNode` and `nil`). The String-returning sibling of {.symbol} — SymbolNode-only, but the
      # caller wants the raw name rather than the interned Symbol.
      #
      # @param node [Prism::Node, nil]
      # @return [String, nil]
      def symbol_name(node)
        return nil unless node.is_a?(Prism::SymbolNode)

        node.unescaped
      end

      # Every literal Symbol/String positional argument of a call, in source order. Non-literal arguments
      # are dropped. Returns `[]` when the call has no argument list.
      #
      # @param call_node [Prism::CallNode, nil]
      # @return [Array<Symbol>]
      def symbol_arguments(call_node)
        args = call_node&.arguments&.arguments
        return [] if args.nil?

        args.filter_map { |arg| symbol_or_string(arg) }
      end

      # Whether a node is a literal `Prism::SymbolNode` that names `name`. The key-comparison counterpart to
      # {.symbol_name} — for callers that need a predicate rather than an extraction (hash-key matching in
      # keyword or assoc argument positions, e.g. `el.is_a?(AssocNode) && symbol_named?(el.key, "required")`).
      # Uses `#unescaped` (not `#value`) for round-trip consistency.
      #
      # @param node [Prism::Node, nil]
      # @param name [String]
      # @return [Boolean]
      def symbol_named?(node, name)
        node.is_a?(Prism::SymbolNode) && node.unescaped == name
      end

      # The literal Symbol/String at positional `index`, or `nil` when the call has no argument list, the
      # index is out of range, or the argument there is not a literal Symbol/String.
      #
      # @param call_node [Prism::CallNode, nil]
      # @param index [Integer]
      # @return [Symbol, nil]
      def symbol_arg(call_node, index)
        args = call_node&.arguments&.arguments
        return nil if args.nil?

        symbol_or_string(args[index])
      end
    end
  end
end
