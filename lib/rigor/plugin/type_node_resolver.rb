# frozen_string_literal: true

module Rigor
  module Plugin
    # Plugin-supplied resolver for custom named / generic type
    # vocabulary in RBS::Extended payloads. ADR-13 § "Decision".
    #
    # Subclasses override {#resolve} to return a
    # {Rigor::Type::Base} when the node matches the vocabulary
    # the resolver covers, or `nil` to fall through to the next
    # resolver in the chain (and finally to the built-in / RBS
    # fallback). The base implementation returns `nil` so an
    # unimplemented subclass is a safe no-op.
    #
    # Resolvers are registered through their plugin's manifest
    # under the `type_node_resolvers:` slot:
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
    # Slice 2 of the ADR-13 envelope (this file) ships the base
    # class + manifest hook + registry aggregation. The parser-
    # side wiring that actually consults the resolver chain
    # arrives in slice 3, when {Rigor::TypeNode::NameScope} and
    # the dispatcher between {Rigor::Builtins::ImportedRefinements::Parser}
    # and the chain land. Until then resolvers can be unit-tested
    # in isolation but never run for a real `%a{rigor:v1:...}`
    # payload.
    #
    # Resolvers SHOULD be stateless and re-entrant; the registry
    # builds the chain once per `Analysis::Runner.run` and may
    # consult any resolver multiple times for the same node.
    class TypeNodeResolver
      # @param node [Rigor::TypeNode::Identifier, Rigor::TypeNode::Generic]
      #   the parser-emitted node the chain is asking about.
      # @param scope [Rigor::TypeNode::NameScope] companion
      #   value object (slice 3); slice 2 invocations MAY pass
      #   `nil` because the chain doesn't exist yet.
      # @return [Rigor::Type::Base, nil] resolved type, or `nil`
      #   to fall through.
      def resolve(node, scope) # rubocop:disable Lint/UnusedMethodArgument
        nil
      end
    end
  end
end
