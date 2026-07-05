# frozen_string_literal: true

require_relative "prism_colorizer"

module Rigor
  class CLI
    # Replays a `Rigor::Inference::FlowTracer` event stream as a terminal animation for `rigor trace`. Each frame draws
    # a box-drawn screen: the source panel (syntax-coloured, current node range underlined) side-by-side with the scope
    # panel (locals accumulated from :bind events), and an event panel describing the current step and the expression
    # stack.
    #
    # The frame is fitted to the measured terminal: the source panel scrolls vertically (a window centred on the line
    # under evaluation) instead of overflowing the screen height, over-long rows are clipped with an ellipsis instead of
    # wrapping, and the event panel keeps a minimum height of {EVENT_PANE_MIN} rows so the narration never collapses to
    # a sliver.
    #
    # Pure ANSI + `io/console` (both stdlib) per ADR-0's zero-runtime-dependency policy. When the output is not a TTY
    # the frames are printed sequentially without cursor control against a default 80×24 layout, which keeps the
    # renderer deterministic under test.
    class TraceRenderer
      RESET = "\e[0m"
      DIM = "\e[90m"
      BOLD = "\e[1m"
      HIGHLIGHT = "\e[7m" # reverse video for the frame's source range

      EVENT_PANE_MIN = 2     # minimum event-panel rows
      SCOPE_WIDTH_MIN = 19   # minimum scope-column width
      BODY_HEIGHT_MIN = 3    # never shrink the source window below this
      DEFAULT_SIZE = [24, 80].freeze

      # @param out [IO]
      # @param source [String] the traced file's source.
      # @param file [String] display path.
      def initialize(out:, source:, file:)
        @out = out
        @source = source
        @file = file
        @lines = source.lines.map(&:chomp)
      end

      # @param events [Array<Rigor::Inference::FlowTracer::Event>] the
      #   pre-filtered frame list (the command owns kind filtering).
      # @param delay [Float, nil] seconds between frames (autoplay);
      #   nil = step on key press when interactive.
      # @param interactive [Boolean] whether to clear/redraw and wait.
      def play(events, delay: nil, interactive: false)
        @rows, @cols = interactive ? terminal_size : DEFAULT_SIZE
        @interactive = interactive
        locals_per_frame = accumulate_locals(events)
        events.each_with_index do |event, index|
          @out.print("\e[H\e[2J") if interactive
          render_frame(event, index: index, total: events.size, locals: locals_per_frame[index])
          @out.puts unless interactive
          next if index == events.size - 1

          if delay
            sleep(delay)
          elsif interactive
            break unless next_frame?
          end
        end
      end

      private

      # `IO.console` reflects the controlling terminal even when stdout is, say, a StringIO under test — which is why
      # the measured size is only used for interactive replays.
      def terminal_size
        require "io/console"
        size = IO.console&.winsize
        return size if size && size[0].positive? && size[1].positive?

        DEFAULT_SIZE
      rescue LoadError, SystemCallError
        DEFAULT_SIZE
      end

      # Replays :bind events into a per-frame snapshot of the locals panel, so frame N shows exactly the bindings
      # visible after the first N events.
      def accumulate_locals(events)
        locals = {}
        events.map do |event|
          locals[event.data[:name]] = event.data[:type] if event.kind == :bind
          locals.dup
        end
      end

      def render_frame(event, index:, total:, locals:)
        inner = @cols - 3 # three vertical borders
        lines = event_pane_lines(event, inner - 1)
        body_height = body_height_for(lines.size)

        source_rows = source_panel_rows(event)
        left_width, right_width = column_widths(source_rows, inner)
        source_rows = clip_rows(scroll_window(source_rows, body_height), left_width)
        scope_rows = fit_rows(scope_panel_rows(locals), body_height, right_width)

        @out.puts(top_border(left_width, right_width))
        body_rows(source_rows, scope_rows, left_width, right_width)
        @out.puts(divider(left_width, right_width, label: " step #{index + 1}/#{total} · #{event.kind} "))
        lines.each { |line| @out.puts(boxed_line(line, left_width + right_width + 1)) }
        @out.puts(bottom_border(left_width + right_width + 1))
      end

      # Screen budget: borders (3 rows) + event pane + the key-hint row when stepping interactively; whatever remains
      # belongs to the source/scope body, floored at {BODY_HEIGHT_MIN}.
      def body_height_for(event_rows)
        chrome = 3 + event_rows + (@interactive ? 1 : 0)
        [@rows - chrome, BODY_HEIGHT_MIN].max
      end

      # The event pane keeps at least {EVENT_PANE_MIN} rows (padding with blanks) so the bottom of the frame is visually
      # stable across event kinds; over-long lines are clipped to the frame width.
      def event_pane_lines(event, max_width)
        lines = [describe_event(event), stack_line(event)].compact
        lines << "" while lines.size < EVENT_PANE_MIN
        lines.map { |line| clip(line, max_width) }
      end

      # Source rows win the width contest; the scope column keeps its minimum and absorbs whatever the source does not
      # need.
      def column_widths(source_rows, inner)
        left_need = (source_rows.map { |raw, _| raw.length }.max || 0) + 1
        left_width = left_need.clamp(24, [inner - SCOPE_WIDTH_MIN, 24].max)
        [left_width, [inner - left_width, SCOPE_WIDTH_MIN].max]
      end

      # Vertical scroll: when the panel is taller than the window, keep a slice centred on the row under evaluation (the
      # `▶` row, which the marker row directly follows).
      def scroll_window(rows, height)
        return rows if rows.size <= height

        focus = rows.index { |raw, _| raw.start_with?("▶") } || 0
        start = (focus - (height / 2)).clamp(0, rows.size - height)
        rows[start, height]
      end

      def clip_rows(rows, width)
        rows.map do |raw, painted|
          next [raw, painted] if raw.length <= width

          # Re-paint from the clipped raw text — clipping the painted string directly would cut ANSI escapes in half.
          clipped = clip(raw, width)
          [clipped, repaint_clipped(clipped)]
        end
      end

      # A clipped row loses its highlight/marker alignment guarantees, so it is repainted with plain syntax colouring
      # (gutter dimmed).
      def repaint_clipped(clipped)
        gutter = clipped[0, 6]
        rest = clipped[6..] || ""
        DIM + gutter + RESET + PrismColorizer.colorize(rest).chomp
      end

      def fit_rows(rows, height, width)
        rows = rows[0, height - 1] + ["  … (+#{rows.size - height + 1} more)"] if rows.size > height
        rows.map { |row| clip(row, width) }
      end

      def clip(text, width)
        return text if text.length <= width

        "#{text[0, [width - 1, 0].max]}…"
      end

      # Each row is `[raw_text, painted_text]` so width math runs on the escape-free string. The row under the event's
      # source range gets a `▔▔▔` marker row injected after it.
      def source_panel_rows(event)
        rows = []
        location = event.location
        @lines.each_with_index do |line, i|
          number = i + 1
          current = location && number == location[:start_line]
          gutter = "#{current ? '▶' : ' '}#{number.to_s.rjust(3)}  "
          raw = gutter + line
          painted = (current ? BOLD + gutter + RESET : DIM + gutter + RESET) + paint_line(line, location, number)
          rows << [raw, painted]
          rows << marker_row(gutter.length, line, location) if current
        end
        rows
      end

      def marker_row(gutter_width, line, location)
        before, slice, = split_at_range(line, location)
        indent = " " * (gutter_width + before.length)
        width = [slice.length, 1].max
        [indent + ("▔" * width), indent + BOLD + ("▔" * width) + RESET]
      end

      # Highlights the in-range slice with reverse video; everything else gets Prism syntax colouring. The highlight is
      # applied on the raw slice (not the colorized string) so byte offsets stay honest.
      def paint_line(line, location, number)
        return PrismColorizer.colorize(line) unless location && number == location[:start_line]

        before, slice, after = split_at_range(line, location)
        return PrismColorizer.colorize(line) if slice.empty?

        PrismColorizer.colorize(before).chomp +
          HIGHLIGHT + slice + RESET +
          PrismColorizer.colorize(after).chomp
      end

      # Prism columns are BYTE columns — split the line with byteslice so a multibyte character earlier on the line
      # cannot shift (or overrun) the highlight range. Returns `[before, slice, after]`.
      def split_at_range(line, location)
        from = [location[:start_column], line.bytesize].min
        to = location[:end_line] == location[:start_line] ? [location[:end_column], line.bytesize].min : line.bytesize
        to = from if to < from
        [line.byteslice(0, from), line.byteslice(from, to - from), line.byteslice(to, line.bytesize - to) || ""]
      end

      def scope_panel_rows(locals)
        return [" (no locals yet)"] if locals.empty?

        width = locals.keys.map(&:length).max
        locals.map { |name, type| format(" %-#{width}s : %s", name, type) }
      end

      def describe_event(event)
        data = event.data
        case event.kind
        when :bind then "bind     #{data[:name]} ← #{data[:type]}"
        when :union then "union    #{data[:members].join(' | ')}  →  #{data[:type]}"
        when :dispatch then describe_dispatch(data)
        when :enter then "eval     #{data[:node]}"
        when :result then "result   #{data[:node]}  →  #{data[:type]}"
        else "#{event.kind}  #{data.inspect}"
        end
      end

      def describe_dispatch(data)
        call = "#{data[:receiver]} ##{data[:method]}(#{data[:args].join(', ')})"
        return "dispatch #{call}  →  #{data[:type]}" if data[:resolved]

        "dispatch #{call}  →  no rule matched (fail-soft → Dynamic[top])"
      end

      def stack_line(event)
        return nil if event.stack.empty?

        "stack    #{event.stack.join(' › ')}"
      end

      # -- box drawing ---------------------------------------------------

      def top_border(left, right)
        "┌#{pad_label("─ #{@file} ", left)}┬#{pad_label('─ scope ', right)}┐"
      end

      # Pads `label` with `─` to exactly `width` cells (truncating an over-long label so the frame never breaks).
      def pad_label(label, width)
        label = "#{label[0, width - 2]} " if label.length > width
        label + ("─" * [width - label.length, 0].max)
      end

      def body_rows(source_rows, scope_rows, left, right)
        [source_rows.size, scope_rows.size].max.times do |i|
          raw, painted = source_rows[i] || ["", ""]
          scope = scope_rows[i] || ""
          @out.puts("│#{painted}#{' ' * [left - raw.length, 0].max}│#{scope}#{' ' * [right - scope.length, 0].max}│")
        end
      end

      def divider(left, right, label:)
        "├#{pad_label(label, left)}┴#{'─' * right}┤"
      end

      def boxed_line(text, width)
        "│ #{text}#{' ' * [width - text.length - 1, 0].max}│"
      end

      def bottom_border(width)
        "└#{'─' * width}┘"
      end

      # Single-keystroke stepping via stdlib io/console; falls back to line-buffered Enter when raw mode is unavailable
      # (e.g. pipes that still claim to be TTYs). Returns false when the user quits.
      def next_frame?
        @out.print("#{DIM}  [any key: next · q: quit]#{RESET}")
        key = read_key
        @out.print("\r\e[K")
        key != "q"
      end

      def read_key
        require "io/console"
        $stdin.getch
      rescue LoadError, Errno::ENOTTY, Errno::ENODEV
        $stdin.gets&.strip
      end
    end
  end
end
