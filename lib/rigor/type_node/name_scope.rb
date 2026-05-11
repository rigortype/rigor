# frozen_string_literal: true

module Rigor
  module TypeNode
    # Companion context handed to every {Rigor::Plugin::TypeNodeResolver}
    # invocation. ADR-13 § "`Plugin::TypeNodeResolver` shape".
    #
    # Three slots:
    #
    # - `resolver`: re-entry point so a plugin can recursively
    #   resolve its own arguments. Any object responding to
    #   `#resolve(node, scope)`. Slice 3 uses {ResolverChain} as
    #   the concrete implementation; tests may pass a stub that
    #   answers `resolve` directly.
    # - `class_context`: the surrounding class / module name, if
    #   any (`String` or `nil`). Plugins use this to resolve
    #   `self`-relative type references or to scope nominal-name
    #   lookups.
    # - `type_alias_table`: a frozen read-only view of the
    #   project's RBS type aliases for forward references. Slice
    #   3 lands the slot with a default empty Hash; the
    #   populated table is wired from {Rigor::Environment} in a
    #   later slice once plugin authors ask for it.
    NameScope = Data.define(:resolver, :class_context, :type_alias_table) do
      def initialize(resolver:, class_context: nil, type_alias_table: {})
        unless resolver.respond_to?(:resolve)
          raise ArgumentError,
                "TypeNode::NameScope resolver must respond to #resolve(node, scope), " \
                "got #{resolver.inspect}"
        end

        unless class_context.nil? || class_context.is_a?(String)
          raise ArgumentError,
                "TypeNode::NameScope class_context must be nil or a String, " \
                "got #{class_context.inspect}"
        end

        unless type_alias_table.is_a?(Hash)
          raise ArgumentError,
                "TypeNode::NameScope type_alias_table must be a Hash, " \
                "got #{type_alias_table.inspect}"
        end

        super(
          resolver: resolver,
          class_context: class_context.nil? ? nil : class_context.dup.freeze,
          type_alias_table: type_alias_table.dup.freeze
        )
      end
    end
  end
end
