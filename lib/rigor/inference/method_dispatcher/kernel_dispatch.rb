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

        # `Kernel#p` / `Kernel#pp` return their argument: one argument comes back verbatim, several come
        # back as an Array of them, zero returns nil. The zero-arg form declines here (the RBS `nil` is
        # already exact); the 1-arg form is a precision-PRESERVING identity (the argument type passes
        # through unchanged — shapes, constants, and `Dynamic` alike); the n-arg form is a `Tuple`.
        IDENTITY_PRINTERS = Set[:p, :pp].freeze
        private_constant :IDENTITY_PRINTERS

        # Value classes `Kernel#String` folds over. Each is a literal-carrier class whose `to_s` is a
        # deterministic pure function of the value, so running the real `String()` at fold time is sound.
        STRING_SAFE_CLASSES = [
          String, Symbol, Integer, Float, Rational, Complex, NilClass, TrueClass, FalseClass
        ].freeze
        private_constant :STRING_SAFE_CLASSES

        def try_dispatch(context)
          receiver = context.receiver
          method_name = context.method_name
          args = context.args
          return nil if receiver.nil?
          return try_array(args) if method_name == :Array
          return try_numeric_constructor(method_name, args) if NUMERIC_CONSTRUCTORS.key?(method_name)
          return try_integer(args) if method_name == :Integer
          return try_float(args) if method_name == :Float
          return try_identity_printer(context) if IDENTITY_PRINTERS.include?(method_name)
          return try_string(context) if method_name == :String
          return try_hash(context) if method_name == :Hash

          nil
        end

        # `Kernel#p(x)` / `Kernel#pp(x)` identity typing. Runtime contract: `p x` returns `x`, `p a, b`
        # returns `[a, b]`, bare `p` returns nil. The 1-arg path returns the argument's type object
        # UNCHANGED — never widened, never concretized (a `Dynamic` argument stays `Dynamic`) — so a
        # `p`-wrapped expression is transparent to downstream inference. The n-arg path materialises the
        # positional types as a `Tuple`. The 0-arg path declines (RBS `nil` is already exact).
        #
        # FP envelope (shared guards): declines on a splat / forwarding argument (the runtime arity — and
        # hence 1-arg-identity vs n-arg-Array — is not statically known), and on any call
        # {#kernel_owned_call?} cannot attribute to Kernel itself.
        def try_identity_printer(context)
          args = context.args
          return nil if args.empty?
          return nil unless kernel_owned_call?(context)
          return nil if unresolved_argument_arity?(context.call_node)
          return args.first if args.size == 1

          Type::Combinator.tuple_of(*args)
        end

        # `Kernel#String(v)` — folds a value-pinned scalar `Constant` to `Constant[String]`
        # (`String(42)` → `"42"`, `String(nil)` → `""`). Restricted to {STRING_SAFE_CLASSES} so the fold
        # never models a user-defined `to_s` / `to_str`; anything else declines to the RBS `String`.
        def try_string(context)
          args = context.args
          return nil unless args.size == 1
          return nil unless kernel_owned_call?(context)
          return nil if unresolved_argument_arity?(context.call_node)

          arg = args.first
          return nil unless arg.is_a?(Type::Constant)
          return nil unless STRING_SAFE_CLASSES.any? { |klass| arg.value.instance_of?(klass) }

          Type::Combinator.constant_of(String(arg.value))
        rescue StandardError
          nil
        end

        # `Kernel#Hash(v)` — the trivially-sound slice only. A `HashShape` argument passes through
        # unchanged (`Hash(h)` returns `h` for a real Hash); `Hash(nil)` and `Hash([])` (an empty Tuple)
        # collapse to the empty `HashShape`. Arguments relying on the `to_hash` protocol are not decidable
        # from types alone and decline to the RBS envelope.
        def try_hash(context)
          args = context.args
          return nil unless args.size == 1
          return nil unless kernel_owned_call?(context)
          return nil if unresolved_argument_arity?(context.call_node)

          case (arg = args.first)
          when Type::HashShape then arg
          when Type::Constant then arg.value.nil? ? Type::Combinator.hash_shape_of({}) : nil
          when Type::Tuple then arg.elements.empty? ? Type::Combinator.hash_shape_of({}) : nil
          end
        end

        # True when the call can be attributed to Kernel's own module function. Kernel's surface is
        # PRIVATE, so a call with an explicit non-`self` receiver is necessarily a user-defined method —
        # decline. Likewise decline when the receiver class (or the toplevel) carries a discovered user
        # redefinition of the name (`def p(node)` in a printer class must not be hijacked by the fold;
        # the precise tiers run ahead of user-method inference). With no call_node / scope (internal
        # dispatcher callers, unit probes) the guards pass — the caller vouches for the shape.
        def kernel_owned_call?(context)
          !explicit_foreign_receiver?(context.call_node) && !user_redefined?(context)
        end

        def explicit_foreign_receiver?(call_node)
          return false if call_node.nil?

          receiver = call_node.receiver
          !(receiver.nil? || receiver.is_a?(Prism::SelfNode))
        end

        def user_redefined?(context)
          scope = context.scope
          return false if scope.nil?

          name = context.method_name
          return true if scope.top_level_def_for(name)

          case (receiver = context.receiver)
          when Type::Nominal then scope.discovered_method?(receiver.class_name, name, :instance)
          when Type::Singleton then scope.discovered_method?(receiver.class_name, name, :singleton)
          else false
          end
        end

        # True when the argument list carries a splat or an argument-forwarding node — the positional
        # arity (and therefore which fold shape applies) is not statically known. `nil` call_node
        # (internal callers) reads as resolved: the args array is authoritative there.
        def unresolved_argument_arity?(call_node)
          arguments = call_node&.arguments
          return false if arguments.nil?

          arguments.arguments.any? do |argument|
            argument.is_a?(Prism::SplatNode) || argument.is_a?(Prism::ForwardingArgumentsNode)
          end
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
