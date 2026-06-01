# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    # ADR-37 slice 1d — the lexical context of a node, handed to a
    # {Base.node_rule} block as its fifth argument. Realises the
    # `ContextInfo` ADR-2 § "Scope Object" promised: the enclosing
    # class / module, method, and block-DSL nesting that a per-node rule
    # needs but that `Scope` (value/type facts) does not carry.
    #
    # The engine builds one per matching node from the descent stack
    # (snapshotted, so it is safe to retain). Rules read the bits they
    # need:
    #
    #   node_rule Prism::CallNode do |node, _scope, path, _fc, context|
    #     action = context.enclosing_def&.name           # rails-i18n
    #     model  = context.enclosing_block(:describe)     # shoulda
    #     …
    #   end
    #
    # `ancestors` is the full chain, outermost first, EXCLUDING the node
    # itself — the general primitive; the accessors below are
    # conveniences derived from it.
    class NodeContext
      EMPTY = nil # sentinel documented for readers; rules get a real instance

      attr_reader :ancestors

      def initialize(ancestors)
        @ancestors = ancestors.dup.freeze
        freeze
      end

      # The innermost enclosing `Prism::DefNode`, or nil. Its `#name`
      # is the method the node sits in (rails-i18n uses it to expand a
      # lazy `t('.key')` against the controller action).
      def enclosing_def
        ancestors.rfind { |n| n.is_a?(Prism::DefNode) }
      end

      # The innermost enclosing `Prism::ClassNode` / `Prism::ModuleNode`,
      # or nil (actionpack uses it to resolve the controller a
      # `before_action` / `render` sits in).
      def enclosing_module
        ancestors.rfind { |n| n.is_a?(Prism::ClassNode) || n.is_a?(Prism::ModuleNode) }
      end

      # The innermost enclosing `Prism::CallNode` that carries a block
      # and whose method name is `method_name` — e.g. the
      # `RSpec.describe(Model) do … end` a shoulda matcher sits in.
      # Returns the CallNode (so the caller can read its arguments /
      # receiver), or nil.
      def enclosing_block(method_name)
        ancestors.rfind do |n|
          n.is_a?(Prism::CallNode) && n.block && n.name == method_name
        end
      end
    end
  end
end
