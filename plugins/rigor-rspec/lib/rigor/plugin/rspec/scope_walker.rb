# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class Rspec < Rigor::Plugin::Base
      # Walks an RSpec spec file's AST and yields, for each
      # describe / context block (including the outer
      # `RSpec.describe`), a `Scope` value with the `let`
      # and `subject` declarations recorded inside that
      # scope.
      #
      # Scope hierarchy is preserved: each `Scope` carries
      # a list of its `nested_scopes`. The analyzer uses the
      # hierarchy to detect cross-scope shadowing.
      #
      # Recognised scope methods (when called without a
      # receiver, or with `RSpec` as the receiver):
      #
      # - `describe` / `context` — both open a new nested
      #   scope.
      # - `RSpec.describe` — the outermost scope.
      #
      # Recognised declaration methods (inside any scope,
      # called without a receiver):
      #
      # - `let(:name) { ... }` — caches the block result
      #   per-example; recorded as a Declaration.
      # - `let!(:name) { ... }` — same, but evaluated
      #   eagerly via a `before` hook; same shape for our
      #   purposes.
      # - `subject(:name) { ... }` — special-cases name
      #   `:subject` when called without a name.
      module ScopeWalker
        SCOPE_METHODS = %i[describe context].freeze
        DECLARATION_METHODS = %i[let let! subject].freeze

        # @!attribute [r] kind
        #   `:describe`, `:context`, or `:rspec_describe` for
        #   the root.
        # @!attribute [r] declarations
        #   `Array<Declaration>` declared in this scope.
        # @!attribute [r] nested_scopes
        #   `Array<Scope>` nested under this scope.
        # @!attribute [r] location
        #   `Prism::Location` of the call node that opened
        #   this scope.
        Scope = Struct.new(:kind, :declarations, :nested_scopes, :location, keyword_init: true)

        # @!attribute [r] name
        #   `Symbol` declared name (`:user`, `:subject`,
        #   ...).
        # @!attribute [r] kind
        #   `:let`, `:let!`, or `:subject`.
        # @!attribute [r] location
        #   `Prism::Location` of the call node.
        # @!attribute [r] block_node
        #   `Prism::BlockNode` of the declaration's body.
        Declaration = Struct.new(:name, :kind, :location, :block_node, keyword_init: true)

        module_function

        # Walks the parsed file and returns an array of
        # top-level scopes (each `RSpec.describe` is a
        # separate root). Files with no recognised scopes
        # return an empty array.
        def collect_scopes(root)
          scopes = []
          walk_top_level(root, scopes)
          scopes
        end

        # Walks every scope in a tree (root + descendants)
        # and yields each in turn.
        def each_scope(scope, &)
          yield scope
          scope.nested_scopes.each { |child| each_scope(child, &) }
        end

        def walk_top_level(node, scopes)
          return unless node.is_a?(Prism::Node)

          if rspec_describe_call?(node)
            scopes << build_scope(node, kind: :rspec_describe)
          else
            node.compact_child_nodes.each { |child| walk_top_level(child, scopes) }
          end
        end

        # Returns true for `RSpec.describe ... do |...| ...
        # end` calls.
        def rspec_describe_call?(node)
          return false unless node.is_a?(Prism::CallNode)
          return false unless node.name == :describe
          return false unless node.block.is_a?(Prism::BlockNode)

          receiver_name = constant_name(node.receiver)
          %w[RSpec ::RSpec].include?(receiver_name)
        end

        # Returns true for `describe ... do ... end` /
        # `context ... do ... end` (called without an
        # explicit receiver — `RSpec.describe` is handled
        # separately by `rspec_describe_call?`).
        def nested_scope_call?(node)
          node.is_a?(Prism::CallNode) &&
            SCOPE_METHODS.include?(node.name) &&
            node.block.is_a?(Prism::BlockNode) &&
            node.receiver.nil?
        end

        def declaration_call?(node)
          node.is_a?(Prism::CallNode) &&
            DECLARATION_METHODS.include?(node.name) &&
            node.receiver.nil?
        end

        # Constructs a Scope from a describe / context /
        # RSpec.describe call node. Walks the block body
        # for declarations + nested scopes.
        def build_scope(call_node, kind:)
          declarations = []
          nested = []
          (call_node.block.body&.compact_child_nodes || []).each do |child|
            classify_child(child, declarations, nested)
          end

          Scope.new(
            kind: kind,
            declarations: declarations,
            nested_scopes: nested,
            location: call_node.location
          )
        end

        def classify_child(child, declarations, nested)
          if declaration_call?(child)
            decl = build_declaration(child)
            declarations << decl if decl
          elsif nested_scope_call?(child)
            nested << build_scope(child, kind: child.name)
          end
        end

        def build_declaration(call_node)
          first_arg = call_node.arguments&.arguments&.first
          # `subject(&block)` (no name) defaults to the
          # implicit subject; record it as `:subject`.
          if first_arg.nil?
            return nil unless call_node.name == :subject

            return Declaration.new(
              name: :subject,
              kind: call_node.name,
              location: call_node.location,
              block_node: call_node.block
            )
          end
          return nil unless first_arg.is_a?(Prism::SymbolNode)

          Declaration.new(
            name: first_arg.unescaped.to_sym,
            kind: call_node.name,
            location: call_node.location,
            block_node: call_node.block
          )
        end

        def constant_name(node)
          case node
          when nil then nil
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode
            parts = []
            current = node
            while current.is_a?(Prism::ConstantPathNode)
              parts.unshift(current.name.to_s)
              current = current.parent
            end
            case current
            when nil then "::#{parts.join('::')}"
            when Prism::ConstantReadNode then "#{current.name}::#{parts.join('::')}"
            end
          end
        end
      end
    end
  end
end
