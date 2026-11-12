# frozen_string_literal: true

require "prism"

require_relative "../../inference/scope_indexer"
require_relative "../../source/constant_path"

module Rigor
  module Analysis
    module CheckRules
      # Issue #3155 — the singleton defs of one file that a later def of the same name certainly replaces, which
      # `def.return-type-mismatch` does not check against the class's signature: Ruby keeps the later body.
      #
      # Both defs must be certain singleton defs of the same class or module body: a direct statement of that body
      # (`def self.x`, or `def K.x` where `K` names the class), or a direct statement of a `class << self` there
      # (`def x`, or `def K.x`). A def in a block (`Class.new do … end`, `Struct.new(…) do … end`), under a condition,
      # loop or `begin`/`rescue`, or in a method body may not run, or runs on another object, so it replaces nothing,
      # and a def written there is never read as replaced either. A reopening in another file is not read.
      class ReplacedSingletonDefs
        def initialize(root)
          @root = root
        end

        def replaced?(def_node) = offsets.include?(def_node.location.start_offset)

        # `def (self).x` and `def (K).x` name the receiver inside parentheses.
        def self.unparenthesized(node)
          while node.is_a?(Prism::ParenthesesNode)
            body = node.body
            node = body.is_a?(Prism::StatementsNode) && body.body.size == 1 ? body.body.first : body
          end
          node
        end

        private

        def offsets
          @offsets ||= collect
        end

        def collect
          replaced = Set.new
          each_class_body(@root) do |body, prefix|
            last = {}
            certain_singleton_defs(body, prefix).each do |def_node|
              replaced << last[def_node.name].location.start_offset if last.key?(def_node.name)
              last[def_node.name] = def_node
            end
          end
          replaced
        end

        def each_class_body(node, &)
          return if node.nil?

          if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
            rendered = Source::ConstantPath.qualified_name(node.constant_path)
            yield node.body, rendered.split("::") if rendered
          end
          node.rigor_each_child { |child| each_class_body(child, &) }
        end

        def certain_singleton_defs(body, prefix)
          statements(body).flat_map do |stmt|
            case stmt
            when Prism::DefNode
              lexical_self?(stmt.receiver, prefix, self_allowed: true) ? [stmt] : []
            when Prism::SingletonClassNode
              next [] unless lexical_self?(stmt.expression, prefix, self_allowed: true)

              statements(stmt.body).select do |inner|
                inner.is_a?(Prism::DefNode) &&
                  (inner.receiver.nil? || lexical_self?(inner.receiver, prefix, self_allowed: false))
              end
            else
              []
            end
          end
        end

        def lexical_self?(node, prefix, self_allowed:)
          node = self.class.unparenthesized(node)
          return self_allowed if node.is_a?(Prism::SelfNode)

          !node.nil? && Inference::ScopeIndexer.def_receiver_targets_lexical_self?(node, prefix)
        end

        def statements(body) = body.is_a?(Prism::StatementsNode) ? body.body : []
      end
    end
  end
end
