# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Iterator-style block-parameter typing.
      #
      # Sits ahead of `RbsDispatch.block_param_types` so the precise
      # integer bounds for `Integer#times` / `Integer#upto` /
      # `Integer#downto` reach the block body's parameter binder.
      # Without this tier the RBS signature for `Integer#times`
      # widens the index to `Nominal[Integer]`, dropping every
      # bound the receiver carries.
      #
      # Each rule mirrors Ruby's actual iteration semantics:
      #
      # - `n.times { |i| … }` yields `i ∈ [0, n-1]` when `n > 0`,
      #   nothing otherwise. The block-param type is therefore
      #   `int<0, n-1>` for a `Constant<Integer>` receiver,
      #   `int<0, upper-1>` for a finite `IntegerRange`, and
      #   `non_negative_int` for any unbounded-above shape.
      # - `a.upto(b) { |i| … }` yields `i ∈ [a, b]` when `a <= b`.
      #   Lower bound from the receiver, upper bound from the
      #   argument.
      # - `a.downto(b) { |i| … }` yields the same domain `[b, a]`,
      #   just iterated in reverse. Lower bound from the
      #   argument, upper bound from the receiver.
      module IteratorDispatch # rubocop:disable Metrics/ModuleLength
        module_function

        # @return [Array<Rigor::Type>, nil] block-param types, or
        #   nil to fall through to the next tier.
        def block_param_types(receiver:, method_name:, args:)
          case method_name
          when :times then times_block_params(receiver)
          when :upto  then upto_block_params(receiver, args.first)
          when :downto then downto_block_params(receiver, args.first)
          when :each_with_index then each_with_index_block_params(receiver)
          when :each_with_object then each_with_object_block_params(receiver, args.first)
          when :inject, :reduce then inject_block_params(receiver, args)
          end
        end

        def times_block_params(receiver)
          return nil unless integer_rooted?(receiver)

          upper = upper_bound_of(receiver)
          return [Type::Combinator.non_negative_int] unless upper.is_a?(Integer)
          return [Type::Combinator.non_negative_int] unless upper.positive?

          [build_index_range(0, upper - 1)]
        end

        def upto_block_params(receiver, end_arg)
          return nil unless integer_rooted?(receiver) && integer_rooted?(end_arg)

          [build_index_range(lower_bound_of(receiver), upper_bound_of(end_arg))]
        end

        def downto_block_params(receiver, end_arg)
          return nil unless integer_rooted?(receiver) && integer_rooted?(end_arg)

          [build_index_range(lower_bound_of(end_arg), upper_bound_of(receiver))]
        end

        # Generalised iterator: every Enumerable-shaped collection
        # in v0.0.4 yields `(element, index)` where the index is
        # always `non-negative-int`. The element comes from the
        # receiver's shape:
        #
        # - `Array[T]` / `Set[T]` / `Range[T]`              → T
        # - `Tuple[A, B, C]`                                → A | B | C
        #   (empty tuple cannot iterate, but we conservatively
        #   fall through to RBS so a missing rule never throws)
        # - `Hash[K, V]` / `HashShape{...}`                 → Tuple[K, V]
        #   (Ruby yields `[key, value]` pairs as the element)
        # - `Constant<Array>` / `Constant<Range>` / `Constant<Set>`
        #                                                   → corresponding Constant element
        #
        # Receivers we cannot project (Top, Dynamic, unknown
        # nominals, IO, …) decline so the RBS tier still answers
        # — its element type is correct, only the index would
        # widen to plain Integer.
        def each_with_index_block_params(receiver)
          element = element_type_of(receiver)
          return nil if element.nil?

          [element, Type::Combinator.non_negative_int]
        end

        # `each_with_object(memo) { |elem, memo_inner| … }` yields
        # `(element, memo)` where `memo` is the second argument's
        # type (passed by reference and threaded across iterations
        # at runtime — Rigor reflects that by binding the block's
        # second parameter to whatever the call site supplied).
        # When the call has no memo argument the dispatcher
        # declines so the user's RBS / overload selector decides.
        def each_with_object_block_params(receiver, memo_arg)
          return nil if memo_arg.nil?

          element = element_type_of(receiver)
          return nil if element.nil?

          [element, memo_arg]
        end

        # `inject(seed) { |memo, elem| … }` and `reduce` accept
        # three call shapes:
        #
        # - `(seed) { |memo, elem| … }` — block params `[seed, element]`.
        #   The memo's static type is the seed's; we cannot prove the
        #   block return type here without round-tripping through the
        #   block analyser, so the binding is the seed's type and
        #   downstream inference widens as needed.
        # - `() { |memo, elem| … }` — the first iteration uses the
        #   first element as the memo, so `[element, element]` is the
        #   sound binding.
        # - `(seed, :sym)` / `(:sym)` — Symbol method-name forms have
        #   no block. `inject` with a Symbol final arg is recognised
        #   and declined (returns nil) so the dispatcher does not
        #   pretend a block existed.
        def inject_block_params(receiver, args)
          element = element_type_of(receiver)
          return nil if element.nil?

          case args.size
          when 0
            [element, element]
          when 1
            seed = args.first
            return nil if symbol_constant?(seed)

            [seed, element]
          when 2
            # `inject(seed, :sym)` — Symbol-call form, no block.
            return nil if symbol_constant?(args[1])

            [args[0], element]
          end
        end

        def symbol_constant?(type)
          type.is_a?(Type::Constant) && type.value.is_a?(Symbol)
        end

        ELEMENT_BY_NOMINAL = {
          "Array" => :nominal_unary_element,
          "Set" => :nominal_unary_element,
          "Range" => :nominal_unary_element,
          "Hash" => :nominal_hash_pair_element
        }.freeze
        private_constant :ELEMENT_BY_NOMINAL

        def element_type_of(receiver)
          case receiver
          when Type::Tuple then tuple_element(receiver)
          when Type::HashShape then hash_shape_pair_element(receiver)
          when Type::Nominal then nominal_element(receiver)
          when Type::Constant then constant_element(receiver)
          end
        end

        def tuple_element(tuple)
          return nil if tuple.elements.empty?
          return tuple.elements.first if tuple.elements.size == 1

          Type::Combinator.union(*tuple.elements)
        end

        def hash_shape_pair_element(shape)
          return nil if shape.pairs.empty?

          key = Type::Combinator.union(*shape.pairs.keys.map { |k| Type::Combinator.constant_of(k) })
          value = Type::Combinator.union(*shape.pairs.values)
          Type::Combinator.tuple_of(key, value)
        end

        def nominal_element(nominal)
          handler = ELEMENT_BY_NOMINAL[nominal.class_name]
          return nil unless handler

          send(handler, nominal)
        end

        def nominal_unary_element(nominal)
          nominal.type_args.first
        end

        def nominal_hash_pair_element(nominal)
          key, value = nominal.type_args
          return nil if key.nil? || value.nil?

          Type::Combinator.tuple_of(key, value)
        end

        def constant_element(constant)
          case constant.value
          when Array
            return nil if constant.value.empty?

            Type::Combinator.union(*constant.value.map { |v| Type::Combinator.constant_of(v) })
          when Range
            range_constant_element(constant.value)
          end
        end

        def range_constant_element(range)
          beg = range.begin
          en  = range.end
          return Type::Combinator.constant_of(beg) if beg.is_a?(Integer) && beg == en

          if beg.is_a?(Integer) && en.is_a?(Integer)
            upper = range.exclude_end? ? en - 1 : en
            return build_index_range(beg, upper)
          end

          # Mixed / non-integer ranges decline: the dispatcher
          # falls through to RBS's element-type answer.
          nil
        end

        # `Constant<Integer>`, `IntegerRange`, and `Nominal[Integer]`
        # all participate. Non-integer types (Float, String, …) and
        # `Top`/`Dynamic` decline so the RBS tier answers.
        def integer_rooted?(type)
          case type
          when Type::Constant then type.value.is_a?(Integer)
          when Type::IntegerRange then true
          when Type::Nominal then type.class_name == "Integer" && type.type_args.empty?
          else false
          end
        end

        def lower_bound_of(type)
          case type
          when Type::Constant then type.value
          when Type::IntegerRange then type.min
          when Type::Nominal then Type::IntegerRange::NEG_INFINITY
          end
        end

        def upper_bound_of(type)
          case type
          when Type::Constant then type.value
          when Type::IntegerRange then type.max
          when Type::Nominal then Type::IntegerRange::POS_INFINITY
          end
        end

        # Builds a `Constant`/`IntegerRange` from possibly-symbolic
        # bounds. Vacuous ranges (lower > upper, indicating the
        # iterator does not fire) collapse to `non_negative_int` so
        # the body still type-checks against a sensible binding.
        def build_index_range(lower, upper)
          return Type::Combinator.non_negative_int if vacuous_range?(lower, upper)
          return Type::Combinator.constant_of(lower) if lower.is_a?(Integer) && lower == upper

          Type::Combinator.integer_range(lower, upper)
        end

        def vacuous_range?(lower, upper)
          return false if lower == Type::IntegerRange::NEG_INFINITY
          return false if upper == Type::IntegerRange::POS_INFINITY

          lower > upper
        end
      end
    end
  end
end
