# frozen_string_literal: true

require "prism"

require "rigor/inference/declaration_walk"

require_relative "serializer_index"

module Rigor
  module Plugin
    class Typelizer < Rigor::Plugin::Base
      # A {Rigor::Inference::DeclarationWalk} collector over one file: the classes it declares, and whether each
      # one's own body says `include Typelizer::DSL` / `extend Typelizer::DSL`.
      #
      # Only the class body itself counts. A `module` that includes the DSL is deliberately not recorded:
      # typelizer registers the module's own name and later calls `.descendants` on it, which a Module does not
      # have, and `DSL.included` never fires for a class that merely includes that module (see the README).
      # A `class << self` body is skipped too, since the hook would see the singleton class there.
      class SerializerCollector
        include Rigor::Inference::DeclarationWalk::Collector

        DSL_MODULE = "Typelizer::DSL"
        DSL_CALLS = %i[include extend].freeze

        def initialize
          @entries = {}
          @nestings = {}
          @dsl = {}
        end

        def on_declaration(node, context, body_context)
          return Rigor::Inference::DeclarationWalk::DESCEND unless node.is_a?(Prism::ClassNode)

          name = body_context.prefix.join("::")
          unless name.empty?
            @entries[name] = superclass_name(node.superclass)
            @nestings[name] = context.nesting || []
          end
          Rigor::Inference::DeclarationWalk::DESCEND
        end

        def on_call(node, context)
          owner = context.prefix.join("::")
          if DSL_CALLS.include?(node.name) && node.receiver.nil? && !owner.empty? && !context.singleton_cref &&
             dsl_argument?(node)
            @dsl[owner] = true
          end
          Rigor::Inference::DeclarationWalk::DESCEND
        end

        # The classes this file declares, as {SerializerIndex::ClassEntry} values.
        def class_entries
          @entries.map do |name, superclass|
            SerializerIndex::ClassEntry.new(
              name: name, superclass: superclass, nesting: @nestings.fetch(name), dsl: @dsl.fetch(name, false)
            )
          end
        end

        private

        def dsl_argument?(node)
          arguments = node.arguments&.arguments || []
          arguments.any? { |argument| constant_name(argument)&.delete_prefix("::") == DSL_MODULE }
        end

        def superclass_name(node)
          node && constant_name(node)
        end

        def constant_name(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode
            parent = node.parent
            return "::#{node.name}" if parent.nil?

            prefix = constant_name(parent)
            prefix && "#{prefix}::#{node.name}"
          end
        end
      end
    end
  end
end
