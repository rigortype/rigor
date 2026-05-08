# frozen_string_literal: true

require "prism"

module Rigor
  module Analysis
    module CheckRules
      # Walks a parse tree and collects every `LocalVariableWriteNode`
      # inside a `DefNode` body whose target name is **never read**
      # within the same body.
      #
      # The collector is the read-side companion to the
      # `def.dead-assignment` rule. v0.1.2 ships the narrowest
      # envelope that catches the most common typo / refactoring-
      # leftover shape ("wrote and never used") without surfacing
      # false positives:
      #
      # - Only `Prism::DefNode` bodies are scanned. Top-level
      #   scripts and class-body assignments are skipped — their
      #   variable surface bleeds across requires / introspection
      #   in ways the rule cannot reason about.
      # - Only plain `LocalVariableWriteNode` writes are
      #   considered. Operator-writes (`x += 1`), and-/or-writes
      #   (`x ||= 1`), and `MultiWriteNode` destructures (`a, b =
      #   foo`) are skipped because their write semantics are
      #   intertwined with reads or with a wider tuple binding.
      # - The "is this name ever read" question is answered by
      #   any `LocalVariableReadNode` anywhere in the def
      #   subtree — so a closure capture, a `return x`, a
      #   block-call argument, an interpolated string all count
      #   as a read.
      # - A write whose name starts with `_` is skipped per the
      #   Ruby convention that `_` / `_foo` declares
      #   "intentionally unused".
      # - The last statement of a def body is skipped — Ruby's
      #   implicit return treats `def foo; x = 1; end` as
      #   returning `1`, so the trailing write is intentional.
      class DeadAssignmentCollector
        # Returns `Array<{def_class:, def_name:, write_node:}>`
        # — one entry per dead-assignment write. Empty when
        # the tree has no qualifying writes.
        def initialize(scope_index)
          @scope_index = scope_index
          @results = []
        end

        def collect(root)
          walk_for_def_nodes(root)
          @results.freeze
        end

        private

        def walk_for_def_nodes(node)
          return unless node.is_a?(Prism::Node)

          collect_def_assignments(node) if node.is_a?(Prism::DefNode)
          node.compact_child_nodes.each { |child| walk_for_def_nodes(child) }
        end

        def collect_def_assignments(def_node)
          body = def_node.body
          return if body.nil?

          read_names = gather_read_names(body)
          last_node = trailing_statement(body)

          gather_write_nodes(body).each do |write|
            next if write.equal?(last_node)
            next if write.name.to_s.start_with?("_")
            next if read_names.include?(write.name)

            @results << { def_node: def_node, write_node: write }
          end
        end

        def gather_read_names(node, accumulator = Set.new)
          return accumulator unless node.is_a?(Prism::Node)

          accumulator << node.name if node.is_a?(Prism::LocalVariableReadNode)
          # Operator/and/or-writes implicitly read the prior
          # binding — count them too so `x = 1; x ||= 2; x` /
          # similar shapes don't trip the rule.
          accumulator << node.name if reading_assignment?(node)

          node.compact_child_nodes.each { |child| gather_read_names(child, accumulator) }
          accumulator
        end

        def reading_assignment?(node)
          node.is_a?(Prism::LocalVariableOperatorWriteNode) ||
            node.is_a?(Prism::LocalVariableAndWriteNode) ||
            node.is_a?(Prism::LocalVariableOrWriteNode)
        end

        def gather_write_nodes(node, accumulator = [])
          return accumulator unless node.is_a?(Prism::Node)

          accumulator << node if node.is_a?(Prism::LocalVariableWriteNode)
          # Don't recurse into nested DefNodes — their bodies
          # carry their own dead-assignment scope and the
          # outer walker visits them separately.
          return accumulator if node.is_a?(Prism::DefNode) && !accumulator.last.equal?(node)

          node.compact_child_nodes.each { |child| gather_write_nodes(child, accumulator) }
          accumulator
        end

        # Returns the final statement of a body node, descending
        # into wrappers Ruby preserves verbatim (`begin ... end`
        # blocks). Used to skip the implicit-return write at the
        # tail of a method body.
        def trailing_statement(body)
          case body
          when Prism::StatementsNode then body.body.last
          when Prism::BeginNode
            body.statements ? trailing_statement(body.statements) : nil
          end
        end
      end
    end
  end
end
