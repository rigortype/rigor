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
    # `Prism::IndexTargetNode` is deliberately absent: it is a multi-assign TARGET, and the `MultiWriteNode` that owns
    # it is where that write is observed.
    module IndexWriteWidening
      NODE_CLASSES = [Prism::IndexOrWriteNode, Prism::IndexAndWriteNode, Prism::IndexOperatorWriteNode].freeze

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
      # @rbs node: Prism::Node -- One of {NODE_CLASSES}
      def widen(node:, current_scope:, arg_types: MutationWidening::NO_ARG_TYPES)
        MutationWidening.widen_receiver_aliases(node.receiver, MUTATOR, current_scope, arg_types: arg_types)
      end
    end
  end
end
