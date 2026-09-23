# frozen_string_literal: true

require "prism"

require_relative "mutation_widening"

module Rigor
  module Inference
    # `h[k] ||= v`, `h[k] &&= v` and `h[k] += v` store through `[]=`, but Prism gives each its own node class rather
    # than a `[]=` `CallNode`. None of them therefore reached {MutationWidening.widen_after_call}, and a literal-shape
    # binding outlived its justification: an `@h = {}` written only through `@h[k] ||= {}` kept its empty `HashShape`,
    # so `@h.empty?` folded to `Constant[true]` and `return nil if x.nil? || @h.empty?` drew a false
    # `flow.always-truthy-condition` on a hash the class fills.
    #
    # Two consumers need the same recognition and neither had it: {StatementEvaluator} for the straight-line write, and
    # {ScopeIndexer}'s class-ivar pre-pass for the cross-method one (an ivar written in `add` and read in `probe`).
    # `||=` / `&&=` are conditional at runtime, but a widening may only LOSE precision, so answering on the branch that
    # does not store is safe.
    #
    # `Prism::IndexTargetNode` stores through `[]=` too, but it is absent from {NODE_CLASSES}: it is a TARGET, and the
    # value it stores comes from the construct that owns it — a multi-assign slot (`h[:a], z = 1, 2`), a `for` index
    # (`for h[:a] in xs`, alone, splatted or in a multi-target) or a rescue reference (`rescue => h[:e]`). Only that
    # construct can type the value, so `StatementEvaluator#eval_multi_write`, `#bind_for_index` and
    # `#bind_rescue_reference` observe the straight-line write, passing each target to {.widen} with the slot
    # {MultiTargetBinder} decomposed for it, the element or the rescued exception. {CONTENT_WRITE_NODE_CLASSES} adds
    # it for the nested-block write-back, and `ScopeIndexer`'s pre-pass, which needs no stored value, names the class
    # next to {NODE_CLASSES}.
    module IndexWriteWidening
      NODE_CLASSES = [Prism::IndexOrWriteNode, Prism::IndexAndWriteNode, Prism::IndexOperatorWriteNode].freeze

      # Every node that stores through `[]=` without being a `[]=` call: {NODE_CLASSES} plus the index TARGET a
      # multi-assign, `rescue =>` or `for` writes through. `StatementEvaluator`'s captured-local write-back widens
      # a receiver a nested block stores into through any of them, `ExpressionTyper`'s block-return threading
      # gate predicts that widening, and `CapturedLocals.content_mutations` finds the per-element fold's in-place
      # captures by it, so all three read this one list.
      CONTENT_WRITE_NODE_CLASSES = [*NODE_CLASSES, Prism::IndexTargetNode].freeze

      # The method these forms store through — the name the mutator tables are keyed on.
      MUTATOR = :[]=

      module_function

      def index_write?(node)
        NODE_CLASSES.any? { |klass| node.is_a?(klass) }
      end

      # `arg_types` is the `[key, stored_value]` pair the caller typed, shaped like a `[]=` call's argument list so
      # the widening joins the stored value into the carrier's content evidence exactly as a real `[]=` does
      # (issue #560). Empty means "no evidence" and widens without joining.
      #
      # @param node — one of {NODE_CLASSES}, or a `Prism::IndexTargetNode`
      def widen(node:, current_scope:, arg_types: MutationWidening::NO_ARG_TYPES)
        MutationWidening.widen_receiver_aliases(node.receiver, MUTATOR, current_scope, arg_types: arg_types)
      end
    end
  end
end
