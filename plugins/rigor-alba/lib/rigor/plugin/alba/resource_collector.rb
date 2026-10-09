# frozen_string_literal: true

require "prism"

require "rigor/inference/declaration_walk"

require_relative "resource_index"

module Rigor
  module Plugin
    class Alba < Rigor::Plugin::Base
      # A {Rigor::Inference::DeclarationWalk} collector over one file: the classes it declares, whether each
      # `include Alba::Resource`s, and the association declarations whose resource
      # class alba infers from the name.
      #
      # An association is recorded only when alba would take the inference path (`Alba::Association#
      # resource_from`): a literal Symbol/String name, exactly one positional argument, no block, and no
      # `resource:` / `serializer:` keyword. A keyword splat (`**opts`) might carry either, so it is not
      # recorded either — a skipped association costs a root, never invents one.
      class ResourceCollector
        include Rigor::Inference::DeclarationWalk::Collector

        ASSOCIATION_METHODS = %i[association one many has_one has_many].freeze
        RESOURCE_MODULE = "Alba::Resource"
        RESOURCE_KEYWORDS = %i[resource serializer].freeze
        # The calls whose block alba `class_eval`s on an anonymous class (`name == nil`): an association
        # lookup inside one sees no nesting. Any other block (`each`, `class_eval`, ...) leaves it alone.
        ANONYMOUS_CLASS_BLOCK_METHODS = (ASSOCIATION_METHODS + %i[trait nested nested_attribute]).freeze

        attr_reader :classes, :associations

        def initialize
          @entries = {}
          @includes = {}
          @nestings = {}
          @blocks = []
          @associations = []
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
          record_call(node, owner) unless owner.empty? || !node.receiver.nil?
          remember_block(node)
          Rigor::Inference::DeclarationWalk::DESCEND
        end

        # The classes this file declares, as {ResourceIndex::ClassEntry} values.
        def class_entries
          @entries.map do |name, superclass|
            ResourceIndex::ClassEntry.new(
              name: name, superclass: superclass, nesting: @nestings.fetch(name),
              includes_resource: @includes.fetch(name, false)
            )
          end
        end

        private

        def record_call(node, owner)
          if node.name == :include
            @includes[owner] = true if includes_resource?(node)
          elsif ASSOCIATION_METHODS.include?(node.name)
            name = inferred_association_name(node)
            @associations << ResourceIndex::Association.new(owner: owner, name: name, in_block: in_block?(node)) if name
          end
        end

        # The calls are visited outer-first, so a call's block is known before the calls inside it.
        def remember_block(node)
          block = node.block
          return unless block.is_a?(Prism::BlockNode) && ANONYMOUS_CLASS_BLOCK_METHODS.include?(node.name)

          @blocks << (block.location.start_offset...block.location.end_offset)
        end

        def in_block?(node)
          offset = node.location.start_offset
          @blocks.any? { |range| range.cover?(offset) }
        end

        def includes_resource?(node)
          arguments = node.arguments&.arguments || []
          arguments.any? { |argument| constant_name(argument)&.delete_prefix("::") == RESOURCE_MODULE }
        end

        def inferred_association_name(node)
          return nil unless node.block.nil?

          arguments = node.arguments&.arguments || []
          positional = arguments.grep_v(Prism::KeywordHashNode)
          keywords = arguments.grep(Prism::KeywordHashNode)
          return nil unless positional.size == 1 && keywords.size <= 1
          return nil if keywords.any? { |hash| names_resource?(hash) }

          literal_name(positional.first)
        end

        def names_resource?(hash)
          hash.elements.any? do |element|
            !element.is_a?(Prism::AssocNode) || !element.key.is_a?(Prism::SymbolNode) ||
              RESOURCE_KEYWORDS.include?(element.key.unescaped.to_sym)
          end
        end

        def literal_name(node)
          case node
          when Prism::SymbolNode, Prism::StringNode then node.unescaped
          end
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
