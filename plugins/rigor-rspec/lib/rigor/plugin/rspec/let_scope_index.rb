# frozen_string_literal: true

require "prism"
require "rigor/source/literals"

require_relative "scope_walker"

module Rigor
  module Plugin
    class Rspec < Rigor::Plugin::Base
      # Per-file index of RSpec scope hierarchy. Each
      # describe scope carries:
      #
      # - `outer_range`: `Range[Integer]` of line numbers
      #   covered by the describe's block body (start_line..end_line).
      # - `describe_const`: the model constant string named in
      #   `RSpec.describe SomeModel do` / `describe SomeModel do`,
      #   or `nil` when the describe's first arg is a String
      #   (`describe ".foo"`).
      # - `lets`: `Hash{Symbol => Prism::BlockNode}` of `let(:name)
      #   { ... }` and `subject(:name) { ... }` declarations.
      #   `:subject` is the key for the implicit `subject { ... }`.
      #
      # Pillar 2 Slice 2 — used by the plugin's let-binding
      # `dynamic_return` rule to bind `let`-named
      # method-shape calls inside `it` bodies to the let
      # block's inferred type.
      class LetScopeIndex
        Record = Struct.new(:outer_range, :describe_const, :lets, keyword_init: true) do
          def contains?(line) = outer_range.cover?(line)
          def let?(name) = lets.key?(name.to_sym)
          def let_block(name) = lets[name.to_sym]
        end

        attr_reader :records

        def initialize(records)
          @records = records.freeze
          freeze
        end

        # Returns every record whose outer_range contains the
        # given line, ordered from outermost to innermost. The
        # innermost wins on `let` name collisions per Ruby's
        # method-resolution order (RSpec nested `let` shadows
        # the outer `let`).
        def records_at(line)
          @records.select { |rec| rec.contains?(line) }
        end

        # ADR-52 slice 5a — every `let` / `subject` name declared
        # anywhere in the file, across all describe scopes. Feeds the
        # plugin's `dynamic_return file_methods:` gate: the engine only
        # consults the rule for a call whose name appears here; the
        # precise line-scoped resolution stays in `let_block_at`.
        # @return [Array<Symbol>]
        def let_names
          @records.flat_map { |rec| rec.lets.keys }.uniq
        end

        # Resolves a `let` name at the given line by walking
        # records innermost to outermost.
        # @return [Prism::BlockNode, nil]
        def let_block_at(line, name)
          name_sym = name.to_sym
          records_at(line).reverse.each do |rec|
            return rec.let_block(name_sym) if rec.let?(name_sym)
          end
          nil
        end

        # Resolves the `describe`-anchor constant name at the
        # given line. The innermost describe with a constant
        # anchor wins; describe-with-String anchors are skipped.
        # @return [String, nil]
        def describe_const_at(line)
          records_at(line).reverse.each do |rec|
            return rec.describe_const if rec.describe_const
          end
          nil
        end

        # Builds an index from a parsed root node.
        def self.build(root)
          records = []
          collect(root, anchor: nil, accumulator: records)
          new(records)
        end

        def self.collect(node, anchor:, accumulator:)
          return unless node.is_a?(Prism::Node)

          if describe_call?(node)
            record = build_record(node, anchor)
            accumulator << record
            # `describe_call?` already guarantees a `Prism::CallNode`; the
            # explicit `is_a?` re-states it so the analyzer narrows `node`
            # from `Prism::Node` and resolves `#block` (a CallNode method).
            if node.is_a?(Prism::CallNode) && node.block&.body
              collect(node.block.body, anchor: record.describe_const || anchor, accumulator: accumulator)
            end
            return
          end

          node.compact_child_nodes.each do |child|
            collect(child, anchor: anchor, accumulator: accumulator)
          end
        end

        def self.build_record(describe_call, parent_anchor)
          block_body = describe_call.block.body
          start_line = block_body&.location&.start_line || describe_call.location.start_line
          end_line = block_body&.location&.end_line || describe_call.block.location.end_line

          Record.new(
            outer_range: (start_line..end_line),
            describe_const: describe_call_const(describe_call) || parent_anchor,
            lets: collect_lets(describe_call.block.body)
          )
        end

        def self.describe_call?(node)
          return false unless node.is_a?(Prism::CallNode)
          return false unless ScopeWalker::SCOPE_METHODS.include?(node.name) || node.name == :describe
          return false unless node.block.is_a?(Prism::BlockNode)

          # `RSpec.describe ...` has receiver = RSpec; bare
          # `describe ... do` has nil receiver. Accept both.
          node.receiver.nil? || describe_receiver?(node.receiver)
        end

        def self.describe_receiver?(receiver)
          case receiver
          when Prism::ConstantReadNode then receiver.name == :RSpec
          when Prism::ConstantPathNode then receiver.name == :RSpec && receiver.parent.nil?
          else false
          end
        end

        def self.describe_call_const(describe_call)
          first_arg = describe_call.arguments&.arguments&.first
          render_const(first_arg)
        end

        def self.render_const(node)
          case node
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

        # Walks the describe's body shallowly: collects every
        # top-level `let(:name) { ... }` / `subject(:name) { ... }`
        # / `subject { ... }` declaration. Does NOT recurse into
        # nested describe / context blocks — those have their
        # own record built by `collect` above.
        def self.collect_lets(body)
          return {} unless body.is_a?(Prism::Node)

          lets = {}
          statements_of(body).each do |stmt|
            decl = let_declaration(stmt)
            next if decl.nil?

            lets[decl[:name]] = decl[:block]
          end
          lets.freeze
        end

        def self.statements_of(node)
          case node
          when Prism::StatementsNode then node.body
          else [node]
          end
        end

        def self.let_declaration(node)
          return nil unless node.is_a?(Prism::CallNode)
          return nil unless node.receiver.nil?
          return nil unless %i[let let! subject].include?(node.name)
          return nil unless node.block.is_a?(Prism::BlockNode)

          name = let_declaration_name(node)
          return nil if name.nil?

          { name: name, block: node.block }
        end

        def self.let_declaration_name(call_node)
          first_arg = call_node.arguments&.arguments&.first
          if first_arg.nil?
            # `subject { ... }` with no name — implicit :subject.
            return :subject if call_node.name == :subject

            return nil
          end

          Rigor::Source::Literals.symbol(first_arg)
        end
      end
    end
  end
end
