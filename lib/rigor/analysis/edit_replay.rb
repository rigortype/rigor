# frozen_string_literal: true

require "prism"

module Rigor
  module Analysis
    # Issue #1967 — the edits `rigor check --verify-incremental-edits` replays on each sampled file, as the text an
    # editor buffer stands in for it with ({IncrementalSession#replay_edit}).
    #
    # - `emptied` — the file with nothing in it. Every declaration and definition it makes disappears, so the replay
    #   exercises the edges a removed declaration fires.
    # - `skeleton` — the file's `class` / `module` declarations, nested as written, with every body statement dropped
    #   (methods, `refine` blocks, visibility calls, mixins, constants). The declarations stay, so the class-level keys
    #   a removed declaration fires stay quiet, and a finer edge such as #2163's `refinement:` is what puts a reader
    #   into the closure. Emptying alone does not exercise that one: the broader key it fires re-checks the reader
    #   anyway. Not every finer edge is reached: dropping a body still moves a broader key for some of them. A
    #   `visibility:` edge is one (#2161's `module_function :two` to `private :two` swap passes both edits with the
    #   edge removed), and only an edit that changes a body while keeping it (#2277) would test it.
    #
    # Neither replays an addition or a body-changing edit. A skeleton identical to the file, or with no declaration
    # (the emptied file again, or a file that does not parse), is not replayed.
    module EditReplay
      Edit = Data.define(:label, :source)

      module_function

      # The edits to replay for `source`, in order.
      def edits(source)
        emptied = Edit.new(label: "emptying", source: "")
        reduced = skeleton(source)
        return [emptied] if reduced.empty? || reduced == source

        [emptied, Edit.new(label: "reducing to its class/module skeleton", source: reduced)]
      end

      # `source`'s `class` / `module` declarations, nested, with their bodies dropped; "" when it does not parse or
      # declares nothing.
      def skeleton(source)
        result = Prism.parse(source)
        return "" unless result.success?

        lines = declarations(result.value.statements, 0)
        lines.empty? ? "" : "#{lines.join("\n")}\n"
      end

      # The skeleton lines of the declarations directly in `statements`, indented `depth` levels.
      def declarations(statements, depth)
        return [] unless statements.is_a?(Prism::StatementsNode)

        statements.body.flat_map do |node|
          next [] unless node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)

          indent = "  " * depth
          ["#{indent}#{header_of(node)}", *declarations(node.body, depth + 1), "#{indent}end"]
        end
      end

      def header_of(node)
        return "module #{node.constant_path.slice}" if node.is_a?(Prism::ModuleNode)

        superclass = node.superclass
        superclass ? "class #{node.constant_path.slice} < #{superclass.slice}" : "class #{node.constant_path.slice}"
      end
      private_class_method :declarations, :header_of
    end
  end
end
