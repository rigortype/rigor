# frozen_string_literal: true

require "json"
require "optionparser"

module Rigor
  class CLI
    # Renders a `TypeScanCommand::Report` as either a terminal-friendly text
    # summary or a JSON document suitable for CI ingestion. Text and JSON
    # branches share a single source of truth (the `Report` value object) so
    # the two formats stay in lockstep; that pairing is why this class is a
    # bit longer than the default class-length budget.
    class TypeScanRenderer # rubocop:disable Metrics/ClassLength
      def initialize(out:)
        @out = out
      end

      def render(report, format:)
        case format
        when "text" then render_text(report)
        when "json" then render_json(report)
        else
          raise OptionParser::InvalidArgument, "unsupported format: #{format}"
        end
      end

      private

      def render_text(report)
        render_text_header(report)
        render_text_summary(report)
        render_text_class_table(report)
        render_text_events(report)
        render_text_parse_errors(report)
      end

      def render_text_header(report)
        files = report.files
        suffix = files.size == 1 ? "" : "s"
        @out.puts("Type-of scan: #{files.size} file#{suffix}")
        files.first(5).each { |f| @out.puts("  - #{f}") }
        @out.puts("  ... (#{files.size - 5} more)") if files.size > 5
        @out.puts("")
      end

      def render_text_summary(report)
        processed = report.files.size - report.parse_errors.size
        visited = report.visited_count
        unrec = report.unrecognized_count

        @out.puts("Summary:")
        @out.puts("  files processed:   #{processed}")
        @out.puts("  parse errors:      #{report.parse_errors.size}")
        @out.puts("  AST nodes visited: #{visited}")
        @out.puts("  unrecognized:      #{unrec}#{percent_suffix(unrec, visited)}")
        @out.puts("")
      end

      def render_text_class_table(report)
        rows = build_class_rows(report)
        return if rows.empty?

        width = rows.map { |row| row[:name].size }.max
        @out.puts("Coverage by node class (unrecognized/visits):")
        rows.each { |row| @out.puts(format_class_row(row, width)) }
        @out.puts("")
      end

      def format_class_row(row, width)
        suffix = percent_suffix(row[:unrecognized], row[:visits])
        "  #{row[:name].ljust(width)}  #{row[:unrecognized]}/#{row[:visits]}#{suffix}"
      end

      def build_class_rows(report)
        rows = report.visits.map do |klass, visits|
          unrec = report.unrecognized[klass] || 0
          { name: klass.name, visits: visits, unrecognized: unrec }
        end
        rows.reject! { |row| row[:unrecognized].zero? } unless report.options[:show_recognized]
        rows.sort_by! do |row|
          ratio = row[:visits].zero? ? 0.0 : row[:unrecognized].fdiv(row[:visits])
          [-ratio, -row[:unrecognized], row[:name]]
        end
        rows
      end

      def render_text_events(report)
        events = report.events
        return if events.empty?

        limit = report.options[:limit] || events.size
        shown = events.first(limit)
        @out.puts("Unrecognized examples (showing #{shown.size} of #{events.size}):")
        shown.each do |located|
          @out.puts("  #{located.event.node_class}  @  #{location_text(located)}")
        end
        @out.puts("")
      end

      def render_text_parse_errors(report)
        return if report.parse_errors.empty?

        @out.puts("Parse errors:")
        report.parse_errors.each do |entry|
          @out.puts("  #{entry[:file]}: #{entry[:errors].join('; ')}")
        end
      end

      def render_json(report)
        @out.puts(JSON.pretty_generate(json_payload(report)))
      end

      def json_payload(report)
        {
          files: report.files,
          summary: {
            files_processed: report.files.size - report.parse_errors.size,
            parse_errors: report.parse_errors.size,
            visited: report.visited_count,
            unrecognized: report.unrecognized_count,
            unrecognized_ratio: report.unrecognized_ratio
          },
          by_class: by_class_payload(report),
          events: report.events.map { |located| event_payload(located) },
          parse_errors: report.parse_errors.map do |entry|
            { file: entry[:file], errors: entry[:errors] }
          end
        }
      end

      def by_class_payload(report)
        report.visits.sort_by { |klass, _| klass.name }.to_h do |klass, visits|
          [klass.name, { visits: visits, unrecognized: report.unrecognized[klass] || 0 }]
        end
      end

      def event_payload(located)
        location = located.event.location
        payload = {
          file: located.file,
          node_class: located.event.node_class.name,
          family: located.event.family
        }
        if location.respond_to?(:start_line)
          payload[:line] = location.start_line
          payload[:column] = location.start_column + 1
        end
        payload
      end

      def location_text(located)
        location = located.event.location
        return "<no location>" unless location.respond_to?(:start_line)

        "#{located.file}:#{location.start_line}:#{location.start_column + 1}"
      end

      def percent_suffix(numerator, denominator)
        return "" if denominator.zero?

        " (#{(numerator.fdiv(denominator) * 100).round(1)}%)"
      end
    end
  end
end
