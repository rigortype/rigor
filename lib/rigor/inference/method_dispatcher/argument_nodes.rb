# frozen_string_literal: true

module Rigor
  module Inference
    module MethodDispatcher
      # What a call's AST says about its argument types that the types alone cannot: shared by the RBS tier's
      # overload selection and the constructor folds, so the two readings of one call cannot drift.
      module ArgumentNodes
        module_function

        # Issue #1727 — whether `args`' last entry is the call's keyword hash (`f(a, k: 1)`), which the overload
        # selector then matches against an overload's keywords. Only the AST tells a keyword hash from a
        # braced positional one (`f(a, { k: 1 })`), so a dispatch without the call node, or one whose
        # arguments are not the node's own (a forwarded `...`, a `send` re-dispatch), answers false and keeps
        # reading every argument positionally.
        def keyword_hash_last?(call_node, args)
          return false if args.empty? || !call_node.respond_to?(:arguments)

          arguments = call_node.arguments&.arguments
          !arguments.nil? && arguments.size == args.size && arguments.last.is_a?(Prism::KeywordHashNode)
        end
      end
    end
  end
end
