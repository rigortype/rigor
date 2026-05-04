# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Block-shaped fold dispatch (v0.0.6 phase 1).
      #
      # Sits ahead of `RbsDispatch.try_dispatch` and folds a small
      # set of block-taking Enumerable methods when the inferred
      # block return type is a Ruby-truthy or Ruby-falsey
      # `Type::Constant`. The block-parameter typing for the same
      # methods continues to be answered by `IteratorDispatch`
      # (this module concerns the *return* of the call, not the
      # block-param binding).
      #
      # The methods covered fall in two families:
      #
      # - **Filter-shaped** (`select` / `filter` / `reject` /
      #   `take_while` / `drop_while`): the block's truthiness
      #   selects the all-or-nothing endpoints — either the
      #   receiver's full shape (when every element is kept) or
      #   the empty-tuple carrier (when every element is dropped).
      # - **Predicate-shaped** (`all?` / `any?` / `none?`): the
      #   block's truthiness combined with the receiver's
      #   emptiness collapses the call to a `Constant[bool]` in
      #   the cases where Ruby's actual semantics make it
      #   unconditional. Non-empty + truthy `any?` is `true`;
      #   non-empty + falsey `all?` is `false`; the empty-receiver
      #   "vacuous" answers (`[].all? { false } == true`,
      #   `[].any? { true } == false`, `[].none? { true } == true`)
      #   are likewise honoured.
      #
      # The dispatcher returns `nil` for any case that cannot be
      # decided from the (receiver-shape, method, block-truthiness)
      # tuple — element-wise block re-evaluation against
      # `Constant<Array>` receivers (the `map` / `filter_map` /
      # `flat_map` precision tier) is reserved for a later slice.
      module BlockFolding # rubocop:disable Metrics/ModuleLength
        module_function

        FILTER_KEEP_ON_TRUTHY = Set[:select, :filter, :take_while].freeze
        FILTER_KEEP_ON_FALSEY = Set[:reject, :drop_while].freeze

        PREDICATE_METHODS = Set[:all?, :any?, :none?].freeze

        # @param receiver    [Rigor::Type, nil]
        # @param method_name [Symbol]
        # @param args        [Array<Rigor::Type>]
        # @param block_type  [Rigor::Type, nil] inferred return type of
        #   the call's block. `nil` means "no block at the call site"
        #   and disqualifies every rule here.
        # @return [Rigor::Type, nil]
        def try_fold(receiver:, method_name:, args:, block_type:) # rubocop:disable Lint/UnusedMethodArgument
          return nil if receiver.nil? || block_type.nil?

          truthiness = constant_truthiness(block_type)
          return nil if truthiness.nil?

          if PREDICATE_METHODS.include?(method_name)
            fold_predicate(receiver, method_name, truthiness)
          elsif filter_method?(method_name)
            fold_filter(receiver, method_name, truthiness)
          end
        end

        def filter_method?(method_name)
          FILTER_KEEP_ON_TRUTHY.include?(method_name) ||
            FILTER_KEEP_ON_FALSEY.include?(method_name)
        end

        # Maps the block return type to `:truthy`, `:falsey`, or
        # `nil` (inconclusive). Only `Type::Constant` answers
        # decisively — `Union[true, false]`, `Nominal[…]`, or
        # `Dynamic[T]` keep the dispatcher silent so the RBS
        # tier still owns the call.
        def constant_truthiness(block_type)
          return nil unless block_type.is_a?(Type::Constant)

          block_type.value ? :truthy : :falsey
        end

        # Filter-shaped methods collapse to either the receiver
        # (every element kept) or the empty tuple (every element
        # dropped). Tuple-shaped receivers widen to
        # `Array[union of elements]` on the all-kept side because
        # we cannot prove WHICH positional subset survives —
        # Tuple's per-position semantics do not carry over to a
        # filtered Array.
        def fold_filter(receiver, method_name, truthiness)
          return nil unless filter_receiver_known?(receiver)

          keep_all = filter_keeps_all?(method_name, truthiness)
          keep_all ? receiver_as_kept_array(receiver) : Type::Combinator.tuple_of
        end

        def filter_keeps_all?(method_name, truthiness)
          (FILTER_KEEP_ON_TRUTHY.include?(method_name) && truthiness == :truthy) ||
            (FILTER_KEEP_ON_FALSEY.include?(method_name) && truthiness == :falsey)
        end

        def receiver_as_kept_array(receiver)
          case receiver
          when Type::Tuple then tuple_to_array(receiver)
          else receiver
          end
        end

        def tuple_to_array(tuple)
          return Type::Combinator.tuple_of if tuple.elements.empty?
          return Type::Combinator.nominal_of("Array", type_args: [tuple.elements.first]) if tuple.elements.size == 1

          element = Type::Combinator.union(*tuple.elements)
          Type::Combinator.nominal_of("Array", type_args: [element])
        end

        # Predicate folds. The decision table mirrors Ruby's
        # actual semantics on `Enumerable#all?` / `#any?` /
        # `#none?` — see the table at the top of the module.
        def fold_predicate(receiver, method_name, truthiness)
          emptiness = receiver_emptiness(receiver)
          decision = predicate_decision(method_name, truthiness, emptiness)
          return nil if decision.nil?

          case decision
          when :always_true  then Type::Combinator.constant_of(true)
          when :always_false then Type::Combinator.constant_of(false)
          when :bool         then bool_union
          end
        end

        # @return [:always_true, :always_false, :bool, nil]
        # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def predicate_decision(method_name, truthiness, emptiness)
          case method_name
          when :all?
            return :always_true if truthiness == :truthy
            return :always_true if emptiness == :empty
            return :always_false if emptiness == :non_empty

            :bool
          when :any?
            return :always_false if truthiness == :falsey
            return :always_true if emptiness == :non_empty
            return :always_false if emptiness == :empty

            :bool
          when :none?
            return :always_true if truthiness == :falsey
            return :always_false if emptiness == :non_empty
            return :always_true if emptiness == :empty

            :bool
          end
        end
        # rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        def bool_union
          Type::Combinator.union(
            Type::Combinator.constant_of(true),
            Type::Combinator.constant_of(false)
          )
        end

        # @return [:empty, :non_empty, :unknown]
        def receiver_emptiness(receiver)
          case receiver
          when Type::Tuple
            receiver.elements.empty? ? :empty : :non_empty
          when Type::HashShape
            receiver.pairs.empty? ? :empty : :non_empty
          when Type::Constant
            constant_emptiness(receiver.value)
          when Type::Difference
            difference_emptiness(receiver)
          else
            :unknown
          end
        end

        def constant_emptiness(value)
          case value
          when Array, Hash, String then value.empty? ? :empty : :non_empty
          when Range then range_emptiness(value)
          else :unknown
          end
        end

        def range_emptiness(range)
          beg = range.begin
          en  = range.end
          return :unknown unless beg.is_a?(Numeric) && en.is_a?(Numeric)

          if range.exclude_end?
            beg < en ? :non_empty : :empty
          else
            beg <= en ? :non_empty : :empty
          end
        end

        # `non-empty-array[T]` is encoded as
        # `Difference[Array[T], Tuple[]]` — the imported built-in
        # carrier for non-emptiness. Recognising it here lets
        # `arr.any? { true }` fold to `Constant[true]` for
        # callers who threaded the non-emptiness through their
        # type signature.
        def difference_emptiness(diff)
          base = diff.base
          removed = diff.removed
          return :unknown unless removed.is_a?(Type::Tuple) && removed.elements.empty?
          return :non_empty if array_or_hash_nominal?(base)

          :unknown
        end

        def array_or_hash_nominal?(type)
          type.is_a?(Type::Nominal) && %w[Array Hash Set].include?(type.class_name)
        end

        # Filter folds need at least a recognised collection
        # carrier; `Top` / `Dynamic` / arbitrary nominals decline
        # so the RBS tier answers (its `Array#select { … } -> Array[T]`
        # projection is correct, just less precise on the empty
        # endpoint).
        def filter_receiver_known?(receiver)
          case receiver
          when Type::Tuple, Type::HashShape, Type::Constant, Type::Difference then true
          when Type::Nominal then %w[Array Hash Set Range].include?(receiver.class_name)
          else false
          end
        end
      end
    end
  end
end
