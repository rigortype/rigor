# frozen_string_literal: true

require_relative "prism_colorizer"

module Rigor
  class CLI
    # Replays a `Rigor::Inference::FlowTracer` event stream as a terminal
    # animation for `rigor trace`. Each frame draws a box-drawn screen:
    # the source panel (syntax-coloured, current node range underlined)
    # side-by-side with the scope panel (locals accumulated from :bind
    # events), and an event panel describing the current step and the
    # expression stack.
    #
    # Pure ANSI + `io/console` (both stdlib) per ADR-0's zero-runtime-
    # dependency policy. When the output is not a TTY the frames are
    # printed sequentially without cursor control, which keeps the
    # renderer deterministic under test.
    class TraceRenderer
      RESET = "\e[0m"
      DIM = "\e[90m"
      BOLD = "\e[1m"
      HIGHLIGHT = "\e[7m" # reverse video for the frame's source range

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

      # Replays :bind events into a per-frame snapshot of the locals
      # panel, so frame N shows exactly the bindings visible after the
      # first N events.
      def accumulate_locals(events)
        locals = {}
        events.map do |event|
          locals[event.data[:name]] = event.data[:type] if event.kind == :bind
          locals.dup
        end
      end

      def render_frame(event, index:, total:, locals:)
        source_rows = source_panel_rows(event)
        scope_rows = scope_panel_rows(locals)
        lines = event_lines(event)
        left_width = panel_width(source_rows.map(&:first), minimum: 24)
        right_width = panel_width(scope_rows, minimum: 18)
        # Widen the scope column so the event panel (whose box spans both
        # columns) never overflows the frame.
        widest_event = lines.map(&:length).max || 0
        right_width = [right_width, widest_event + 1 - left_width].max

        @out.puts(top_border(left_width, right_width))
        body_rows(source_rows, scope_rows, left_width, right_width)
        @out.puts(divider(left_width, right_width, label: " step #{index + 1}/#{total} · #{event.kind} "))
        lines.each { |line| @out.puts(boxed_line(line, left_width + right_width + 1)) }
        @out.puts(bottom_border(left_width + right_width + 1))
      end

      # Each row is `[raw_text, painted_text]` so width math runs on the
      # escape-free string. The row under the event's source range gets a
      # `▔▔▔` marker row injected after it.
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

      # Highlights the in-range slice with reverse video; everything else
      # gets Prism syntax colouring. The highlight is applied on the raw
      # slice (not the colorized string) so byte offsets stay honest.
      def paint_line(line, location, number)
        return PrismColorizer.colorize(line) unless location && number == location[:start_line]

        before, slice, after = split_at_range(line, location)
        return PrismColorizer.colorize(line) if slice.empty?

        PrismColorizer.colorize(before).chomp +
          HIGHLIGHT + slice + RESET +
          PrismColorizer.colorize(after).chomp
      end

      # Prism columns are BYTE columns — split the line with byteslice
      # so a multibyte character earlier on the line cannot shift (or
      # overrun) the highlight range. Returns `[before, slice, after]`.
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

      def event_lines(event)
        [describe_event(event), stack_line(event)].compact
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

      def panel_width(raw_rows, minimum:)
        [raw_rows.map(&:length).max || 0, minimum].max + 1
      end

      def top_border(left, right)
        "┌#{pad_label("─ #{@file} ", left)}┬#{pad_label('─ scope ', right)}┐"
      end

      # Pads `label` with `─` to exactly `width` cells (truncating an
      # over-long label so the frame never breaks).
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

      # Single-keystroke stepping via stdlib io/console; falls back to
      # line-buffered Enter when raw mode is unavailable (e.g. pipes that
      # still claim to be TTYs). Returns false when the user quits.
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
