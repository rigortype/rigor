# frozen_string_literal: true

require_relative "../../type"
require_relative "singleton_folding"

module Rigor
  module Inference
    module MethodDispatcher
      # Folds `Regexp` class-method calls on statically known arguments.
      #
      # === Supported methods
      #
      # * `escape(str)` / `quote(str)` — escapes regexp meta-characters.
      #   Returns `Constant[String]`.
      # * `new(str)` / `new(str, opts)` — constructs a Regexp at fold time
      #   when the pattern argument is a `Constant[String]`. The optional
      #   second argument may be a `Constant[Integer]` (flag bits), a
      #   `Constant[true/false]` (IGNORECASE shorthand), or absent.
      #   Returns `Constant[Regexp]`.
      #
      # === Non-constant / unsupported cases
      #
      # Returns `nil` (deferring to the next dispatcher tier) when:
      # - the receiver is not `Singleton[Regexp]`,
      # - the required pattern argument is not a `Constant[String]`,
      # - the method is not in the supported set.
      module RegexpFolding
        REGEXP_ESCAPE_METHODS = Set[:escape, :quote].freeze
        private_constant :REGEXP_ESCAPE_METHODS

        module_function

        # @return [Rigor::Type, nil] folded result, or nil to defer.
        def try_dispatch(context)
          receiver = context.receiver
          method_name = context.method_name
          args = context.args
          return nil unless SingletonFolding.receiver?(receiver, "Regexp")
          return fold_escape(args) if REGEXP_ESCAPE_METHODS.include?(method_name)
          return fold_new(args) if method_name == :new

          nil
        end

        # `Regexp.escape(str)` / `.quote(str)` — one String arg.
        def fold_escape(args)
          return nil unless args.size == 1

          str = SingletonFolding.constant_string(args.first)
          return nil if str.nil?

          Type::Combinator.constant_of(Regexp.escape(str))
        end

        # `Regexp.new(pattern)` / `Regexp.new(pattern, opts)` — constructs
        # the pattern at inference time. Delegates to Ruby's real
        # `Regexp.new` so all option forms (Integer flags, `true`/`false`,
        # option strings) are handled without case-analysis; non-constant or
        # invalid arguments decline through to the RBS tier.
        def fold_new(args)
          return nil if args.empty? || args.size > 2

          pattern_arg = args.first
          return nil unless pattern_arg.is_a?(Type::Constant) &&
                            pattern_arg.value.is_a?(String)

          opts = args.size == 2 ? constant_value_or_nil(args[1]) : 0
          return nil if args.size == 2 && opts.nil?

          Type::Combinator.constant_of(Regexp.new(pattern_arg.value, opts))
        rescue StandardError
          nil
        end

        def constant_value_or_nil(type)
          type.is_a?(Type::Constant) ? type.value : nil
        end
      end
    end
  end
end
