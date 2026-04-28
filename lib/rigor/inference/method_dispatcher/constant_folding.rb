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
      module ConstantFolding
        module_function

        NUMERIC_BINARY = Set[:+, :-, :*, :/, :%, :<, :<=, :>, :>=, :==, :!=, :<=>].freeze
        STRING_BINARY  = Set[:+, :*, :==, :!=, :<, :<=, :>, :>=, :<=>].freeze
        SYMBOL_BINARY  = Set[:==, :!=, :<=>, :<, :<=, :>, :>=].freeze
        BOOL_BINARY    = Set[:&, :|, :^, :==, :!=].freeze
        NIL_BINARY     = Set[:==, :!=].freeze

        STRING_FOLD_BYTE_LIMIT = 4096

        # @return [Rigor::Type::Constant, nil]
        def try_fold(receiver:, method_name:, args:)
          return nil unless receiver.is_a?(Type::Constant)
          return nil if args.size != 1

          arg = args.first
          return nil unless arg.is_a?(Type::Constant)
          return nil unless safe?(receiver.value, method_name, arg.value)

          Type::Combinator.constant_of(receiver.value.public_send(method_name, arg.value))
        rescue StandardError
          nil
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
