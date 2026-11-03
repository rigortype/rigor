# frozen_string_literal: true

require "prism"

require_relative "../../source/node_children"
require_relative "../closure_escape_analyzer"
require_relative "../remover_holder_scan"

module Rigor
  module Inference
    module AliasMutationFloor
      # Issue #2335 — the *foreign* locals of a frame body ({AliasMutationFloor}): those whose object may have come
      # from elsewhere, so they may be another local's object. A method parameter, a block or lambda parameter (but one
      # of a catalogued iterator over literals that read nothing, whose parameters are those literals' own objects), a
      # local any target node binds, and a local written anything but a new object.
      module ForeignLocals
        FRESH_VALUES = [
          Prism::ArrayNode, Prism::HashNode, Prism::StringNode, Prism::InterpolatedStringNode, Prism::XStringNode,
          Prism::InterpolatedXStringNode, Prism::IntegerNode, Prism::FloatNode, Prism::RationalNode, Prism::ImaginaryNode,
          Prism::SymbolNode, Prism::InterpolatedSymbolNode, Prism::NilNode, Prism::TrueNode, Prism::FalseNode,
          Prism::RangeNode, Prism::RegularExpressionNode, Prism::InterpolatedRegularExpressionNode
        ].freeze
        # `+"x"`, `"x".dup`, `String.new`: a new String.
        FRESH_STRING_CALLS = %i[+@ dup clone].to_set.freeze
        LITERAL_PARTS = [Prism::ArrayNode, Prism::HashNode, Prism::KeywordHashNode, Prism::AssocNode,
                         *FRESH_VALUES].freeze
        private_constant :FRESH_VALUES, :FRESH_STRING_CALLS, :LITERAL_PARTS

        module_function

        # `[foreign, entry]`: the foreign locals, and the method parameters the body never rebinds, each frozen.
        def collect(body, parameters)
          entry = Set.new
          collect_parameters(parameters, entry)
          foreign = Set.new(entry)
          written = Set.new
          collect_foreign(body, foreign, written)
          [foreign.freeze, (entry - written).freeze]
        end

        def collect_parameters(node, names)
          return if node.nil?

          names << node.name if node.class.name.end_with?("ParameterNode") && node.respond_to?(:name) && node.name
          node.rigor_each_child { |child| collect_parameters(child, names) }
        end

        # `foreign` gains every block or lambda parameter and every local a write binds to an object from elsewhere (an
        # operator write's value is a call result); `written` every local any write or target binds.
        def collect_foreign(node, foreign, written, literal_blocks = Set.new.compare_by_identity)
          case node
          when Prism::CallNode then literal_blocks << node.block if literal_iterator_block?(node)
          when Prism::BlockNode, Prism::LambdaNode
            collect_parameters(node.parameters, foreign) unless literal_blocks.include?(node)
          when Prism::LocalVariableTargetNode, Prism::LocalVariableOperatorWriteNode
            foreign << written_name(node, written)
          when Prism::LocalVariableWriteNode, Prism::LocalVariableOrWriteNode, Prism::LocalVariableAndWriteNode
            name = written_name(node, written)
            foreign << name unless fresh_value?(node.value)
          when Prism::DefNode then return
          end
          node.rigor_each_child { |child| collect_foreign(child, foreign, written, literal_blocks) }
        end

        # A catalogued iterator over literals that read nothing (`[[1], [2]].each { |x| }`,
        # `[1].each_with_object({}) { |x, h| }`): its block's parameters are those literals' own new objects. Any other
        # block's parameters may be any object.
        def literal_iterator_block?(call_node)
          return false unless call_node.block.is_a?(Prism::BlockNode)
          return false unless ClosureEscapeAnalyzer.iterator_name?(call_node.name)

          [call_node.receiver, *call_node.arguments&.arguments].all? do |operand|
            !operand.nil? && literal_only?(operand)
          end
        end

        def literal_only?(node)
          return false unless LITERAL_PARTS.any? { |klass| node.is_a?(klass) }

          node.rigor_each_child { |child| return false unless literal_only?(child) }
          true
        end

        def written_name(node, written)
          written << node.name
          node.name
        end

        # A value that is a new object, so the local it binds holds no other holder's object.
        def fresh_value?(value)
          value = RemoverHolderScan.unparenthesised(value)
          return true if FRESH_VALUES.any? { |klass| value.is_a?(klass) }
          return false unless value.is_a?(Prism::CallNode)
          return true if RemoverHolderScan.fresh_value?(value)

          receiver = value.receiver
          (FRESH_STRING_CALLS.include?(value.name) &&
            (receiver.is_a?(Prism::StringNode) || receiver.is_a?(Prism::InterpolatedStringNode))) ||
            (value.name == :new && receiver.is_a?(Prism::ConstantReadNode) && receiver.name == :String)
        end
      end
    end
  end
end
