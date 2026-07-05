# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Shared helpers for the per-singleton folding tiers (CGI, URI, Shellwords, Math, Time, Regexp, Set,
      # File, …).
      #
      # Each of those tiers folds a pure module-/class-function call on `Constant` receivers, and every one
      # of them opens with the same two questions:
      #
      #   1. "Is the receiver the `Singleton[X]` I handle?" — a one-line
      #      `is_a?(Type::Singleton) && class_name == "X"` that used to be copied verbatim into nine
      #      modules.
      #   2. "Is this argument a foldable `Constant[String]`?" — the `is_a?(Type::Constant) &&
      #      value.is_a?(String)` unwrap the string-folding tiers (CGI / URI / Shellwords / Regexp) gate on
      #      before evaluating the literal.
      #
      # Centralising both here keeps the receiver-shape and constant-unwrap knowledge in one place: if
      # `Type::Singleton` or `Type::Constant` ever changes shape, there is a single edit rather than nine.
      # The per-tier fold bodies stay where they are — only the shared gate moves.
      module SingletonFolding
        module_function

        # True when `receiver` is the class/module singleton named `class_name` (e.g. `Singleton[Math]`).
        def receiver?(receiver, class_name)
          receiver.is_a?(Type::Singleton) && receiver.class_name == class_name
        end

        # The `String` value carried by a `Constant[String]` argument, or `nil` for any other carrier.
        # Callers fold when this is non-nil and decline (return nil, deferring to the RBS tier) otherwise.
        def constant_string(arg)
          return nil unless arg.is_a?(Type::Constant)

          value = arg.value
          value.is_a?(String) ? value : nil
        end
      end
    end
  end
end
