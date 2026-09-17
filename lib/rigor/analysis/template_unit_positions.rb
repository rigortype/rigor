# frozen_string_literal: true

require "prism"

require_relative "../source/node_children"

module Rigor
  module Analysis
    # #1040 — the INVERSE of a template unit's positions: a template `(line, column)` the user names, resolved
    # to the one compiled node it denotes, or declined.
    #
    # Everything else the seam ships runs compiled → template ({TemplateUnits#remap}). A position probe runs
    # the other way, and neither half of the map inverts on its own terms:
    #
    # - **Lines.** `line_map` is not injective — a compiler may emit several compiled lines for one template
    #   line, and lines the map does not mention anchor at the nearest mapped line before them. So a template
    #   line names a SET of compiled lines: every one whose {TemplateUnits::Entry#template_line} is that line,
    #   which is exactly the set a diagnostic would be reported from.
    # - **Columns.** They do not correspond at all. A compiler rewrites each line's text around the Ruby it
    #   copies (`<%= @user.name %>` becomes `_buf << ( @user.name ).to_s;`), and the seam says nothing about
    #   where the copied bytes land.
    #
    # What IS true of every line-preserving template compiler is that the code a tag carries is copied
    # verbatim. So a column is resolved through the **longest verbatim run**: every placement of the template
    # line's byte at the column against the candidate compiled lines is extended left and right while the
    # bytes agree, and the longest such run wins. The answer is accepted only when all of these hold:
    #
    # 1. the longest run is UNIQUE — two placements of equal length are two readings, and the probe declines
    #    (`:ambiguous`) rather than pick one;
    # 2. the deepest compiled node at the mapped offset lies wholly INSIDE that run, on one line — which is
    #    what rejects markup: template text is copied into a string LITERAL, and the literal node's quotes
    #    are never part of the template's bytes (`:not_verbatim`).
    #
    # The engine knows nothing about ERB here, and needs to: an identity transform (the whole line is one run)
    # and an ERB compiler (each tag body is a run) answer through the same rule, and a tag the compiler
    # REWROTE rather than copied (rigor-actionpack's `yield` → `__rigor_yield`) is declined, because the node
    # it produced is not made of the template's bytes.
    class TemplateUnitPositions
      # A verbatim run: `[from_start, from_end)` on the side the search started from, `shift` added to reach
      # the other side, and `line` — the compiled line it lies on.
      Run = Data.define(:line, :from_start, :from_end, :shift) do
        def length = from_end - from_start
      end
      private_constant :Run

      # Mirrors the `rigor type-of FILE:LINE` cap, so a template line table is bounded the same way.
      ENUMERATION_CAP = 40

      # @param entry — the unit's {TemplateUnits::Entry}.
      # @param template — the template's own bytes, exactly as the plugin was handed them.
      # @param root — the parse of `entry.source`.
      # @param skip_node_types — node class names a line enumeration leaves out (the probe's non-expressions).
      def initialize(entry:, template:, root:, skip_node_types: [])
        @entry = entry
        @template_lines = template.b.lines.map(&:chomp)
        @compiled_lines = entry.source.b.lines
        # Offsets are summed over the RAW lines, so a `\r\n` compiled source still lands on the right byte.
        @compiled_widths = @compiled_lines.map(&:bytesize)
        @compiled_lines = @compiled_lines.map(&:chomp)
        @root = root
        @skip_node_types = skip_node_types
      end

      def template_line_count
        @template_lines.length
      end

      # The deepest compiled node a template position denotes, or a Symbol saying why there is none:
      # `:no_compiled_line`, `:not_verbatim` or `:ambiguous`. The caller has already range-checked the line.
      def node_at(line:, column:)
        text = @template_lines.fetch(line - 1)
        offset = column - 1
        return :not_verbatim if offset >= text.bytesize

        candidates = compiled_lines_for(line)
        return :no_compiled_line if candidates.empty?

        # The compiled line ABOVE joins as a spill target: stdlib ERB hoists a line's leading text onto it
        # (`_erbout.<< "\nname ".freeze`), so the literal a probe in that text has to tie with is not on
        # this template line's compiled lines at all.
        resolve(text, offset, targets_for(candidates), spill_targets(candidates))
      end

      # The nearest NON-BLANK compiled line above this template line's own, or none.
      #
      # Not "the compiled lines of template line L-1": one text gap is ONE literal, and the compiler pads
      # the lines it swallowed with blanks, so the literal carrying line L's leading text sits on the last
      # line that emitted anything — which is L-1 only when L-1 itself carried a tag. With the L-1 reading,
      # `<h1>T</h1>` / `<div>` / `name <%= name %>` answered about the tag's code at `3:1`, and so did any
      # view with a blank line or a text-only line above the probed one: the common shape.
      def spill_targets(candidates)
        number = candidates.min - 1
        number -= 1 while number.positive? && @compiled_lines[number - 1].strip.empty?
        number.positive? ? targets_for([number]) : []
      end

      def targets_for(numbers)
        numbers.map { |number| [number, @compiled_lines[number - 1]] }
      end

      # `[[template_column, node], …]` for the expressions starting on the compiled lines a template line
      # maps to, restricted to the ones whose bytes are the template's own — so every column in the table is
      # a column of the TEMPLATE, and a probe at it resolves through the same verbatim run {#node_at} uses.
      # Returns `[rows, total]`, `rows` capped at {ENUMERATION_CAP}.
      def line_nodes(line)
        text = @template_lines.fetch(line - 1)
        wanted = compiled_lines_for(line).to_h { |number| [number, true] }
        rows = []
        walk(@root) do |node|
          next unless wanted.key?(node.location.start_line)
          next if @skip_node_types.include?(node.class.name)

          column = template_column(node, text)
          rows << [column, node] if column
        end
        rows.sort_by! { |column, node| [column, -node.location.length] }
        [rows.first(ENUMERATION_CAP), rows.length]
      end

      # The template column a compiled location starts at, or nil when it does not lie in a verbatim run.
      # Used to position `--trace` fallback events, which carry compiled locations.
      def template_column_for(location)
        return nil unless location.respond_to?(:start_line)

        text = @template_lines[@entry.template_line(location.start_line) - 1]
        return nil if text.nil? || location.start_line != location.end_line

        column_of_span(location, text)
      end

      private

      def compiled_lines_for(line)
        @compiled_by_template ||= (1..@compiled_lines.length).group_by { |number| @entry.template_line(number) }
        @compiled_by_template.fetch(line, [])
      end

      def template_column(node, text)
        location = node.location
        return nil unless location.start_line == location.end_line

        column_of_span(location, text)
      end

      # Forward, compiled span → template column, confirmed by probing BACK from the answer: the column is
      # reported only when {#node_at} at it resolves to a node starting where this one does. Anything the
      # table prints is therefore a column the exact form answers, declines included.
      def column_of_span(location, text)
        compiled_line = location.start_line
        compiled = @compiled_lines[compiled_line - 1]
        return nil if compiled.nil? || location.start_column >= compiled.bytesize

        forward = resolve_run(compiled, location.start_column, [[compiled_line, text]])
        return nil if forward.is_a?(Symbol) || location.end_column > forward.from_end

        template_offset = location.start_column + forward.shift
        back = node_at(line: @entry.template_line(compiled_line), column: template_offset + 1)
        return nil unless back.is_a?(Prism::Node) && back.location.start_offset == location.start_offset

        template_offset + 1
      end

      # The one compiled node a template offset denotes, through the verbatim runs, or the Symbol reason.
      #
      # The LONGEST run decides, and it must be unique: two placements of equal length are two readings.
      # But a longer run is not on its own a better reading, because a compiler's own punctuation joins the
      # template's bytes into runs the template never had — the `=` of `<%=` matches the `=` of `<=`, `==`,
      # `+=` or an assignment, so `"= v "` (4 bytes, ending in the WRONG `v`) outran the tag body `" v "`
      # (3 bytes) and the probe answered about another `v` on the line. So a placement whose own deepest
      # node lies inside its own run is a RIVAL reading, and a rival declines the position.
      #
      # A repeat INSIDE the winning run is not a rival: `<%= @author.nil? ? l(:a) : l(:b, f(@author)) %>`
      # copies one tag body once, and the second `@author` is the same copy seen from the other end, not a
      # second reading. Only a node OUTSIDE the winning run's own compiled span counts, which is what keeps
      # the busy lines of a real view answerable while the cross-tag repeat (`<%= v %> <%= v.to_s %>`, or
      # `<%= v %><%= "v" %>` probed at the STRING's `v`) still declines — the family a plugin-exported tag
      # span would answer instead
      # (see the PR), and the follow-up this rule is deliberately conservative ahead of.
      #
      # `spill` is the nearest NON-BLANK compiled line above this template line's own, where a hoisted
      # leading-text literal lives. Only a string literal the run does NOT contain counts there. A code
      # node up there is ordinary compiled code, and counting it would decline every `<%= v %>` that
      # repeats on consecutive template lines; a literal the run DOES contain is a literal the TAG wrote
      # (`<%= link_to "Edit", path %>`), whose quotes are template bytes, so it passes `inside?` and the
      # probe answered about that tag's string from an HTML attribute that happened to spell it. A
      # hoisted literal is never inside its own run — the quotes around it are the compiler's — so spill
      # runs can only ever form ties, which is all they exist to do.
      def resolve(text, offset, targets, spill = [])
        runs = collect_runs(text, offset, targets)
        runs += collect_runs(text, offset, spill).select { |run| hoisted_text?(run, offset) }
        return :not_verbatim if runs.empty?

        longest = runs.max_by(&:length)
        return :ambiguous if runs.count { |run| run.length == longest.length } > 1

        answer = node_for(longest, offset)
        return :not_verbatim unless inside?(answer, longest)

        rival = runs.any? do |run|
          next false if run.equal?(longest)

          node = node_for(run, offset)
          inside?(node, run) && !node.equal?(answer) && !inside?(node, longest)
        end
        rival ? :ambiguous : answer
      end

      def collect_runs(text, offset, targets)
        runs = []
        targets.each { |number, to| runs_through(text, offset, to, number) { |run| runs << run } }
        runs
      end

      def hoisted_text?(run, offset)
        node = node_for(run, offset)
        node.is_a?(Prism::StringNode) && !inside?(node, run)
      end

      def node_for(run, offset)
        deepest(@root, compiled_offset(run.line, offset + run.shift))
      end

      # The longest verbatim run through `from[offset]` across every placement on the `targets` lines, or
      # `:not_verbatim` when the byte appears nowhere and `:ambiguous` when two placements tie. The
      # compiled → template direction, where the node is already known, so only the run's length decides.
      def resolve_run(from, offset, targets)
        best = nil
        tied = false
        targets.each do |number, to|
          runs_through(from, offset, to, number) do |run|
            if best.nil? || run.length > best.length
              best = run
              tied = false
            elsif run.length == best.length
              tied = true
            end
          end
        end
        return :not_verbatim if best.nil?
        return :ambiguous if tied

        best
      end

      def runs_through(from, offset, to, number)
        byte = from.getbyte(offset)
        to.bytesize.times do |index|
          next unless to.getbyte(index) == byte

          shift = index - offset
          left = offset
          left -= 1 while left.positive? && (left + shift).positive? &&
                          from.getbyte(left - 1) == to.getbyte(left - 1 + shift)
          right = offset + 1
          right += 1 while right < from.bytesize && from.getbyte(right) == to.getbyte(right + shift)
          yield Run.new(line: number, from_start: left, from_end: right, shift: shift)
        end
      end

      def inside?(node, run)
        return false if node.nil?

        location = node.location
        location.start_line == run.line && location.end_line == run.line &&
          location.start_column >= run.from_start + run.shift && location.end_column <= run.from_end + run.shift
      end

      def compiled_offset(line, column)
        @compiled_widths.first(line - 1).sum + column
      end

      def deepest(node, offset)
        return nil unless node.is_a?(Prism::Node)

        location = node.location
        return nil unless location.start_offset <= offset && offset < location.end_offset

        node.rigor_each_child do |child|
          deeper = deepest(child, offset)
          return deeper if deeper
        end
        node
      end

      def walk(node, &block)
        return unless node.is_a?(Prism::Node)

        block.call(node)
        node.rigor_each_child { |child| walk(child, &block) }
      end
    end
  end
end
