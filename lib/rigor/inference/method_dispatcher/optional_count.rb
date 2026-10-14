# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Issue #1393 — `min` / `max` / `min_by` / `max_by` take an OPTIONAL count, and Ruby reads a `nil` count as
      # "no count" (except blockless `Range#min` / `Range#max`, which raise; those are left alone):
      # `[1, 2].min_by(nil) { |s| s }` is `1`, not `[1]`, and `[1, 2].max(nil)` is `2`. The RBS
      # declares only `() ...` and `(Integer) ...` arms, so a `nil` argument matched none of them and the selector
      # fell back to the blockless `Enumerator` arm — a confidently wrong type, and a false `call.undefined-method`
      # on `xs.min_by(limit) { … }.succ` where `limit` may be `nil`.
      #
      # This splits the count argument. A `nil` part is dispatched as the no-argument call (so every no-count
      # answer, including the #1333 non-empty fold, applies); a non-`nil` part is dispatched as written; a union
      # of both answers the union of the two results. A count that has no `nil` part is left to the caller
      # untouched. Only the core receivers whose methods these are (`Array`, `Hash`, `Range`, `Set`, and their
      # shape and constant carriers) are rewritten, so a user class's own `min(limit)` is not reinterpreted.
      module OptionalCount
        module_function

        METHODS = Set[:min, :max, :min_by, :max_by].freeze
        # `Range` defines its own blockless `min` / `max`, which raise `TypeError` for a `nil` count in Ruby 4.0;
        # only with a block does it fall through to `Enumerable`'s, which read `nil` as no count.
        COUNTED_BY_ENUMERABLE_ONLY = Set[:min, :max].freeze
        RECEIVER_CLASSES = Set["Array", "Hash", "Range", "Set"].freeze

        # @return nil when the call is not a nil-count call; otherwise a one-element list holding the non-`nil`
        #   part of the count (itself nil when the count is only `nil`).
        def split(receiver, method_name, args, block: true)
          return nil unless METHODS.include?(method_name) && args.size == 1 && core_receiver?(receiver)
          return nil if !block && COUNTED_BY_ENUMERABLE_ONLY.include?(method_name) && range_receiver?(receiver)

          arg = args.first
          members = arg.is_a?(Type::Union) ? arg.members : [arg]
          return nil unless members.any? { |m| nil_constant?(m) }

          rest = members.reject { |m| nil_constant?(m) }
          [rest.empty? ? nil : Type::Combinator.union(*rest)]
        end

        def range_receiver?(receiver)
          (receiver.is_a?(Type::Constant) && receiver.value.is_a?(Range)) ||
            (receiver.is_a?(Type::Nominal) && receiver.class_name == "Range")
        end

        def nil_constant?(type)
          type.is_a?(Type::Constant) && type.value.nil?
        end

        def core_receiver?(receiver)
          case receiver
          when Type::Tuple, Type::HashShape then true
          when Type::Constant then receiver.value.is_a?(Range) || receiver.value.is_a?(::Set)
          when Type::Nominal then RECEIVER_CLASSES.include?(receiver.class_name)
          else false
          end
        end
      end
    end
  end
end
