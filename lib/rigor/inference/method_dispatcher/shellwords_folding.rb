# frozen_string_literal: true

require "shellwords"
require_relative "../../type"
require_relative "singleton_folding"

module Rigor
  module Inference
    module MethodDispatcher
      # Folds `Shellwords` module-function calls on statically known
      # string constants.
      #
      # `Shellwords` is a pure, side-effect-free module whose functions
      # are deterministic over their inputs — the same string always
      # produces the same escaped / split / joined result. When all
      # relevant arguments are `Constant[String]` (or `Tuple` of them
      # for `join`), the analyzer can evaluate the call at inference
      # time and return the concrete `Constant<T>` result.
      #
      # === Supported methods
      #
      # * `escape` / `shellescape(str)` — returns `Constant[String]`.
      #   `Shellwords.escape("")` → `"''"`, so the result is always
      #   non-empty; callers that care about the `non-empty-string`
      #   refinement will get it for free once that carrier is wired
      #   to scalar-constant returns.
      #
      # * `split` / `shellsplit` / `shellwords(line)` — splits the
      #   shell command line into tokens, returns
      #   `Tuple[Constant[String], …]`. Raises `ArgumentError` on
      #   unmatched quotes; the handler declines (returns `nil`) so
      #   the RBS tier widens gracefully.
      #
      # * `join` / `shelljoin(array)` — joins an array of tokens into
      #   a shell-safe string. Requires a `Tuple` whose every element
      #   is a `Constant[String]`; returns `Constant[String]`.
      #
      # === Non-constant / unsupported cases
      #
      # Any call where:
      # - the receiver is not `Singleton[Shellwords]`,
      # - the required argument is not a `Constant[String]` (or
      #   `Tuple[Constant[String]…]` for `join`),
      # - the method is not in the supported set, or
      # - `Shellwords.split` raises on malformed input
      #
      # returns `nil`, deferring to the next dispatcher tier.
      module ShellwordsFolding
        SHELLWORDS_ESCAPE_METHODS = Set[:escape, :shellescape].freeze
        SHELLWORDS_SPLIT_METHODS  = Set[:split, :shellsplit, :shellwords].freeze
        SHELLWORDS_JOIN_METHODS   = Set[:join, :shelljoin].freeze
        SHELLWORDS_ALL_METHODS    = (
          SHELLWORDS_ESCAPE_METHODS | SHELLWORDS_SPLIT_METHODS | SHELLWORDS_JOIN_METHODS
        ).freeze

        # Maximum number of tokens `split` may produce before we
        # decline the fold (same rationale as STRING_ARRAY_LIFT_LIMIT
        # in ConstantFolding — keep the result Tuple manageable).
        SHELLWORDS_SPLIT_LIMIT = 64

        private_constant :SHELLWORDS_ESCAPE_METHODS, :SHELLWORDS_SPLIT_METHODS,
                         :SHELLWORDS_JOIN_METHODS, :SHELLWORDS_ALL_METHODS,
                         :SHELLWORDS_SPLIT_LIMIT

        module_function

        # @return [Rigor::Type, nil] folded result, or nil to defer.
        def try_dispatch(receiver:, method_name:, args:)
          return nil unless SingletonFolding.receiver?(receiver, "Shellwords")
          return nil unless SHELLWORDS_ALL_METHODS.include?(method_name)

          if SHELLWORDS_ESCAPE_METHODS.include?(method_name)
            fold_escape(args)
          elsif SHELLWORDS_SPLIT_METHODS.include?(method_name)
            fold_split(args)
          else
            fold_join(args)
          end
        end

        # `Shellwords.escape(str)` / `.shellescape(str)` — one String arg.
        def fold_escape(args)
          return nil unless args.size == 1

          str = SingletonFolding.constant_string(args.first)
          return nil if str.nil?

          Type::Combinator.constant_of(Shellwords.escape(str))
        end

        # `Shellwords.split(line)` / `.shellsplit` / `.shellwords` —
        # one String arg, result lifted to Tuple[Constant[String]…].
        def fold_split(args)
          return nil unless args.size == 1

          str = SingletonFolding.constant_string(args.first)
          return nil if str.nil?

          tokens = Shellwords.split(str)
          return nil if tokens.size > SHELLWORDS_SPLIT_LIMIT

          Type::Combinator.tuple_of(*tokens.map { |t| Type::Combinator.constant_of(t) })
        rescue ArgumentError
          # Unmatched quotes / invalid shell syntax — decline so the
          # RBS tier returns the widened Array[String] envelope.
          nil
        end

        # `Shellwords.join(array)` / `.shelljoin` — one Tuple arg
        # whose every element is `Constant[String]`.
        def fold_join(args)
          return nil unless args.size == 1

          arg = args.first
          return nil unless arg.is_a?(Type::Tuple)
          return nil unless arg.elements.all? { |e| e.is_a?(Type::Constant) && e.value.is_a?(String) }

          Type::Combinator.constant_of(Shellwords.join(arg.elements.map(&:value)))
        end
      end
    end
  end
end
