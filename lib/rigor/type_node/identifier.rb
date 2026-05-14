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
    class Identifier < Data.define(:name)
      def initialize(name:)
        unless name.is_a?(String) && !name.empty?
          raise ArgumentError,
                "TypeNode::Identifier name must be a non-empty String, " \
                "got #{name.inspect}"
        end

        # Freeze the String field so the resulting Data object
        # is `Ractor.shareable?` regardless of whether the
        # caller passed a `# frozen_string_literal: true`
        # constant or a dynamically built String. The same
        # discipline applies to every other TypeNode value
        # object — they live in the parser's hot path and are
        # the natural carriers to flow through future Ractor
        # boundaries (see CURRENT_WORK Open Items #8).
        super(name: name.frozen? ? name : name.dup.freeze)
      end
    end
  end
end
