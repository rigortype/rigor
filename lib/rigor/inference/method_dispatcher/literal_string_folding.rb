# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Dispatcher tier that lifts string-composition results into
      # the `literal-string` carrier when every operand is itself
      # literal-bearing. Sits between {ConstantFolding} (which
      # handles all-Constant cases) and {ShapeDispatch}; runs only
      # for `String#+` / `String#*` calls whose inputs the
      # ConstantFolding tier could not fold to a precise
      # `Constant<String>` (e.g. one operand is `literal-string`
      # rather than `Constant<String>`, or the multiplication
      # exceeds the constant-fold size cap).
      #
      # Result rule:
      #
      # - `+`: receiver and argument MUST both be
      #   `Type::Combinator.literal_string_compatible?`. The result
      #   is `literal-string`.
      # - `*`: receiver MUST be literal-bearing; argument MUST be
      #   integer-typed. The result is `literal-string`.
      #
      # Other receiver / argument shapes decline so the next tier
      # (ShapeDispatch / FileFolding / RbsDispatch) takes over and
      # the call site widens to the RBS-declared `Nominal[String]`
      # as before.
      module LiteralStringFolding
        module_function

        def try_dispatch(receiver:, method_name:, args:, **)
          return nil unless Type::Combinator.literal_string_compatible?(receiver)
          return nil unless args.size == 1

          case method_name
          when :+ then fold_concat(args.first)
          when :* then fold_repeat(args.first)
          end
        end

        def fold_concat(arg_type)
          return nil unless Type::Combinator.literal_string_compatible?(arg_type)

          Type::Combinator.literal_string
        end

        def fold_repeat(arg_type)
          return nil unless integer_typed?(arg_type)
          return nil if known_negative_integer?(arg_type)

          Type::Combinator.literal_string
        end

        def integer_typed?(type)
          case type
          when Type::Constant then type.value.is_a?(Integer)
          when Type::Nominal then type.class_name == "Integer"
          when Type::IntegerRange then true
          else false
          end
        end

        # `String#*` raises ArgumentError on a negative multiplier, so a
        # `Constant<-1>` argument is not a valid lift target. Decline so
        # the call site keeps the existing nil-result behaviour rather
        # than promising a `literal-string` value that could never
        # exist at runtime.
        def known_negative_integer?(type)
          type.is_a?(Type::Constant) && type.value.is_a?(Integer) && type.value.negative?
        end

        private_class_method :fold_concat, :fold_repeat, :integer_typed?
      end
    end
  end
end
