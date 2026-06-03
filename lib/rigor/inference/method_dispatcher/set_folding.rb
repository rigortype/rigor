# frozen_string_literal: true

require_relative "../../type"
require_relative "singleton_folding"

module Rigor
  module Inference
    module MethodDispatcher
      # Folds `Set` constructor calls into `Constant[Set]` when all
      # arguments are statically known.
      #
      # Ruby 3.2+ implements Set in C (`set.c`). The constructor is
      # deterministic — it reads only its arguments and writes nothing
      # to global state.
      #
      # === Supported methods
      #
      # * `Set[]` — variadic constructor; each argument must be a
      #   `Constant[T]`. Returns `Constant[Set]`.
      # * `Set.new` — zero-argument form; returns `Constant[Set.new]`.
      # * `Set.new(tuple)` — the argument must be a `Tuple` whose
      #   every element is a `Constant[T]`. Returns `Constant[Set]`.
      #
      # === Non-constant / unsupported cases
      #
      # Returns `nil` (deferring to the next dispatcher tier) when:
      # - the receiver is not `Singleton[Set]`,
      # - the method is not `[]` or `new`,
      # - any argument is non-constant or structurally opaque.
      module SetFolding
        module_function

        # @return [Rigor::Type, nil] folded result, or nil to defer.
        def try_dispatch(receiver:, method_name:, args:)
          return nil unless SingletonFolding.receiver?(receiver, "Set")

          case method_name
          when :[] then fold_bracket(args)
          when :new then fold_new(args)
          end
        end

        # `Set["a", "b", "c"]` — all positional args must be Constant.
        def fold_bracket(args)
          values = args.map do |a|
            return nil unless a.is_a?(Type::Constant)

            a.value
          end

          Type::Combinator.constant_of(::Set.new(values))
        rescue StandardError
          nil
        end

        # `Set.new` / `Set.new(tuple_of_constants)`.
        def fold_new(args)
          return Type::Combinator.constant_of(::Set.new) if args.empty?
          return nil if args.size > 1

          arg = args.first
          values = case arg
                   when Type::Tuple
                     return nil unless arg.elements.all?(Type::Constant)

                     arg.elements.map(&:value)
                   else
                     return nil
                   end

          Type::Combinator.constant_of(::Set.new(values))
        rescue StandardError
          nil
        end
      end
    end
  end
end
