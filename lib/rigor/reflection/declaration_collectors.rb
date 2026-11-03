# frozen_string_literal: true

require "prism"

# Not required on its own: `rigor/inference/declaration_walk` loads it once the walk exists, and
# {Reflection.class_declarations_in} loads that entry point on first use. Keeping the walk out of `Reflection`'s own
# load keeps the engine-free paths engine-free (ADR-104).
module Rigor
  module Reflection
    # The walk's collector behind {.class_declarations_in}; the plugin never sees it.
    class DeclarationCollector
      include Inference::DeclarationWalk::Collector

      EMPTY_NESTING = [].freeze

      attr_reader :classes

      def initialize
        @classes = []
      end

      def on_declaration(node, context, body_context)
        if node.is_a?(Prism::ClassNode)
          name = body_context.prefix.join("::")
          @classes << ClassDeclaration.new(name: name, nesting: frozen_nesting(context), node: node) unless name.empty?
        end
        Inference::DeclarationWalk::DESCEND
      end

      private

      # The walk's chain, frozen: the root's `[]` is one array shared by every top-level declaration.
      def frozen_nesting(context)
        nesting = context.nesting || EMPTY_NESTING
        nesting.frozen? ? nesting : nesting.dup.freeze
      end
    end

    # {DeclarationCollector} that also forwards every call. A subclass, because the walk dispatches only the events a
    # collector's class overrides, so a classes-only run pays for no call event.
    class DeclarationCallCollector < DeclarationCollector
      def initialize(on_call)
        super()
        @on_call = on_call
      end

      def on_call(node, context)
        owner = context.prefix.join("::")
        @on_call.call(DeclaredCall.new(node: node, owner: owner.empty? ? nil : owner))
        Inference::DeclarationWalk::DESCEND
      end
    end
    private_constant :DeclarationCollector, :DeclarationCallCollector
  end
end
