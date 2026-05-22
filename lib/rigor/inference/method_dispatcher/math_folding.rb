# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Folds `Math` module-function calls on statically known numeric
      # constants.
      #
      # `Math` is a pure, side-effect-free module whose functions are
      # deterministic over their inputs — the same number always
      # produces the same result. When every relevant argument is a
      # `Constant` carrying a `Numeric` value, the analyzer evaluates
      # the call at inference time and returns the concrete result.
      #
      # === Supported methods
      #
      # * Single-argument transcendental functions (`sqrt`, `cbrt`,
      #   `exp`, `log2`, `log10`, `log1p`, `expm1`, `sin`, `cos`,
      #   `tan`, `asin`, `acos`, `atan`, `sinh`, `cosh`, `tanh`,
      #   `asinh`, `acosh`, `atanh`, `erf`, `erfc`, `gamma`) — return
      #   `Constant[Float]`.
      #
      # * Two-argument functions (`atan2`, `hypot`, `ldexp`) — return
      #   `Constant[Float]`.
      #
      # * `log(x)` / `log(x, base)` — variadic; folds the 1- and
      #   2-argument forms to `Constant[Float]`.
      #
      # * `frexp(x)` / `lgamma(x)` — return a two-element array, lifted
      #   to `Tuple[Constant[Float], Constant[Integer]]`.
      #
      # === Non-constant / unsupported cases
      #
      # Any call where the receiver is not `Singleton[Math]`, an
      # argument is not a numeric `Constant`, the method is not in the
      # supported set, or the Ruby call raises `Math::DomainError` /
      # `RangeError` (domain-error inputs like `Math.sqrt(-1)`) returns
      # `nil`, deferring to the next dispatcher tier.
      #
      # An infinite or NaN result (`Math.log(0.0)` → `-Infinity`) is
      # still folded — `Constant[Float]` carries those values, matching
      # `ConstantFolding`'s treatment of `Float / 0`.
      module MathFolding
        MATH_UNARY = Set[
          :sqrt, :cbrt, :exp, :log2, :log10, :log1p, :expm1,
          :sin, :cos, :tan, :asin, :acos, :atan,
          :sinh, :cosh, :tanh, :asinh, :acosh, :atanh,
          :erf, :erfc, :gamma
        ].freeze
        MATH_BINARY = Set[:atan2, :hypot, :ldexp].freeze
        MATH_TUPLE_UNARY = Set[:frexp, :lgamma].freeze

        private_constant :MATH_UNARY, :MATH_BINARY, :MATH_TUPLE_UNARY

        module_function

        # @return [Rigor::Type, nil] folded result, or nil to defer.
        def try_dispatch(receiver:, method_name:, args:)
          return nil unless dispatch_target?(receiver)

          # `log` is variadic (1 or 2 args), so it cannot live in the
          # fixed-arity sets above.
          return fold_log(args) if method_name == :log
          return fold_unary(method_name, args) if MATH_UNARY.include?(method_name)
          return fold_binary(method_name, args) if MATH_BINARY.include?(method_name)
          return fold_tuple_unary(method_name, args) if MATH_TUPLE_UNARY.include?(method_name)

          nil
        end

        def dispatch_target?(receiver)
          receiver.is_a?(Type::Singleton) && receiver.class_name == "Math"
        end

        # Unwraps a numeric `Constant` argument to its Ruby value.
        # Returns nil for any non-`Constant` or non-`Numeric` carrier.
        def numeric_constant(arg)
          return nil unless arg.is_a?(Type::Constant)

          value = arg.value
          value.is_a?(Numeric) ? value : nil
        end

        def fold_unary(method_name, args)
          return nil unless args.size == 1

          x = numeric_constant(args.first)
          return nil if x.nil?

          fold_float_result(Math.public_send(method_name, x))
        rescue Math::DomainError, RangeError
          nil
        end

        def fold_binary(method_name, args)
          return nil unless args.size == 2

          a = numeric_constant(args[0])
          b = numeric_constant(args[1])
          return nil if a.nil? || b.nil?

          fold_float_result(Math.public_send(method_name, a, b))
        rescue Math::DomainError, RangeError
          nil
        end

        # `Math.log(x)` and `Math.log(x, base)` — the only variadic
        # `Math` function.
        def fold_log(args)
          return nil unless [1, 2].include?(args.size)

          values = args.map { |a| numeric_constant(a) }
          return nil if values.any?(&:nil?)

          fold_float_result(Math.log(*values))
        rescue Math::DomainError, RangeError
          nil
        end

        # `Math.frexp` / `Math.lgamma` return a two-element array;
        # lift it to `Tuple[Constant[Float], Constant[Integer]]`.
        def fold_tuple_unary(method_name, args)
          return nil unless args.size == 1

          x = numeric_constant(args.first)
          return nil if x.nil?

          result = Math.public_send(method_name, x)
          return nil unless result.is_a?(Array) && result.size == 2

          Type::Combinator.tuple_of(
            Type::Combinator.constant_of(result[0]),
            Type::Combinator.constant_of(result[1])
          )
        rescue Math::DomainError, RangeError
          nil
        end

        def fold_float_result(result)
          return nil unless result.is_a?(Float)

          Type::Combinator.constant_of(result)
        end
      end
    end
  end
end
