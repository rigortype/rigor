# frozen_string_literal: true

require "prism"

module Rigor
  module Analysis
    # Issue #1967 — the edits `rigor check --verify-incremental-edits` replays on each sampled file, as the text an editor
    # buffer stands in for it with ({IncrementalSession#replay_edit}).
    #
    # - `emptied` — the file with nothing in it. Every declaration and definition it makes disappears, so the replay
    #   exercises the edges a removed declaration fires.
    # - `skeleton` — the file's `class` / `module` declarations, nested as written, with every body statement dropped
    #   (methods, `refine` blocks, visibility calls, mixins, constants). The declarations stay, so the class-level keys
    #   a removed declaration fires stay quiet, and only the finer edges (`refinement:`, `visibility:`, `defines:`, a
    #   method's symbol) can put a reader into the closure. Emptying alone never exercises them: the broader key it
    #   fires re-checks the reader anyway.
    #
    # Neither replays an addition. A skeleton identical to the file, or with no declaration (where it is the emptied
    # file again), is not replayed.
    module EditReplay
      Edit = Data.define(:label, :source)

      module_function

      # The edits to replay for `source`, in order.
      def edits(source)
        emptied = Edit.new(label: "emptying", source: "")
        skeleton = skeleton(source)
        return [emptied] if skeleton.nil? || skeleton.empty? || skeleton == source

        [emptied, Edit.new(label: "reducing to its class/module skeleton", source: skeleton)]
      end

      # `source`'s `class` / `module` declarations, nested, with their bodies dropped; nil when it does not parse.
      def skeleton(source)
        result = Prism.parse(source)
        return nil unless result.success?

        lines = []
        declarations(result.value.statements, 0, lines)
        lines.empty? ? "" : "#{lines.join("\n")}\n"
      end

      def declarations(statements, depth, lines)
        return unless statements.is_a?(Prism::StatementsNode)

        statements.body.each do |node|
          header = header_of(node) or next
          lines << "#{'  ' * depth}#{header}"
          declarations(node.body, depth + 1, lines)
          lines << "#{'  ' * depth}end"
        end
      end

      def header_of(node)
        case node
        when Prism::ClassNode
          superclass = node.superclass ? " < #{node.superclass.slice}" : ""
          "class #{node.constant_path.slice}#{superclass}"
        when Prism::ModuleNode then "module #{node.constant_path.slice}"
        end
      end
      private_class_method :declarations, :header_of
    end
  end
end
