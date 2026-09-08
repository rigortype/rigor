# frozen_string_literal: true

require_relative "../type"

module Rigor
  module Inference
    # Reads the endpoints out of a `Constant<Range>`.
    #
    # A `Constant` normally carries a value and no generic instantiation, which is why acceptance
    # ignores a nominal's `type_args` against one. A Range value is the exception: the engine only
    # builds `Constant<Range>` when both endpoints are static (`ExpressionTyper#type_of_range`), so
    # the element the range would yield IS known, and a `Range[T]` parameter can be judged against it.
    #
    # Two consumers share the reading so they cannot drift: `Acceptance` refutes a `Range[T]`
    # parameter whose `T` rejects an endpoint (issue #833), and `RbsDispatch` binds a method-level
    # `Range[A]` parameter's `A` from the endpoints (issue #834).
    module RangeConstant
      module_function

      # The non-`nil` endpoints of the range `type` pins, or nil when there is nothing to read from.
      #
      # nil — meaning "no opinion, keep the answer you already had" — covers a carrier that is not a
      # `Constant<Range>`, a range with no endpoint at all (`nil..nil` constrains nothing), and a
      # range whose endpoints are not literals. The literal set is the one
      # `ExpressionTyper#static_range_endpoint` pins; a value outside it reached the carrier by some
      # other route and the caller has no lifting for it.
      def literal_endpoints(type)
        return nil unless type.is_a?(Type::Constant)

        value = type.value
        return nil unless value.is_a?(::Range)

        endpoints = [value.begin, value.end].compact
        return nil if endpoints.empty?
        return nil unless endpoints.all? { |endpoint| literal_endpoint?(endpoint) }

        endpoints
      end

      # The endpoints lifted to their own classes and unioned — the element type the range would
      # yield. Lifting rather than pinning the values mirrors
      # `ExpressionTyper#nominal_range_for_endpoints`: `1..9` yields Integers, not the two values 1
      # and 9, so binding a `Range[A]` parameter's `A` to `Integer` states what the runtime can
      # honour. Nil when {#literal_endpoints} has nothing to read.
      def element_type(type)
        endpoints = literal_endpoints(type)
        return nil if endpoints.nil?

        Type::Combinator.union(*endpoints.map { |endpoint| Type::Combinator.nominal_of(endpoint.class.name) })
      end

      def literal_endpoint?(value)
        value.is_a?(::Integer) || value.is_a?(::Float) || value.is_a?(::String)
      end
    end
  end
end
