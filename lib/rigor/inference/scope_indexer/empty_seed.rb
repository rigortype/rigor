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

        def empty_seed?(node)
          case node
          when Prism::StringNode then node.unescaped.empty?
          when Prism::ArrayNode, Prism::HashNode then node.elements.empty?
          when Prism::CallNode then empty_string_dup?(node)
          else false
          end
        end

        # `+""`: the unfrozen empty String the accumulator idiom spells under `# frozen_string_literal: true`.
        def empty_string_dup?(node)
          node.name == :+@ && node.arguments.nil? && node.receiver.is_a?(Prism::StringNode) &&
            node.receiver.unescaped.empty?
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
        private_class_method :empty_string_dup?, :unpinned
      end
    end
  end
end
