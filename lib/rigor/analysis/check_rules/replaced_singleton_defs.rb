# frozen_string_literal: true

require "prism"

require_relative "../../inference/scope_indexer"

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
      #
      # The walk groups defs by the class or module body node only; whether a constant receiver names the class is
      # read from the def's own Scope (`self_type`, the indexer's declaration context), so it derives none itself.
      class ReplacedSingletonDefs
        def initialize(root, scope_index)
          @root = root
          @scope_index = scope_index
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
          each_class_body(@root) do |body|
            last = {}
            certain_singleton_defs(body).each do |def_node|
              replaced << last[def_node.name].location.start_offset if last.key?(def_node.name)
              last[def_node.name] = def_node
            end
          end
          replaced
        end

        def each_class_body(node, &)
          return if node.nil?

          yield node.body if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
          node.rigor_each_child { |child| each_class_body(child, &) }
        end

        def certain_singleton_defs(body)
          statements(body).flat_map do |stmt|
            case stmt
            when Prism::DefNode
              lexical_self?(stmt.receiver, stmt, self_allowed: true) ? [stmt] : []
            when Prism::SingletonClassNode
              next [] unless lexical_self?(stmt.expression, stmt, self_allowed: true)

              statements(stmt.body).select do |inner|
                inner.is_a?(Prism::DefNode) &&
                  (inner.receiver.nil? || lexical_self?(inner.receiver, inner, self_allowed: false))
              end
            else
              []
            end
          end
        end

        # `at` is the node whose Scope names the class: its `self_type` is the class or its singleton.
        def lexical_self?(node, at, self_allowed:)
          node = self.class.unparenthesized(node)
          return self_allowed if node.is_a?(Prism::SelfNode)

          self_type = @scope_index[at]&.self_type
          return false unless self_type.respond_to?(:class_name)

          Inference::ScopeIndexer.def_receiver_targets_lexical_self?(node, self_type.class_name.split("::"))
        end

        def statements(body) = body.is_a?(Prism::StatementsNode) ? body.body : []
      end
    end
  end
end
