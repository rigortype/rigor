# frozen_string_literal: true

module Rigor
  module TypeNode
    # Walks an ordered list of {Rigor::Plugin::TypeNodeResolver}
    # instances, returning the first non-nil `resolve(node, scope)`
    # answer. ADR-13 § "`Plugin::TypeNodeResolver` shape" — first
    # non-nil wins; registration order is the user's lever for
    # shadowing per WD3 / WD5.
    #
    # The chain is itself a `TypeNodeResolver`-shaped object
    # (`#resolve(node, scope)`) so it slots into a {NameScope} as
    # the `resolver:` field without further indirection: a plugin
    # resolver that wants to recursively resolve a nested argument
    # calls `scope.resolver.resolve(arg, scope)` and reaches every
    # resolver in the chain plus the built-in registry through the
    # same entry point.
    #
    # Constructed once per `Analysis::Runner.run` from
    # `Plugin::Registry#type_node_resolvers`. The chain is
    # immutable and re-entrant; the parser may consult it many
    # times for the same node.
    class ResolverChain
      def initialize(resolvers)
        unless resolvers.is_a?(Array) && resolvers.all? { |r| r.respond_to?(:resolve) }
          raise ArgumentError,
                "TypeNode::ResolverChain expects an Array of resolvers " \
                "responding to #resolve(node, scope), got #{resolvers.inspect}"
        end

        @resolvers = resolvers.dup.freeze
        freeze
      end

      # @return [Array<Rigor::Plugin::TypeNodeResolver>] ordered
      #   resolver instances, in plugin-registration order.
      attr_reader :resolvers

      # First non-nil `resolve(node, scope)` answer from the chain;
      # `nil` when every resolver declined.
      def resolve(node, scope)
        @resolvers.each do |resolver|
          result = resolver.resolve(node, scope)
          return result unless result.nil?
        end
        nil
      end

      # Shared empty chain — a `NameScope` constructed without any
      # plugin-supplied resolvers can use this to satisfy the
      # `responds_to?(:resolve)` contract without a per-call
      # allocation.
      EMPTY = new([]).freeze
    end
  end
end
