# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Which arguments `OverloadSelector` may not discriminate on. Issue #1021 — the strict and alias passes must not
      # key on an argument whose type cannot rule an overload out: the bare untyped carrier, or a union with an untyped
      # member. That member may reach any overload at runtime, so a strict match is decided by the union's other
      # members alone — `Dynamic[top] | nil` pinned `Regexp#match?(nil) -> false` and typed a live predicate as the
      # literal `false`. The gradual pass still accepts against the whole union, so `Dynamic[top] | nil` keeps both
      # `match?` overloads and the #521 join answers `Dynamic[bool]`.
      #
      # A `Dynamic` with a concrete static facet stays out: its facet discriminates. One whose facet itself holds the
      # untyped carrier does not (#1675): `Array[untyped] | Array[Integer]` indexed at an untyped position answers
      # `Dynamic[Array[untyped] | untyped | nil] | Dynamic[Array[Integer] | Integer | nil]`, and read as precise,
      # `0 + @data[i]` took `(Integer) -> Integer`.
      module ImpreciseArgument
        module_function

        # The literal `untyped` carrier, `Dynamic[top]`.
        def untyped?(type) = type.is_a?(Type::Dynamic) && type.static_facet.is_a?(Type::Top)

        # The untyped carrier itself, or a union or `Dynamic` holding it at any depth.
        def imprecise?(type)
          case type
          when Type::Dynamic then type.static_facet.is_a?(Type::Top) || imprecise?(type.static_facet)
          when Type::Union then type.members.any? { |member| imprecise?(member) }
          else false
          end
        end

        # Whether the call holds an imprecise argument: a positional one, or (#1737) a value of the call's keyword
        # hash when `keywords_last`. An untyped keyword value reaches every overload's keyword just as an untyped
        # positional reaches every positional parameter, so `m(1, mode: untyped)` must not pick `mode: Symbol` over
        # `mode: Integer` by declaration order.
        def any_in?(arg_types, keywords_last)
          return true if arg_types.any? { |arg| imprecise?(arg) }
          return false unless keywords_last

          keywords = arg_types.last
          keywords.is_a?(Type::HashShape) && keywords.pairs.each_value.any? { |value| imprecise?(value) }
        end

        # Issue #1675 — the argument list with each imprecise argument replaced by the bare untyped carrier, or nil
        # when no argument holds the carrier beside something precise. Through its untyped part such an argument
        # reaches every overload the bare carrier reaches, including one a precise member rules out of the
        # whole-argument match: `0 + (1 | untyped)` kept only `(Integer) -> Integer`, because `(Float)` refuses the
        # `1`, and typed the sum `Integer` where the untyped part may be a `Float` or a project `Numeric`.
        def untyped_stand_ins(arg_types)
          return nil unless arg_types.any? { |arg| !untyped?(arg) && imprecise?(arg) }

          arg_types.map { |arg| imprecise?(arg) ? Type::Combinator.untyped : arg }
        end
      end
    end
  end
end
