# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Kernel intrinsic shape-folding — precision tier for the `Kernel` module-functions whose return type
      # is a function of the argument's *shape*, not just its class.
      #
      # Today the only catalogued intrinsic is `Kernel#Array`. The default RBS sig is
      # `Array(untyped) -> Array[untyped]`, which collapses to `Array[Dynamic[top]]` for every caller. This
      # tier short-circuits with a precise answer when the argument's type lattice tells us what the result
      # element type MUST be:
      #
      #   Array(Constant[nil])         -> Array[bot]      # `[]`
      #   Array(Nominal["Array",[E]])  -> Array[E]        # already an Array
      #   Array(Tuple[T1,T2,…])        -> Array[T1|T2|…]
      #   Array(Union[A,B,…])          -> distribute, then unify
      #   Array(other Nominal[T])      -> Array[Nominal[T]]
      #
      # For receiver shapes we cannot prove (`Top`, `Dynamic`, …) the tier returns nil and the RBS tier
      # answers with the generic `Array[untyped]` envelope.
      #
      # See `docs/type-specification/value-lattice.md` for the union-distribution contract this tier
      # mirrors.
      module KernelDispatch
        module_function

        # `Kernel#Rational` / `Kernel#Complex` constructor folds. When every argument is a `Type::Constant`
        # whose value is numeric, we can run the actual Ruby constructor and lift the result into a
        # `Constant<Rational>` / `Constant<Complex>`. The factory accepts the same shapes as Ruby:
        # `Rational(a)`, `Rational(a, b)`, `Complex(a)`, `Complex(a, b)`.
        NUMERIC_CONSTRUCTORS = Ractor.make_shareable({
                                                       Rational: Ractor.make_shareable(->(*args) { Rational(*args) }),
                                                       Complex: Ractor.make_shareable(->(*args) { Complex(*args) })
                                                     })
        private_constant :NUMERIC_CONSTRUCTORS

        # `Kernel#Integer(s)` predicate-aware refinement set (v0.1.1 Track 1 slice 2b). `decimal-int-string`
        # is the only string refinement whose every inhabitant `Integer(s)` parses without remainder, so
        # the result is a plain `Integer` — but NOT `non-negative-int`: the predicate `/\A-?\d+\z/` admits a
        # leading sign, so `"-7"` is a valid decimal-int-string and `Integer("-7") == -7 < 0`. The narrowing
        # is total (every inhabitant parses) but not `>= 0`, so it lands on `universal_int`.
        # `numeric-string` is deliberately NOT in this set at all: since it was widened to the full Ruby
        # numeric-literal grammar (floats, hex, rational, imaginary, signs), `Integer(numeric_string)` would
        # raise for a `"1.5"` / `"2i"` inhabitant — not even total — so it falls through to RBS `Integer`.
        # The `Integer(s, base)` overload is left for a later slice.
        INTEGER_REFINEMENT_PREDICATES = Set[:decimal_int].freeze
        private_constant :INTEGER_REFINEMENT_PREDICATES

        def try_dispatch(context)
          receiver = context.receiver
          method_name = context.method_name
          args = context.args
          return nil if receiver.nil?
          return try_array(args) if method_name == :Array
          return try_numeric_constructor(method_name, args) if NUMERIC_CONSTRUCTORS.key?(method_name)
          return try_integer(args) if method_name == :Integer
          return try_float(args) if method_name == :Float

          nil
        end

        # `Kernel#Integer(arg)` / `Integer(arg, base)`. Two folding paths, tried in order:
        #
        # 1. A `Refined[String, predicate]` argument whose predicate is a total-parse carrier narrows to
        #    `universal_int` (see {try_integer_from_refinement}).
        # 2. A `Constant` String or Numeric argument — optionally with a `Constant[Integer]` base — runs
        #    the actual `Integer()` conversion and lifts the result to `Constant[Integer]`.
        def try_integer(args)
          refined = try_integer_from_refinement(args)
          return refined if refined

          try_integer_constant(args)
        end

        # Constant-folding path for `Integer()`. A non-parseable string raises `ArgumentError` (or
        # `TypeError` for a base against a non-string) at fold time; the handler declines so the RBS tier
        # answers with the widened `Integer`.
        def try_integer_constant(args)
          return nil unless [1, 2].include?(args.size)
          return nil unless args.all?(Type::Constant)

          values = args.map(&:value)
          return nil unless values[0].is_a?(String) || values[0].is_a?(Numeric)
          return nil if values.size == 2 && !values[1].is_a?(Integer)

          Type::Combinator.constant_of(Integer(*values))
        rescue ArgumentError, TypeError
          nil
        end

        # `Kernel#Float(arg)` — folds a `Constant` String or Numeric argument to `Constant[Float]`. A
        # non-parseable string raises `ArgumentError` at fold time; the handler declines.
        def try_float(args)
          return nil unless args.size == 1

          arg = args.first
          return nil unless arg.is_a?(Type::Constant)

          value = arg.value
          return nil unless value.is_a?(String) || value.is_a?(Numeric)

          Type::Combinator.constant_of(Float(value))
        rescue ArgumentError, TypeError
          nil
        end

        # `Kernel#Integer(s)` over a `Refined[String, predicate]` whose predicate is in
        # {INTEGER_REFINEMENT_PREDICATES}. Mirrors the `String#to_i` projection in `ShapeDispatch` (v0.1.1
        # slice 2a) — the result is `universal_int`, NOT `non-negative-int`: a decimal-int-string admits a
        # leading sign (`"-7"`), so the parsed Integer can be negative. The carrier stays an `IntegerRange`
        # (rather than declining to the RBS `Nominal[Integer]`) so downstream range narrowing still has a
        # range to intersect. Returns nil for any other arg shape so the RBS tier handles the generic
        # `Integer(arg)` case.
        def try_integer_from_refinement(args)
          return nil unless args.size == 1

          arg = args.first
          return nil unless arg.is_a?(Type::Refined)

          base = arg.base
          return nil unless base.is_a?(Type::Nominal) && base.class_name == "String"
          return nil unless INTEGER_REFINEMENT_PREDICATES.include?(arg.predicate_id)

          Type::Combinator.universal_int
        end

        def try_array(args)
          return nil if args.length != 1

          element = element_type_of(args.first)
          return nil if element.nil?

          Type::Combinator.nominal_of("Array", type_args: [element])
        end

        # `Rational(int)` / `Rational(num, den)` and `Complex(re)` / `Complex(re, im)` fold when every arg
        # is a numeric Constant. The actual Ruby constructor runs at fold time (host-side), so the result
        # respects Ruby's normalisation (`Rational(2, 4)` → `Rational(1, 2)`).
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

        # Computes the element type the argument contributes to the `Array(arg)` result, mirroring Ruby's
        # coercion contract:
        #
        # - `nil` becomes `[]` (element type Bot — the empty array contributes no inhabitants).
        # - An existing `Array[E]` is returned as-is, so its element type is `E`.
        # - A `Tuple[T1, T2, …]` is materialised as `Array[T1|T2|…]` (every tuple inhabitant is a tuple,
        #   hence Array-like).
        # - Any other value `v` becomes `[v]`, so the element type is the value's own type.
        #
        # Returns nil for receiver shapes the tier cannot prove (Top, Dynamic, Bot in pre-coercion position)
        # so the caller falls back to the RBS-tier envelope.
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
