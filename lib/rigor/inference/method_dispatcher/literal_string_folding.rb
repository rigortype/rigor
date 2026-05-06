# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Dispatcher tier that lifts string-composition results into
      # the `literal-string` carrier when every operand is itself
      # literal-bearing. Sits between {ConstantFolding} (which
      # handles all-Constant cases) and {ShapeDispatch}; runs for:
      #
      # - `String#+` / `String#*` / `String#<<` / `String#concat`
      #   on string-typed receivers whose inputs the
      #   ConstantFolding tier could not fold to a precise
      #   `Constant<String>` (e.g. one operand is `literal-string`
      #   rather than `Constant<String>`, or the multiplication
      #   exceeds the constant-fold size cap).
      # - `Array#join` on `Tuple[…]` receivers whose every element
      #   plus the separator argument (when given) is
      #   literal-bearing.
      #
      # Result rule:
      #
      # - `+`, `<<`, `concat`: receiver and argument MUST both be
      #   `Type::Combinator.literal_string_compatible?`. The result
      #   is `literal-string`. `<<` and `concat` mutate the
      #   receiver at runtime; the analyzer does not track that
      #   mutation against the local's binding, but the call's
      #   *return value* is the receiver itself, and the receiver
      #   stays literal-bearing because every appended slice was
      #   literal-bearing too.
      # - `*`: receiver MUST be literal-bearing; argument MUST be
      #   integer-typed. The result is `literal-string`.
      # - `join`: receiver MUST be `Tuple[…]` with every element
      #   literal-string-compatible; the optional separator
      #   argument MUST also be literal-string-compatible.
      #   Result: `literal-string`. Empty `Tuple[]` lifts too —
      #   `[].join` is the empty string at runtime, which is
      #   literal-bearing trivially.
      #
      # Other receiver / argument shapes decline so the next tier
      # (ShapeDispatch / FileFolding / RbsDispatch) takes over and
      # the call site widens to the RBS-declared `Nominal[String]`
      # as before.
      module LiteralStringFolding
        module_function

        CONCAT_METHODS = %i[+ << concat].freeze
        private_constant :CONCAT_METHODS

        def try_dispatch(receiver:, method_name:, args:, **)
          return fold_array_join(receiver, args) if method_name == :join

          return nil unless Type::Combinator.literal_string_compatible?(receiver)
          return nil unless args.size == 1

          if CONCAT_METHODS.include?(method_name)
            fold_concat(args.first)
          elsif method_name == :*
            fold_repeat(args.first)
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

        # `[lit, lit].join(sep)` — receiver must be a Tuple
        # whose every element is literal-bearing; separator
        # (when given) must be literal-bearing too. Multi-arg
        # forms / `Array#join(*args)` splat shapes don't reach
        # here because the dispatcher only routes through this
        # tier when the call resolves to a single named method.
        def fold_array_join(receiver, args)
          return nil unless receiver.is_a?(Type::Tuple)
          return nil unless receiver.elements.all? { |el| Type::Combinator.literal_string_compatible?(el) }
          return nil unless args.size <= 1
          return nil if args.size == 1 && !Type::Combinator.literal_string_compatible?(args.first)

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

        private_class_method :fold_concat, :fold_repeat, :fold_array_join, :integer_typed?
      end
    end
  end
end
