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
    #   edge removed), and only an edit that changes a body while keeping it would test it.
    # - `dropped` (#2277) — the file with ONE statement of a `class` / `module` body removed and everything else kept,
    #   so the declarations, the other definitions and every broader key stay as they were and a finer edge is the
    #   only thing that re-checks a reader. At most {MAX_DROPS} statements per file: the visibility-changing calls
    #   (`private`, `module_function`, ... {VISIBILITY_CALLS}) first, a body's own statements before those of the bodies
    #   nested in it, since those are what finer edges such as #2161's `visibility:` read; then the other statements,
    #   spread evenly over the file. A drop whose remainder does not parse (a heredoc body left behind) gives way to the
    #   next candidate. Statements of a `class << self` body are never candidates.
    #
    # No edit is an addition. An edit identical to the file or to an earlier edit, or a file that does not parse
    # (or, for the skeleton, declares nothing), is not replayed.
    module EditReplay
      Edit = Data.define(:label, :source)

      # The most body-statement drops replayed per file; each is a recheck plus a full analysis.
      MAX_DROPS = 2

      VISIBILITY_CALLS = %i[
        private public protected module_function private_class_method public_class_method
        private_constant public_constant
      ].freeze

      module_function

      # The edits to replay for `source`, in order.
      def edits(source)
        emptied = Edit.new(label: "emptying", source: "")
        reduced = skeleton(source)
        edits = [emptied]
        edits << Edit.new(label: "reducing to its class/module skeleton", source: reduced) unless reduced.empty?
        edits.concat(drops(source))
        edits.reject { |edit| edit.source == source }.uniq(&:source)
      end

      # Up to {MAX_DROPS} edits, each `source` less one statement of a class / module body, in source order. A drop that
      # leaves text that does not parse is never returned: the next candidate takes its place.
      def drops(source)
        result = Prism.parse(source)
        return [] unless result.success?

        picked = []
        preferred(drop_candidates(result.value.statements.body)).each do |node|
          edit = drop_edit(source, node)
          picked << [node, edit] if edit
          break if picked.size == MAX_DROPS
        end
        picked.sort_by { |node, _| node.location.start_offset }.map(&:last)
      end

      # `source` less `node`, or nil when what is left does not parse. The range runs to the furthest heredoc body
      # inside the node, which sits after the node's own location.
      def drop_edit(source, node)
        location = node.location
        from, to = whole_lines(source, location.start_offset, [location.end_offset, heredoc_end(node)].max)
        dropped = source.byteslice(0, from) + source.byteslice(to..)
        return nil unless Prism.parse(dropped).success?

        Edit.new(label: "dropping the statement at line #{location.start_line} of", source: dropped)
      end

      # The end offset of the furthest heredoc terminator inside `node` (0 when it holds none).
      def heredoc_end(node)
        own = node.respond_to?(:closing_loc) && node.respond_to?(:opening_loc) &&
              node.opening_loc&.slice&.start_with?("<<")
        ends = node.compact_child_nodes.map { |child| heredoc_end(child) }
        ends << node.closing_loc.end_offset if own && node.closing_loc
        ends.max || 0
      end

      # The byte range of `start...finish` widened to the lines it alone occupies, so no blank line is left behind.
      def whole_lines(source, start, finish)
        head = source.byteslice(0, start)[/(?<=\A|\n)[ \t]*\z/]
        tail = finish.positive? && source.getbyte(finish - 1) == 10 ? "" : source.byteslice(finish..)[/\A[ \t]*\n/]
        head.nil? || tail.nil? ? [start, finish] : [start - head.bytesize, finish + tail.bytesize]
      end

      # Every statement directly in a `class` / `module` body of `nodes`, nested bodies included, in the order a body's
      # own statements come before those of the bodies nested in it (a nested declaration is itself a candidate,
      # dropped whole). A `class << self` body is never searched: its statements are not candidates.
      def drop_candidates(nodes)
        nodes.flat_map do |node|
          next [] unless (node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)) &&
                         node.body.is_a?(Prism::StatementsNode)

          body = node.body.body
          [*body, *drop_candidates(body)]
        end
      end

      # The candidates in the order to try them: the visibility calls, then the other statements from the evenly spread
      # picks outward, then the rest of the other statements.
      def preferred(candidates)
        visibility, others = candidates.partition { |node| visibility_call?(node) }
        spread = Array.new(others.empty? ? 0 : MAX_DROPS) do |index|
          others[(((index * 2) + 1) * others.size) / (MAX_DROPS * 2)]
        end
        [*visibility, *spread, *others].uniq(&:object_id)
      end

      def visibility_call?(node)
        node.is_a?(Prism::CallNode) && VISIBILITY_CALLS.include?(node.name) &&
          (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
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
      private_class_method :declarations, :header_of, :drop_candidates, :whole_lines, :drop_edit, :heredoc_end,
                           :preferred, :visibility_call?
    end
  end
end
