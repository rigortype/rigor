# frozen_string_literal: true

module Rigor
  module TypeNode
    # A bare named-type reference in an RBS::Extended payload. The
    # `name` is the head as the parser saw it — kebab-case for
    # built-in refinement names (`"non-empty-string"`),
    # PascalCase for class-like names (`"String"`, `"Pick"`),
    # `lower_snake` for type-function-shaped names without
    # arguments (rare).
    #
    # The resolver dispatch path treats an `Identifier` as the
    # no-arg form: if a plugin recognises `Pick` as a TS-utility
    # name, it MAY still return `Dynamic[top]` for the bare
    # `Identifier("Pick")` since TypeScript's `Pick` is only
    # meaningful with two type arguments. The `Generic` carrier
    # is what plugin resolvers normally key on.
    Identifier = Data.define(:name) do
      def initialize(name:)
        unless name.is_a?(String) && !name.empty?
          raise ArgumentError,
                "TypeNode::Identifier name must be a non-empty String, " \
                "got #{name.inspect}"
        end

        super
      end
    end
  end
end
