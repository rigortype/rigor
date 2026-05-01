# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Slice 2 rule book that folds binary operations on `Rigor::Type::Constant`
      # receivers into another `Constant` whenever:
      #
      # * the receiver is a recognised scalar literal,
      # * exactly one argument is supplied and it is also a `Constant`,
      # * the method name is in the curated whitelist for the receiver's class,
      # * the operation cannot accidentally explode the analyzer (we cap
      #   string-fold output at `STRING_FOLD_BYTE_LIMIT` bytes), and
      # * the actual Ruby invocation does not raise.
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

        # @return [Rigor::Type::Constant, nil]
        def try_fold(receiver:, method_name:, args:)
          return nil unless receiver.is_a?(Type::Constant)

          case args.size
          when 0 then try_fold_unary(receiver, method_name)
          when 1 then try_fold_binary(receiver, method_name, args.first)
          end
        end

        def try_fold_binary(receiver, method_name, arg)
          return nil unless arg.is_a?(Type::Constant)
          return nil unless safe?(receiver.value, method_name, arg.value)

          Type::Combinator.constant_of(receiver.value.public_send(method_name, arg.value))
        rescue StandardError
          nil
        end

        # v0.0.3 C — zero-arg pure-unary fold. Returns a
        # `Constant` carrier, or `nil` when:
        # - the method is not in the receiver's pure-unary
        #   catalogue,
        # - invoking it raises (the catalogue is curated to
        #   minimise this; the rescue is a safety net),
        # - the result is a host object the analyzer should
        #   not surface as a `Constant` (e.g. an `Array` or
        #   `Proc` — those would need carrier-aware
        #   handling that the constant lattice does not
        #   model today). The post-result type guard caps
        #   the surface at scalar / String / Symbol values.
        def try_fold_unary(receiver, method_name)
          return nil unless unary_safe?(receiver.value, method_name)
          return nil if string_unary_blow_up?(receiver.value, method_name)

          result = receiver.value.public_send(method_name)
          return nil unless foldable_constant_value?(result)

          Type::Combinator.constant_of(result)
        rescue StandardError
          nil
        end

        def unary_safe?(receiver_value, method_name)
          unary_ops_for(receiver_value).include?(method_name)
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
          ops = ops_for(receiver_value)
          return false unless ops.include?(method_name)
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
