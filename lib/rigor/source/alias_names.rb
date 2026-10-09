# frozen_string_literal: true

require "prism"

module Rigor
  module Source
    # The `[new_name, old_name]` pair a method-alias statement names, read off its syntax alone: the `alias` keyword
    # (`alias to_m to_modint`, `alias :to_m :to_modint`) and an implicit-self `alias_method :to_m, :to_modint` call
    # whose two arguments are Symbol or String literals. A computed name (`alias_method name, :x`, an interpolated
    # symbol) is runtime data and reads as nil, so no walker files an alias for it.
    #
    # The one reader the per-file discovery walk ({Inference::ScopeIndexer}) and the `pre_eval:` pre-pass
    # ({Inference::ProjectPatchedScanner}) share, so a patch file's aliases mean the same thing in both.
    module AliasNames
      module_function

      # The pair for an `alias` keyword node or an `alias_method` call, or nil for any other node.
      def of(node)
        case node
        when Prism::AliasMethodNode then keyword_names(node)
        when Prism::CallNode then alias_method_call_names(node)
        end
      end

      # The pair for an `alias` keyword whose two names are plain symbols (a bare identifier parses as one), or nil.
      def keyword_names(alias_node)
        new_name = symbol_name(alias_node.new_name)
        old_name = symbol_name(alias_node.old_name)
        return nil if new_name.nil? || old_name.nil?

        [new_name, old_name]
      end

      # The pair for an implicit-self `alias_method` call with two literal Symbol / String arguments, or nil.
      def alias_method_call_names(call_node)
        return nil unless call_node.name == :alias_method && call_node.receiver.nil?

        args = call_node.arguments&.arguments
        return nil unless args && args.size == 2

        new_name = literal_name(args[0])
        old_name = literal_name(args[1])
        return nil if new_name.nil? || old_name.nil?

        [new_name, old_name]
      end

      def symbol_name(node)
        node.is_a?(Prism::SymbolNode) ? node.unescaped.to_sym : nil
      end

      def literal_name(node)
        return nil unless node.is_a?(Prism::SymbolNode) || node.is_a?(Prism::StringNode)

        node.unescaped&.to_sym
      end
    end
  end
end
