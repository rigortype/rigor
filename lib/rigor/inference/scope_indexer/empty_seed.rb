# frozen_string_literal: true

require "prism"
require_relative "../../type"

module Rigor
  module Inference
    module ScopeIndexer
      # Issue #2499 — the accumulator idiom: a heap slot (an instance, class or global variable, or a constant)
      # seeded with an empty literal and filled later, often from a method, a subclass, a mixin or another file
      # the census cannot see. The seed is never proof that the slot is still empty, so the census records it
      # without its emptiness: `""` and `+""` as `String`, `[]` as `Array[untyped]`, `{}` as
      # `Hash[untyped, untyped]`. `String.new`, `Array.new` and `Hash.new` already type as their nominal.
      #
      # Only the empty spellings count. A non-empty literal (`@order = "asc"`, `MODES = %w[a b]`,
      # `@opts = { a: 1 }`) keeps its exact type: such slots are modes and config tables, and an RBS parameter
      # typed `"asc" | "desc"` must still accept them. A local keeps its flow precision; this applies only where
      # the census seeds a heap slot.
      module EmptySeed
        module_function

        # `type` with its emptiness dropped when `node` is an empty seed literal, otherwise `type` itself.
        def erase(node, type)
          return type unless empty_seed?(node)

          members = type.is_a?(Type::Union) ? type.members : [type]
          Type::Combinator.union(*members.map { |member| unpinned(member) })
        end

        # `{ name => value node }` for each leading target of a multiple assignment whose right-hand side is a literal
        # list (`@a, @b = {}, []`), so each slot is erased from its own element. Empty for any other right-hand side.
        def multi_write_values(node)
          value = node.value
          return EMPTY_VALUES unless value.is_a?(Prism::ArrayNode)

          elements = value.elements
          node.lefts.each_with_index.with_object({}) do |(target, index), values|
            break values if index >= elements.size || elements[index].is_a?(Prism::SplatNode)
            next unless target.respond_to?(:name)

            values[target.name] = elements[index]
          end
        end

        EMPTY_VALUES = {}.freeze
        private_constant :EMPTY_VALUES

        # A chained write (`@a = @b = ""`) stores the inner write's value in the outer slot too, so it is followed.
        def empty_seed?(node)
          case node
          when Prism::StringNode then node.unescaped.empty?
          when Prism::ArrayNode, Prism::HashNode then node.elements.empty?
          when Prism::CallNode then copied_empty_seed?(node)
          when *CHAINED_WRITES then empty_seed?(node.value)
          else false
          end
        end

        CHAINED_WRITES = [
          Prism::LocalVariableWriteNode, Prism::InstanceVariableWriteNode, Prism::ClassVariableWriteNode,
          Prism::GlobalVariableWriteNode, Prism::ConstantWriteNode, Prism::ConstantPathWriteNode
        ].freeze
        private_constant :CHAINED_WRITES

        # `+""`, the unfrozen empty String the accumulator idiom spells under `# frozen_string_literal: true`, and a
        # `.dup` of an empty seed (`"".dup`, `[].dup`, `{}.dup`).
        def copied_empty_seed?(node)
          return false unless node.arguments.nil? && node.block.nil?

          case node.name
          when :+@ then node.receiver.is_a?(Prism::StringNode) && node.receiver.unescaped.empty?
          when :dup then empty_seed?(node.receiver)
          else false
          end
        end

        def unpinned(member)
          case member
          when Type::Constant
            member.value.is_a?(String) && member.value.empty? ? Type::Combinator.nominal_of("String") : member
          when Type::Tuple
            if member.elements.empty?
              Type::Combinator.nominal_of("Array",
                                          type_args: [Type::Combinator.untyped])
            else
              member
            end
          when Type::HashShape
            return member unless member.pairs.empty?

            Type::Combinator.nominal_of("Hash", type_args: [Type::Combinator.untyped, Type::Combinator.untyped])
          else member
          end
        end
        private_class_method :copied_empty_seed?, :unpinned
      end
    end
  end
end
