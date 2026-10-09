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
      # A `module` that includes the DSL is deliberately not recorded: typelizer registers the module's own
      # name and `target_serializers` then calls `.descendants` on it, which a plain Module lacks. A class that
      # reaches the DSL through a module's `included do ... end` hook is a known missed root (see the README).
      #
      # Only a statement of the class body itself counts, because only there is `self` the class: the walk is
      # over the body's own statements (through `if` / `unless` / `begin`), never into a `def`, a block, a
      # lambda or a nested class, so `Class.new { include Typelizer::DSL }`, `Other.class_eval { include ... }`,
      # `included do include Typelizer::DSL end` and a `def` that includes it credit nothing to the lexical
      # class. A `class << self` body is a different node and is not entered either.
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
            superclass = superclass_name(node.superclass)
            @entries[name] = superclass if superclass || !@entries.key?(name)
            @nestings[name] = context.nesting || []
            @dsl[name] = true if dsl_in?(node.body) && !body_context.singleton_cref
          end
          Rigor::Inference::DeclarationWalk::DESCEND
        end

        # The classes this file declares, as {SerializerIndex::ClassEntry} values.
        def class_entries
          @entries.map do |name, superclass|
            SerializerIndex::ClassEntry.new(
              name: name, superclass: superclass, nesting: @nestings.fetch(name), dsl: @dsl.fetch(name, false),
              in_dirs: false
            )
          end
        end

        private

        # Whether a statement reachable without entering a def, block, lambda or nested declaration is a
        # receiverless `include` / `extend` of the DSL module.
        def dsl_in?(node)
          case node
          when Prism::StatementsNode then node.body.any? { |child| dsl_in?(child) }
          when Prism::BeginNode then dsl_in?(node.statements) || dsl_in?(node.else_clause)
          when Prism::ElseNode then dsl_in?(node.statements)
          when Prism::IfNode then dsl_in?(node.statements) || dsl_in?(node.subsequent)
          when Prism::UnlessNode then dsl_in?(node.statements) || dsl_in?(node.else_clause)
          when Prism::CallNode then dsl_call?(node)
          else false
          end
        end

        def dsl_call?(node)
          DSL_CALLS.include?(node.name) && node.receiver.nil? && node.block.nil? && dsl_argument?(node)
        end

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
