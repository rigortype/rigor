# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Kernel intrinsic shape-folding — precision tier for the
      # `Kernel` module-functions whose return type is a function
      # of the argument's *shape*, not just its class.
      #
      # Today the only catalogued intrinsic is `Kernel#Array`. The
      # default RBS sig is `Array(untyped) -> Array[untyped]`, which
      # collapses to `Array[Dynamic[top]]` for every caller. This
      # tier short-circuits with a precise answer when the argument's
      # type lattice tells us what the result element type MUST be:
      #
      #   Array(Constant[nil])         -> Array[bot]      # `[]`
      #   Array(Nominal["Array",[E]])  -> Array[E]        # already an Array
      #   Array(Tuple[T1,T2,…])        -> Array[T1|T2|…]
      #   Array(Union[A,B,…])          -> distribute, then unify
      #   Array(other Nominal[T])      -> Array[Nominal[T]]
      #
      # For receiver shapes we cannot prove (`Top`, `Dynamic`, …)
      # the tier returns nil and the RBS tier answers with the
      # generic `Array[untyped]` envelope.
      #
      # See `docs/type-specification/value-lattice.md` for the
      # union-distribution contract this tier mirrors.
      module KernelDispatch
        module_function

        # `Kernel#Rational` / `Kernel#Complex` constructor folds.
        # When every argument is a `Type::Constant` whose value is
        # numeric, we can run the actual Ruby constructor and lift
        # the result into a `Constant<Rational>` / `Constant<Complex>`.
        # The factory accepts the same shapes as Ruby:
        # `Rational(a)`, `Rational(a, b)`, `Complex(a)`, `Complex(a, b)`.
        NUMERIC_CONSTRUCTORS = {
          Rational: ->(*args) { Rational(*args) },
          Complex: ->(*args) { Complex(*args) }
        }.freeze
        private_constant :NUMERIC_CONSTRUCTORS

        def try_dispatch(receiver:, method_name:, args:)
          return nil if receiver.nil?
          return try_array(args) if method_name == :Array
          return try_numeric_constructor(method_name, args) if NUMERIC_CONSTRUCTORS.key?(method_name)

          nil
        end

        def try_array(args)
          return nil if args.length != 1

          element = element_type_of(args.first)
          return nil if element.nil?

          Type::Combinator.nominal_of("Array", type_args: [element])
        end

        # `Rational(int)` / `Rational(num, den)` and `Complex(re)`
        # / `Complex(re, im)` fold when every arg is a numeric
        # Constant. The actual Ruby constructor runs at fold time
        # (host-side), so the result respects Ruby's normalisation
        # (`Rational(2, 4)` → `Rational(1, 2)`).
        def try_numeric_constructor(method_name, args)
          return nil unless [1, 2].include?(args.size)
          return nil unless args.all? { |arg| numeric_constant?(arg) }

          values = args.map(&:value)
          result = NUMERIC_CONSTRUCTORS[method_name].call(*values)
          Type::Combinator.constant_of(result)
        rescue StandardError
          nil
        end

        def numeric_constant?(type)
          type.is_a?(Type::Constant) &&
            (type.value.is_a?(Integer) ||
              type.value.is_a?(Float) ||
              type.value.is_a?(Rational) ||
              type.value.is_a?(Complex))
        end

        # Computes the element type the argument contributes to the
        # `Array(arg)` result, mirroring Ruby's coercion contract:
        #
        # - `nil` becomes `[]` (element type Bot — the empty array
        #   contributes no inhabitants).
        # - An existing `Array[E]` is returned as-is, so its element
        #   type is `E`.
        # - A `Tuple[T1, T2, …]` is materialised as `Array[T1|T2|…]`
        #   (every tuple inhabitant is a tuple, hence Array-like).
        # - Any other value `v` becomes `[v]`, so the element type
        #   is the value's own type.
        #
        # Returns nil for receiver shapes the tier cannot prove
        # (Top, Dynamic, Bot in pre-coercion position) so the
        # caller falls back to the RBS-tier envelope.
        def element_type_of(type)
          case type
          when Type::Union
            distribute_over_union(type)
          when Type::Constant
            type.value.nil? ? Type::Combinator.bot : type
          when Type::Nominal
            array_element_or_self(type)
          when Type::Tuple
            tuple_element_union(type)
          end
        end

        def distribute_over_union(union)
          contributions = union.members.map { |member| element_type_of(member) }
          return nil if contributions.any?(&:nil?)

          Type::Combinator.union(*contributions)
        end

        def array_element_or_self(nominal)
          return nominal unless nominal.class_name == "Array"
          return Type::Combinator.untyped if nominal.type_args.empty?

          Type::Combinator.union(*nominal.type_args)
        end

        def tuple_element_union(tuple)
          return Type::Combinator.bot if tuple.elements.empty?

          Type::Combinator.union(*tuple.elements)
        end
      end
    end
  end
end
