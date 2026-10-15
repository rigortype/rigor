# frozen_string_literal: true

require "prism"

require_relative "slot"

module Rigor
  module Lens
    # A `def`'s parameter list as slots and as the RBS head sig-gen would write for an undeclared method.
    module Parameters
      module_function

      UNDECLARED = "inferred_return_untyped"

      # [params (nil for an argument-forwarding list), block or nil, "(…)" head]. A definition takes a block when
      # it declares `&blk` or `yields` (its body yields).
      def read(node, yields: false)
        block = yields ? undeclared_block : nil
        return [[], block, "()"] if node.nil?
        return [nil, block, "(?)"] if node.keyword_rest.is_a?(Prism::ForwardingParameterNode)

        entries = entries(node)
        params = entries.map { |kind, name| { "name" => name&.to_s, "kind" => kind, "type" => undeclared } }
        block = undeclared_block if node.block
        [params, block, "(#{entries.map { |kind, name| spell(kind, name) }.join(', ')})"]
      end

      # `[kind, name]` per parameter, in declaration order.
      def entries(node)
        node.requireds.map { |param| ["required", name_of(param)] } +
          node.optionals.map { |param| ["optional", param.name] } +
          rest(node.rest) +
          node.posts.map { |param| ["post", name_of(param)] } +
          node.keywords.map { |param| [keyword_kind(param), param.name] } +
          keyword_rest(node.keyword_rest)
      end

      def undeclared
        Slot.dynamic("inferred", UNDECLARED)
      end

      def undeclared_block
        { "required" => false, "type" => undeclared }
      end

      # Whether a `def` body yields, outside the bodies whose `yield` belongs elsewhere: a nested `def`, a lambda,
      # a `define_method` block.
      def yields?(node)
        return false if node.nil?
        return true if node.is_a?(Prism::YieldNode)
        return false if node.is_a?(Prism::DefNode) || node.is_a?(Prism::LambdaNode)
        return false if node.is_a?(Prism::CallNode) && node.name == :define_method && node.receiver.nil?

        node.compact_child_nodes.any? { |child| yields?(child) }
      end

      # The shape of a parameter list: names and kinds, with every type null (lens.md § Sites).
      def shape(params, block)
        [params&.map { |param| param.merge("type" => nil) }, block&.merge("type" => nil)]
      end

      def name_of(param)
        param.respond_to?(:name) ? param.name : nil
      end

      def keyword_kind(param)
        param.is_a?(Prism::RequiredKeywordParameterNode) ? "keyreq" : "key"
      end

      def rest(node)
        node.is_a?(Prism::RestParameterNode) ? [["rest", node.name]] : []
      end

      def keyword_rest(node)
        node.is_a?(Prism::KeywordRestParameterNode) ? [["keyrest", node.name]] : []
      end

      def spell(kind, name)
        label = name ? " #{name}" : ""
        case kind
        when "required", "post" then "untyped#{label}"
        when "optional" then "?untyped#{label}"
        when "rest" then "*untyped#{label}"
        when "keyreq" then "#{name}: untyped"
        when "key" then "?#{name}: untyped"
        when "keyrest" then "**untyped#{label}"
        end
      end
    end
  end
end
