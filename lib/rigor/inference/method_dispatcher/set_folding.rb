# frozen_string_literal: true

require_relative "../../type"
require_relative "singleton_folding"

module Rigor
  module Inference
    module MethodDispatcher
      # Folds `Set` constructor calls into `Constant[Set]` when all arguments are statically known.
      #
      # Ruby 3.2+ implements Set in C (`set.c`). The constructor is deterministic — it reads only its
      # arguments and writes nothing to global state.
      #
      # === Supported methods
      #
      # * `Set[]` — variadic constructor; each argument must be a `Constant[T]`. Returns `Constant[Set]`.
      # * `Set.new` — zero-argument form; returns `Constant[Set.new]`.
      # * `Set.new(tuple)` — the argument must be a `Tuple` whose every element is a `Constant[T]`. Returns
      #   `Constant[Set]`.
      #
      # === Non-constant / unsupported cases
      #
      # Returns `nil` (deferring to the next dispatcher tier) when:
      # - the receiver is not `Singleton[Set]`,
      # - the method is not `[]` or `new`,
      # - any argument is non-constant or structurally opaque.
      module SetFolding
        module_function

        # @return folded result, or nil to defer.
        def try_dispatch(context)
          receiver = context.receiver
          method_name = context.method_name
          args = context.args
          return nil unless SingletonFolding.receiver?(receiver, "Set")

          case method_name
          when :[] then fold_bracket(args, context.call_node)
          when :new then fold_new(args, context.call_node, context.block_type)
          end
        end

        # `Set["a", "b", "c"]` — all positional args must be Constant to fold to a value. Otherwise the
        # element type is the union of the arguments, widened off their literal pins (#2278).
        def fold_bracket(args, call_node = nil)
          return nil if splatted?(call_node)

          return Type::Combinator.constant_of(::Set.new(args.map(&:value))) if args.all?(Type::Constant)

          typed_set(args)
        rescue StandardError
          nil
        end

        # `Set.new` / `Set.new(enum)`. A call with a block declines: the block maps each element
        # (`Set.new([1, 2], &:to_s)` holds `"1"` and `"2"`), so the argument's elements are not the set's.
        def fold_new(args, call_node = nil, block_type = nil)
          return nil if block_type || block_given?(call_node) || splatted?(call_node)
          return Type::Combinator.constant_of(::Set.new) if args.empty?
          return nil if args.size > 1

          arg = args.first
          return fold_tuple(arg) if arg.is_a?(Type::Tuple)

          element = nominal_element(arg)
          element ? typed_set([element], widen: false) : nil
        rescue StandardError
          nil
        end

        def fold_tuple(tuple)
          if tuple.elements.all?(Type::Constant)
            return Type::Combinator.constant_of(::Set.new(tuple.elements.map(&:value)))
          end

          typed_set(tuple.elements)
        end

        # The element of an `Array[T]` / `Set[T]` argument, or nil for any other carrier.
        def nominal_element(arg)
          return nil unless arg.is_a?(Type::Nominal) && %w[Array Set].include?(arg.class_name)
          return nil unless arg.type_args.size == 1

          arg.type_args.first
        end

        # `Nominal[Set, [element]]`: a set is mutable, so the element is widened off value pins and literal
        # containers as an `Array.new` fill is, never pinned to what it was built with.
        def typed_set(types, widen: true)
          return nil if types.empty?

          members = widen ? types.map { |t| MethodDispatcher.array_new_element(t) } : types
          Type::Combinator.nominal_of("Set", type_args: [Type::Combinator.union(*members)])
        end

        def block_given?(call_node)
          call_node.respond_to?(:block) && !call_node.block.nil?
        end

        def splatted?(call_node)
          return false unless call_node.respond_to?(:arguments)

          (call_node.arguments&.arguments || []).any?(Prism::SplatNode)
        end
      end
    end
  end
end
