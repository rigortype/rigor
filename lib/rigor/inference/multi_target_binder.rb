# frozen_string_literal: true

require "prism"

require_relative "../type"

module Rigor
  module Inference
    # Slice 5 phase 2 sub-phase 2 destructuring binder.
    #
    # `Rigor::Inference::MultiTargetBinder` decomposes a tuple-shaped
    # right-hand side type against a Prism multi-target tree and
    # produces a `name -> Rigor::Type` binding map. The binder is
    # shared between two surfaces:
    #
    # 1. `Rigor::Inference::StatementEvaluator#eval_multi_write` for
    #    the statement-level `a, b = rhs` form (`Prism::MultiWriteNode`).
    # 2. `Rigor::Inference::BlockParameterBinder` for nested
    #    destructuring inside block parameter lists
    #    (`Prism::MultiTargetNode` under `BlockParametersNode#requireds`).
    #
    # Both Prism nodes share the same `lefts` / `rest` (a
    # `Prism::SplatNode`) / `rights` triple, so the binder treats them
    # uniformly. The binder is pure: it MUST NOT mutate its inputs and
    # MUST return a fresh `Hash` on every call.
    #
    # The binder threads `Type::Tuple` decompositions when the
    # right-hand side carrier is a known-arity tuple. Other carriers
    # (`Nominal[Array]`, `Dynamic[Top]`, `Top`, `Bot`, ...) collapse
    # to `Dynamic[Top]` per slot — Slice 5 phase 2 sub-phase 2 stays
    # conservative on dynamic-arity right-hand sides until the
    # narrower receiver-shape lattice lands.
    #
    # Targets the binder recognises:
    #
    # - `Prism::LocalVariableTargetNode` — used by the statement-level
    #   `a, b = rhs` form. Binds `target.name` to its slice of the
    #   right-hand side.
    # - `Prism::RequiredParameterNode` — used by block-parameter
    #   destructuring (`|(a, b), c|`). Prism encodes the inner names
    #   of a block-side `MultiTargetNode` as parameter nodes rather
    #   than target nodes; the binder treats them uniformly with
    #   their `LocalVariableTargetNode` cousins because they carry
    #   the same `name:` field and the same observable semantics
    #   (binding a fresh local in the block-entry scope).
    # - `Prism::MultiTargetNode` — recurses with the slot's type as
    #   the new right-hand side.
    # - `Prism::SplatNode` (used for `rest`) — its `expression` MUST
    #   be a `Prism::LocalVariableTargetNode` or a
    #   `Prism::RequiredParameterNode` to be observable; an anonymous
    #   `*` splat or a non-local target is skipped.
    #
    # Other target kinds (`InstanceVariableTargetNode`,
    # `ConstantTargetNode`, `IndexTargetNode`, `CallTargetNode`,
    # `ConstantPathTargetNode`, `ImplicitRestNode`, ...) MUST be
    # silently skipped: they have no observable contribution to the
    # local-variable scope the StatementEvaluator threads.
    #
    # See docs/internal-spec/inference-engine.md for the binding
    # contract and docs/adr/4-type-inference-engine.md for the slice
    # rationale.
    module MultiTargetBinder
      module_function

      # @param target_node [Prism::MultiWriteNode, Prism::MultiTargetNode]
      # @param rhs_type [Rigor::Type] type of the right-hand side
      # @return [Hash{Symbol => Rigor::Type}]
      def bind(target_node, rhs_type)
        bindings = {}
        visit(target_node, rhs_type, bindings)
        bindings
      end

      class << self
        private

        def visit(node, rhs_type, bindings)
          lefts = node.lefts || []
          rest = node.rest
          rights = node.rights || []

          fronts, rest_type, backs = decompose(rhs_type, lefts.size, rights.size, rest_present: !rest.nil?)
          lefts.each_with_index { |t, i| bind_target(t, fronts[i], bindings) }
          bind_rest_target(rest, rest_type, bindings) if rest
          rights.each_with_index { |t, i| bind_target(t, backs[i], bindings) }
        end

        # Decomposes the right-hand side type into the per-slot
        # types. Returns a `[fronts, rest_type, backs]` triple, with
        # `fronts` and `backs` each an ordered array of length
        # `front_count`/`back_count`, and `rest_type` either a
        # `Rigor::Type` (when `rest_present:` is true) or `nil`.
        def decompose(rhs_type, front_count, back_count, rest_present:)
          if rhs_type.is_a?(Type::Tuple)
            decompose_tuple(rhs_type, front_count, back_count, rest_present: rest_present)
          else
            decompose_default(front_count, back_count, rest_present: rest_present)
          end
        end

        def decompose_tuple(tuple, front_count, back_count, rest_present:)
          elements = tuple.elements
          fronts = Array.new(front_count) { |i| elements[i] || Type::Combinator.constant_of(nil) }
          if rest_present
            middle_end = [elements.size - back_count, front_count].max
            middle = elements[front_count...middle_end] || []
            rest_type = Type::Combinator.tuple_of(*middle)
            backs = Array.new(back_count) { |i| elements[middle_end + i] || Type::Combinator.constant_of(nil) }
          else
            rest_type = nil
            backs = Array.new(back_count) { |i| elements[front_count + i] || Type::Combinator.constant_of(nil) }
          end
          [fronts, rest_type, backs]
        end

        def decompose_default(front_count, back_count, rest_present:)
          [
            Array.new(front_count) { Type::Combinator.untyped },
            rest_present ? Type::Combinator.untyped : nil,
            Array.new(back_count) { Type::Combinator.untyped }
          ]
        end

        def bind_target(target, type, bindings)
          case target
          when Prism::LocalVariableTargetNode, Prism::RequiredParameterNode
            bindings[target.name] = type
          when Prism::MultiTargetNode
            visit(target, type, bindings)
          end
        end

        def bind_rest_target(splat_node, type, bindings)
          expression = splat_node.expression
          case expression
          when Prism::LocalVariableTargetNode, Prism::RequiredParameterNode
            bindings[expression.name] = type
          end
        end
      end
    end
  end
end
