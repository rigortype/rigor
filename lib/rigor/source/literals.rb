# frozen_string_literal: true

require "prism"

module Rigor
  module Source
    # Extracts literal Symbol/String values from Prism call arguments.
    #
    # The "is this argument a literal `:sym` or `"str"`, and if so what
    # Symbol does it name?" question recurs across the analyzer (sig-gen
    # observation, attr-accessor generation, synthetic-method scanning)
    # and across nearly every DSL plugin (`state :draft`,
    # `has_one_attached :avatar`, `validate_presence_of(:name)`, …). This
    # module is the one place that answers it, so the
    # `node.unescaped.to_sym if SymbolNode || StringNode` shape is written
    # once rather than copied per call site.
    #
    # `#unescaped` (not `#value`) is used deliberately so an interpolation-
    # free `"foo"` / `:foo` round-trips to `:foo` consistently for both
    # node kinds.
    module Literals
      module_function

      # The Symbol a literal `Prism::SymbolNode` / `Prism::StringNode`
      # names, or `nil` for any other node (including `nil`).
      #
      # @param node [Prism::Node, nil]
      # @return [Symbol, nil]
      def symbol_or_string(node)
        return nil unless node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)

        node.unescaped.to_sym
      end

      # Every literal Symbol/String positional argument of a call, in
      # source order. Non-literal arguments are dropped. Returns `[]` when
      # the call has no argument list.
      #
      # @param call_node [Prism::CallNode, nil]
      # @return [Array<Symbol>]
      def symbol_arguments(call_node)
        args = call_node&.arguments&.arguments
        return [] if args.nil?

        args.filter_map { |arg| symbol_or_string(arg) }
      end

      # The literal Symbol/String at positional `index`, or `nil` when the
      # call has no argument list, the index is out of range, or the
      # argument there is not a literal Symbol/String.
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
