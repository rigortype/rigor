# frozen_string_literal: true

require_relative "../../type"
require_relative "../builtins/numeric_catalog"

module Rigor
  module Inference
    module MethodDispatcher
      # Slice 2 rule book that folds method calls on `Rigor::Type::Constant`
      # receivers (and unions of them) into another `Constant` (or a small
      # `Union[Constant, …]`) whenever:
      #
      # * the receiver is a recognised scalar literal, OR a `Union` whose
      #   members are all `Constant`,
      # * arguments (zero or one) are likewise `Constant` or `Union[Constant…]`,
      # * the method name is in the curated whitelist for the receiver's class,
      # * the operation cannot accidentally explode the analyzer (we cap
      #   string-fold output at `STRING_FOLD_BYTE_LIMIT` bytes, the input
      #   cartesian product at `UNION_FOLD_INPUT_LIMIT`, and the deduped
      #   output union at `UNION_FOLD_OUTPUT_LIMIT`), and
      # * the actual Ruby invocation does not raise on at least one
      #   receiver/argument combination.
      #
      # Anything else returns `nil`, signalling "no rule matched" so the
      # caller (`ExpressionTyper`) falls back to `Dynamic[Top]` and records a
      # fail-soft event. Slice 4 (RBS-backed) layers another dispatch tier
      # behind this rule book, but the constant-folding semantics defined
      # here MUST NOT regress: any value reachable by literal arithmetic at
      # parse time is meant to be foldable independent of RBS data.
      module ConstantFolding # rubocop:disable Metrics/ModuleLength
        module_function

        NUMERIC_BINARY = Set[:+, :-, :*, :/, :%, :<, :<=, :>, :>=, :==, :!=, :<=>].freeze
        STRING_BINARY  = Set[:+, :*, :==, :!=, :<, :<=, :>, :>=, :<=>].freeze
        SYMBOL_BINARY  = Set[:==, :!=, :<=>, :<, :<=, :>, :>=].freeze
        BOOL_BINARY    = Set[:&, :|, :^, :==, :!=].freeze
        NIL_BINARY     = Set[:==, :!=].freeze

        # v0.0.3 C — pure unary catalogue. Each method must:
        # - take zero arguments,
        # - have no side effects,
        # - never raise on the type's full domain (or be
        #   guarded by `safe?` below),
        # - return a value safe to materialise as a
        #   `Constant` (no large strings, no host objects).
        #
        # The catalogue is the prerequisite for aggressive
        # constant folding through user methods: once
        # `Constant[3].odd?` folds to `Constant[true]`, the
        # inter-procedural inference path landed in v0.0.2
        # #5 carries the constant through the body of a
        # user-defined `def is_odd(n) = n.odd?` so
        # `Parity.new.is_odd(3)` types as `Constant[true]`
        # rather than the RBS-widened `bool`.
        INTEGER_UNARY = Set[
          :odd?, :even?, :zero?, :positive?, :negative?,
          :succ, :pred, :next, :abs, :magnitude,
          :bit_length, :to_s, :to_i, :to_int, :to_f,
          :inspect, :hash, :-@, :+@, :~
        ].freeze
        FLOAT_UNARY = Set[
          :zero?, :positive?, :negative?,
          :nan?, :finite?, :infinite?,
          :abs, :magnitude, :floor, :ceil, :round, :truncate,
          :to_s, :to_i, :to_int, :to_f,
          :inspect, :hash, :-@, :+@
        ].freeze
        STRING_UNARY = Set[
          :upcase, :downcase, :capitalize, :swapcase,
          :reverse, :length, :size, :bytesize,
          :empty?, :strip, :lstrip, :rstrip, :chomp,
          :to_s, :to_str, :to_sym, :intern,
          :inspect, :hash
        ].freeze
        SYMBOL_UNARY = Set[
          :to_s, :to_sym, :to_proc, :length, :size,
          :empty?, :upcase, :downcase, :capitalize,
          :swapcase, :inspect, :hash
        ].freeze
        BOOL_UNARY = Set[:!, :to_s, :inspect, :hash, :&, :|, :^].freeze
        NIL_UNARY  = Set[:nil?, :!, :to_s, :to_a, :to_h, :inspect, :hash].freeze

        STRING_FOLD_BYTE_LIMIT = 4096

        # Input cartesian product hard cap. Keeps fold cost bounded even
        # when the receiver and argument are both `Union[Constant…]`.
        # 5 × 5 = 25 inputs is permitted; 6 × 6 = 36 is not. The user-
        # facing payoff (a precise small enum) drops off fast past this
        # range and CRuby method invocation cost adds up.
        UNION_FOLD_INPUT_LIMIT = 32

        # Output cardinality cap on the deduped result union. A single
        # binary op on a small range can collapse: `[1,2,3] + [2,4,6]`
        # produces 9 raw pairs but only 7 distinct sums. The output cap
        # is what ultimately limits how wide an inferred type gets.
        UNION_FOLD_OUTPUT_LIMIT = 8

        # @return [Rigor::Type::Constant, Rigor::Type::Union, Rigor::Type::IntegerRange, nil]
        def try_fold(receiver:, method_name:, args:)
          receiver_set = numeric_set_of(receiver)
          return nil unless receiver_set

          arg_sets = args.map { |a| numeric_set_of(a) }
          return nil if arg_sets.any?(&:nil?)

          case args.size
          when 0 then try_fold_unary(receiver_set, method_name)
          when 1 then try_fold_binary(receiver_set, method_name, arg_sets.first)
          end
        end

        # Normalises an input type into one of:
        # - `Array<Object>` for a `Constant` (1-element) or
        #   `Union[Constant…]` (n-element) — concrete values to enumerate.
        # - `Type::IntegerRange` — bounded interval.
        # - `nil` — the input shape is not foldable.
        def numeric_set_of(type)
          case type
          when Type::Constant then [type.value]
          when Type::Union
            return nil unless type.members.all?(Type::Constant)

            type.members.map(&:value)
          when Type::IntegerRange then type
          end
        end

        def try_fold_unary(set, method_name)
          case set
          when Array              then try_fold_unary_set(set, method_name)
          when Type::IntegerRange then try_fold_unary_range(set, method_name)
          end
        end

        def try_fold_binary(left, method_name, right)
          return try_fold_divmod(left, right) if method_name == :divmod

          if left.is_a?(Type::IntegerRange) || right.is_a?(Type::IntegerRange)
            try_fold_binary_range(left, method_name, right)
          else
            try_fold_binary_set(left, method_name, right)
          end
        end

        # `Integer#divmod` and `Float#divmod` return a 2-element array
        # `[quotient, remainder]`. We project that into
        # `Tuple[Constant[q], Constant[r]]` so downstream rules see
        # the precise element types. Union/range receivers are
        # widened per-position: each tuple slot carries the union of
        # quotients (resp. remainders) over every safe input pair.
        # Range inputs are not yet folded — they bail to nil.
        def try_fold_divmod(left, right)
          pairs = collect_divmod_pairs(left, right)
          return nil unless pairs && !pairs.empty?

          q_type = build_constant_type(pairs.map(&:first))
          r_type = build_constant_type(pairs.map(&:last))
          return nil unless q_type && r_type

          Type::Combinator.tuple_of(q_type, r_type)
        end

        def collect_divmod_pairs(left, right)
          return nil unless left.is_a?(Array) && right.is_a?(Array)
          return nil if left.size * right.size > UNION_FOLD_INPUT_LIMIT

          left.flat_map do |lv|
            right.flat_map { |rv| invoke_divmod(lv, rv) || [] }
          end
        end

        # Returns `[[quotient, remainder]]` (single-element array
        # wrapping the tuple) on success; `nil` to signal "skip this
        # pair". The wrapping mirrors `invoke_binary` so we can
        # use `flat_map` and not lose legitimate 0/false elements.
        def invoke_divmod(receiver_value, arg_value)
          return nil unless receiver_value.is_a?(Numeric) && arg_value.is_a?(Numeric)

          result = receiver_value.divmod(arg_value)
          divmod_result_to_pair(result)
        rescue StandardError
          nil
        end

        def divmod_result_to_pair(result)
          return nil unless result.is_a?(Array) && result.size == 2
          return nil unless result.all? { |v| foldable_constant_value?(v) }

          [result]
        end

        def try_fold_unary_set(receiver_values, method_name)
          results = receiver_values.flat_map do |rv|
            invoke_unary(rv, method_name) || []
          end
          build_constant_type(results, source: receiver_values)
        end

        def try_fold_binary_set(receiver_values, method_name, arg_values)
          return nil if receiver_values.size * arg_values.size > UNION_FOLD_INPUT_LIMIT

          results = receiver_values.flat_map do |rv|
            arg_values.flat_map { |av| invoke_binary(rv, method_name, av) || [] }
          end
          build_constant_type(results, source: receiver_values + arg_values)
        end

        # Builds a Constant or Union[Constant…] from a flat list of
        # Ruby values. When the deduped set exceeds
        # `UNION_FOLD_OUTPUT_LIMIT` and every result is an Integer,
        # widens to the bounding `IntegerRange` instead of returning
        # nil — that is the graceful escape valve for additions over
        # disjoint integer ranges. The `source` array is used only as
        # a hint that the result set's "Integer-ness" was already
        # implied by the inputs (so the widening fallback only fires
        # for arithmetic over integers).
        def build_constant_type(values, source: nil)
          return nil if values.empty?

          unique = values.uniq
          return collapse_constants(unique) if unique.size <= UNION_FOLD_OUTPUT_LIMIT

          widen_to_integer_range(unique, source) ||
            (raise_if_strict || nil)
        end

        def collapse_constants(values)
          constants = values.map { |v| Type::Combinator.constant_of(v) }
          constants.size == 1 ? constants.first : Type::Combinator.union(*constants)
        end

        # Widening fallback: when every successful result is an
        # Integer, return the bounding `IntegerRange` rather than
        # losing the answer entirely. The fallback is also gated on
        # the input set being all-integers, so a fold whose results
        # happen to land on integers but whose receivers were Floats
        # does not silently change shape.
        def widen_to_integer_range(values, source)
          return nil unless values.all?(Integer)
          return nil if source && !source.all? { |v| v.is_a?(Integer) || v.is_a?(Type::IntegerRange) }

          Type::Combinator.integer_range(values.min, values.max)
        end

        # Reserved hook: present so future `:strict` modes can raise
        # rather than silently returning nil. Today it always returns
        # nil so behaviour is unchanged.
        def raise_if_strict
          nil
        end

        # ----------------------------------------------------------------
        # IntegerRange arithmetic and comparison.
        # ----------------------------------------------------------------

        RANGE_ADDITIVE = Set[:+, :-].freeze
        RANGE_COMPARISON = Set[:<, :<=, :>, :>=, :==, :!=].freeze

        # Per-operator dispatch table for binary range ops. Each
        # value is a method symbol on `ConstantFolding` taking
        # `(left, right)` and returning a `Type` or `nil`.
        BINARY_RANGE_HANDLERS = {
          :* => :range_multiply,
          :/ => :range_divide,
          :% => :range_modulo
        }.freeze
        private_constant :BINARY_RANGE_HANDLERS

        def try_fold_binary_range(left, method_name, right)
          l = ensure_integer_range(left)
          r = ensure_integer_range(right)
          return nil unless l && r
          return range_additive(l, method_name, r) if RANGE_ADDITIVE.include?(method_name)
          return range_comparison(l, method_name, r) if RANGE_COMPARISON.include?(method_name)
          return send(BINARY_RANGE_HANDLERS[method_name], l, r) if BINARY_RANGE_HANDLERS.key?(method_name)

          nil
        end

        # Promotes an array-of-values input to an `IntegerRange` when
        # every value is an `Integer`. Used so a mixed `Constant +
        # IntegerRange` call can be reduced to range × range
        # arithmetic. Returns `nil` for non-Integer arrays so a
        # `Constant[Float]` does not silently degrade.
        def ensure_integer_range(operand)
          case operand
          when Type::IntegerRange then operand
          when Array
            return nil unless operand.all?(Integer)

            Type::Combinator.integer_range(operand.min, operand.max)
          end
        end

        def range_additive(left, method_name, right)
          lower, upper =
            case method_name
            when :+ then [left.lower + right.lower, left.upper + right.upper]
            when :- then [left.lower - right.upper, left.upper - right.lower]
            end
          build_integer_range(lower, upper)
        end

        # Range × Range. Computes the four corner products with
        # `safe_mul` so that `0 × ±∞` is treated as 0 rather than
        # NaN — that captures the algebraic truth that the actual
        # range elements are integers, never literal infinity.
        def range_multiply(left, right)
          corners = [
            safe_mul(left.lower, right.lower),
            safe_mul(left.lower, right.upper),
            safe_mul(left.upper, right.lower),
            safe_mul(left.upper, right.upper)
          ]
          build_integer_range(corners.min, corners.max)
        end

        # 0 dominates: 0 × anything (including ±∞) is 0. Without this
        # special case Ruby's `0 * Float::INFINITY` is `NaN`, which
        # would corrupt `min`/`max`.
        def safe_mul(left, right)
          return 0 if left.zero? || right.zero?

          left * right
        end

        # Range ÷ Range using Ruby's integer floor division. If the
        # right range covers 0 the operation may raise
        # `ZeroDivisionError`, so the fold bails (caller falls back
        # to RBS-widened `Integer`). When both inputs are finite we
        # compute the four corner quotients; the universal-on-one-side
        # case is handled by treating ±∞ ÷ n as ±∞ and n ÷ ±∞ as 0.
        def range_divide(left, right)
          return nil if right.covers?(0)

          corners = [
            safe_div(left.lower, right.lower),
            safe_div(left.lower, right.upper),
            safe_div(left.upper, right.lower),
            safe_div(left.upper, right.upper)
          ]
          build_integer_range(corners.min, corners.max)
        end

        def safe_div(numer, denom)
          return 0 if numer.zero?
          return numer.positive? ^ denom.negative? ? Float::INFINITY : -Float::INFINITY if denom.zero?
          return 0 if denom.infinite?

          if numer.infinite?
            return numer.positive? ^ denom.negative? ? Float::INFINITY : -Float::INFINITY
          end

          numer.to_i.div(denom.to_i).to_f
        end

        # Range % Range. Only the `(any range) % (positive constant n)`
        # and `(any range) % (negative constant n)` cases are folded
        # precisely — the former narrows to `int<0, n-1>`, the latter
        # to `int<n+1, 0>`. Other shapes fall back to nil.
        def range_modulo(_left, right)
          return nil unless right.finite? && right.min == right.max

          divisor = right.min
          return nil if divisor.zero?

          if divisor.positive?
            build_integer_range(0, divisor - 1)
          else
            build_integer_range(divisor + 1, 0)
          end
        end

        # Builds an `IntegerRange` from numeric `lower`/`upper`
        # endpoints. Collapses single-point finite ranges to a
        # `Constant` so downstream rules (which prefer the more
        # specific carrier) see the most precise result.
        def build_integer_range(lower, upper)
          min = lower == -Float::INFINITY ? Type::IntegerRange::NEG_INFINITY : Integer(lower)
          max = upper == Float::INFINITY ? Type::IntegerRange::POS_INFINITY : Integer(upper)
          if min.is_a?(Integer) && max.is_a?(Integer) && min == max
            Type::Combinator.constant_of(min)
          else
            Type::Combinator.integer_range(min, max)
          end
        end

        def range_comparison(left, method_name, right)
          decision = decide_range_comparison(left, method_name, right)
          case decision
          when :always_true  then Type::Combinator.constant_of(true)
          when :always_false then Type::Combinator.constant_of(false)
          when :both         then bool_union
          end
        end

        def bool_union
          Type::Combinator.union(
            Type::Combinator.constant_of(true),
            Type::Combinator.constant_of(false)
          )
        end

        BOOL_INVERSE = {
          always_true: :always_false,
          always_false: :always_true,
          both: :both
        }.freeze
        private_constant :BOOL_INVERSE

        def decide_range_comparison(left, method_name, right)
          case method_name
          when :<  then decide_lt(left, right)
          when :<= then decide_le(left, right)
          when :>  then decide_lt(right, left)
          when :>= then decide_le(right, left)
          when :== then decide_eq(left, right)
          when :!= then BOOL_INVERSE[decide_eq(left, right)]
          end
        end

        def decide_lt(left, right)
          return :always_true if left.upper < right.lower
          return :always_false if left.lower >= right.upper

          :both
        end

        def decide_le(left, right)
          return :always_true if left.upper <= right.lower
          return :always_false if left.lower > right.upper

          :both
        end

        def decide_eq(left, right)
          return :always_true if left.finite? && right.finite? && left.min == left.max && left == right
          return :always_false if left.upper < right.lower || right.upper < left.lower

          :both
        end

        # ----------------------------------------------------------------
        # IntegerRange unary folds.
        # ----------------------------------------------------------------

        RANGE_UNARY_PREDICATES = Set[:zero?, :positive?, :negative?].freeze
        RANGE_UNARY_SHIFTS = Set[:succ, :next, :pred].freeze
        RANGE_UNARY_PARITY = Set[:even?, :odd?].freeze

        # `(method_name) -> handler symbol` for the unary range
        # surface that does not need extra context. The grouped
        # categories (predicates / shifts / parity) stay separate
        # because they share dispatch logic.
        UNARY_RANGE_DIRECT = {
          abs: :range_unary_abs,
          magnitude: :range_unary_abs,
          "-@": :range_unary_negate,
          "+@": :range_unary_identity,
          bit_length: :range_unary_bit_length
        }.freeze
        private_constant :UNARY_RANGE_DIRECT

        def try_fold_unary_range(range, method_name)
          return range_unary_predicate(range, method_name) if RANGE_UNARY_PREDICATES.include?(method_name)
          return range_unary_shift(range, method_name) if RANGE_UNARY_SHIFTS.include?(method_name)
          return range_unary_parity(range, method_name) if RANGE_UNARY_PARITY.include?(method_name)
          return send(UNARY_RANGE_DIRECT[method_name], range) if UNARY_RANGE_DIRECT.key?(method_name)

          nil
        end

        def range_unary_negate(range)
          build_integer_range(-range.upper, -range.lower)
        end

        def range_unary_identity(range)
          range
        end

        # `even?`/`odd?` on a single-point range collapses to an
        # exact `Constant[bool]`. Any range spanning ≥ 2 integers
        # contains both an even and an odd value, so the result is
        # `Union[true, false]`.
        def range_unary_parity(range, method_name)
          if range.finite? && range.min == range.max
            value = range.min.public_send(method_name)
            Type::Combinator.constant_of(value)
          else
            bool_union
          end
        end

        # Integer#bit_length is non-negative and bounded by the
        # bit_length of the wider endpoint. For half-open ranges the
        # upper bound is unknown (any large integer is reachable), so
        # we widen to non_negative_int. Negative endpoints map via
        # `~n` semantics; using the magnitude is a safe upper bound.
        def range_unary_bit_length(range)
          return Type::Combinator.non_negative_int unless range.finite?

          width = [range.min.bit_length, range.max.bit_length].max
          build_integer_range(0, width)
        end

        def range_unary_predicate(range, method_name)
          decision =
            case method_name
            when :zero?     then decide_zero(range)
            when :positive? then decide_positive(range)
            when :negative? then decide_negative(range)
            end
          range_comparison_result(decision)
        end

        def range_comparison_result(decision)
          case decision
          when :always_true  then Type::Combinator.constant_of(true)
          when :always_false then Type::Combinator.constant_of(false)
          when :both         then bool_union
          end
        end

        def decide_zero(range)
          return :always_true if range.finite? && range.min.zero? && range.max.zero?
          return :always_false unless range.covers?(0)

          :both
        end

        def decide_positive(range)
          return :always_true if range.lower.positive?
          return :always_false if range.upper <= 0

          :both
        end

        def decide_negative(range)
          return :always_true if range.upper.negative?
          return :always_false if range.lower >= 0

          :both
        end

        def range_unary_shift(range, method_name)
          delta = method_name == :pred ? -1 : 1
          build_integer_range(range.lower + delta, range.upper + delta)
        end

        def range_unary_abs(range)
          if range.lower >= 0
            range
          elsif range.upper <= 0
            build_integer_range(-range.upper, -range.lower)
          else
            magnitude = [range.lower.abs, range.upper.abs].max
            build_integer_range(0, magnitude)
          end
        end

        # ----------------------------------------------------------------

        # Returns `[value]` on success, `nil` to signal "skip this pair".
        # The 1-element-array shape lets callers distinguish a successful
        # `false`/`nil` fold from a skipped pair when chaining via
        # `flat_map`.
        def invoke_binary(receiver_value, method_name, arg_value)
          return nil unless safe?(receiver_value, method_name, arg_value)

          result = receiver_value.public_send(method_name, arg_value)
          foldable_constant_value?(result) ? [result] : nil
        rescue StandardError
          nil
        end

        # Returns `[value]` on success, `nil` to signal "skip". See
        # `invoke_binary` for why we wrap.
        def invoke_unary(receiver_value, method_name)
          return nil unless unary_safe?(receiver_value, method_name)
          return nil if string_unary_blow_up?(receiver_value, method_name)

          result = receiver_value.public_send(method_name)
          foldable_constant_value?(result) ? [result] : nil
        rescue StandardError
          nil
        end

        def unary_safe?(receiver_value, method_name)
          return true if unary_ops_for(receiver_value).include?(method_name)

          catalog_allows?(receiver_value, method_name)
        end

        # Consults the offline numeric catalog (data/builtins/ruby_core/
        # numeric.yml) as a superset of the hand-rolled unary/binary
        # allow lists. The catalog's `leaf` / `trivial` /
        # `leaf_when_numeric` entries promise the underlying CRuby
        # implementation does not call back into user-redefinable
        # Ruby methods, so executing them on a literal Integer/Float
        # is safe regardless of monkey-patching.
        def catalog_allows?(receiver_value, method_name)
          class_name = catalog_class_for(receiver_value)
          return false unless class_name

          Builtins::NumericCatalog.safe_for_folding?(class_name, method_name)
        end

        def catalog_class_for(receiver_value)
          case receiver_value
          when Integer then "Integer"
          when Float   then "Float"
          end
        end

        def unary_ops_for(receiver_value)
          case receiver_value
          when Integer        then INTEGER_UNARY
          when Float          then FLOAT_UNARY
          when String         then STRING_UNARY
          when Symbol         then SYMBOL_UNARY
          when true, false    then BOOL_UNARY
          when nil            then NIL_UNARY
          else                     Set.new
          end
        end

        # `String#reverse` / `#swapcase` etc. produce a
        # string the same size as the receiver; only the
        # already-handled binary `:+` / `:*` paths can
        # explode the output. No unary string method
        # currently in the catalogue grows beyond the input
        # size, so this hook is a no-op today — kept as a
        # placeholder so future additions (e.g. `:succ` on
        # very long strings) can be guarded without
        # restructuring.
        def string_unary_blow_up?(_receiver_value, _method_name)
          false
        end

        # Scalar / String / Symbol values fold; everything
        # else (Array, Hash, Proc, Range, ...) is held back
        # because `Type::Constant` does not model those
        # carriers and surfacing one would mis-type
        # downstream calls. `Range`, `Array`, and friends
        # have their own shape carriers; this method picks
        # the conservative envelope of "values that already
        # round-trip through `Type::Combinator.constant_of`".
        def foldable_constant_value?(value)
          case value
          when Integer, Float, String, Symbol, true, false, nil then true
          else false
          end
        end

        def safe?(receiver_value, method_name, arg_value)
          allowed = ops_for(receiver_value).include?(method_name) ||
                    catalog_allows?(receiver_value, method_name)
          return false unless allowed
          return false if integer_division_by_zero?(receiver_value, method_name, arg_value)
          return false if string_blow_up?(receiver_value, method_name, arg_value)

          true
        end

        def ops_for(receiver_value)
          case receiver_value
          when Integer, Float then NUMERIC_BINARY
          when String         then STRING_BINARY
          when Symbol         then SYMBOL_BINARY
          when true, false    then BOOL_BINARY
          when nil            then NIL_BINARY
          else                     Set.new
          end
        end

        # Integer / 0 and Integer % 0 raise; Float / 0 and Float / 0.0 return
        # Float::INFINITY or NaN, which are valid `Constant[Float]` values.
        def integer_division_by_zero?(receiver_value, method_name, arg_value)
          return false unless %i[/ %].include?(method_name)
          return false unless receiver_value.is_a?(Integer)

          arg_value.is_a?(Integer) && arg_value.zero?
        end

        def string_blow_up?(receiver_value, method_name, arg_value)
          return false unless receiver_value.is_a?(String)

          case method_name
          when :+ then string_concat_blow_up?(receiver_value, arg_value)
          when :* then string_repeat_blow_up?(receiver_value, arg_value)
          else false
          end
        end

        def string_concat_blow_up?(receiver_value, arg_value)
          arg_value.is_a?(String) &&
            receiver_value.bytesize + arg_value.bytesize > STRING_FOLD_BYTE_LIMIT
        end

        def string_repeat_blow_up?(receiver_value, arg_value)
          return false unless arg_value.is_a?(Integer)
          return true if arg_value.negative?

          receiver_value.bytesize * arg_value > STRING_FOLD_BYTE_LIMIT
        end
      end
    end
  end
end
