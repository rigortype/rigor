# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Folds `Regexp` module-function calls on statically known
      # string constants.
      #
      # `Regexp.escape(str)` / `Regexp.quote(str)` escapes regexp
      # meta-characters. The function is pure and deterministic —
      # the same input always produces the same output.
      #
      # === Supported methods
      #
      # * `escape(str)` / `quote(str)` — returns `Constant[String]`.
      #
      # === Non-constant / unsupported cases
      #
      # Returns `nil` (deferring to the next dispatcher tier) when:
      # - the receiver is not `Singleton[Regexp]`,
      # - the required argument is not a `Constant[String]`,
      # - the method is not in the supported set.
      module RegexpFolding
        REGEXP_ESCAPE_METHODS = Set[:escape, :quote].freeze
        private_constant :REGEXP_ESCAPE_METHODS

        module_function

        # @return [Rigor::Type, nil] folded result, or nil to defer.
        def try_dispatch(receiver:, method_name:, args:)
          return nil unless dispatch_target?(receiver)
          return nil unless REGEXP_ESCAPE_METHODS.include?(method_name)

          fold_escape(args)
        end

        def dispatch_target?(receiver)
          receiver.is_a?(Type::Singleton) && receiver.class_name == "Regexp"
        end

        # `Regexp.escape(str)` / `.quote(str)` — one String arg.
        def fold_escape(args)
          return nil unless args.size == 1

          arg = args.first
          return nil unless arg.is_a?(Type::Constant) && arg.value.is_a?(String)

          Type::Combinator.constant_of(Regexp.escape(arg.value))
        end
      end
    end
  end
end
