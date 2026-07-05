# frozen_string_literal: true

module Rigor
  module Plugin
    # Plugin-supplied resolver for custom named / generic type vocabulary in RBS::Extended payloads. ADR-13 §
    # "Decision".
    #
    # Subclasses override {#resolve} to return a {Rigor::Type::Base} when the node matches the vocabulary the
    # resolver covers, or `nil` to fall through to the next resolver in the chain (and finally to the built-in /
    # RBS fallback). The base implementation returns `nil` so an unimplemented subclass is a safe no-op.
    #
    # Resolvers are registered through their plugin's manifest under the `type_node_resolvers:` slot:
    #
    #   class RigorTypescriptUtilityTypes < Rigor::Plugin::Base
    #     manifest(
    #       id: "typescript-utility-types",
    #       version: "0.1.0",
    #       type_node_resolvers: [Resolvers::Pick.new,
    #                             Resolvers::Omit.new]
    #     )
    #   end
    #
    # ADR-13 — base class, manifest hook, and registry aggregation for plugin-contributed type-node resolvers.
    # Resolvers declared via `manifest(type_node_resolvers:)` run for every real `%a{rigor:v1:...}` payload
    # through `TypeNode::ResolverChain` (built by `Environment#build_name_scope` from
    # `Plugin::Registry#type_node_resolvers`).
    #
    # Resolvers SHOULD be stateless and re-entrant; the registry builds the chain once per
    # `Analysis::Runner.run` and may consult any resolver multiple times for the same node.
    class TypeNodeResolver
      # @param node [Rigor::TypeNode::Identifier, Rigor::TypeNode::Generic] the parser-emitted node the chain is
      #   asking about.
      # @param scope [Rigor::TypeNode::NameScope] companion value object (slice 3); slice 2 invocations MAY pass
      #   `nil` because the chain doesn't exist yet.
      # @return [Rigor::Type::Base, nil] resolved type, or `nil` to fall through.
      def resolve(node, scope) # rubocop:disable Lint/UnusedMethodArgument
        nil
      end
    end
  end
end
