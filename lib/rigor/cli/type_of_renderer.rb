# frozen_string_literal: true

require "json"
require "optionparser"

require_relative "renderable"

module Rigor
  class CLI
    # Renders a `TypeOfCommand::Result` as either human-readable text or a machine-readable JSON document.
    #
    # The renderer is a separate concern from the command itself so that future output formats (sexp, lsp-style hover
    # payloads, color decoration) can plug in without disturbing argument parsing or the inference call site.
    class TypeOfRenderer
      include Renderable

      def initialize(out:)
        @out = out
      end

      private

      # Takes the whole result list: one invocation can now answer several positions, and a bare `FILE:LINE`
      # answers every expression on that line. Blocks are separated by a blank line so a multi-result run stays
      # readable; a single result renders byte-identically to before.
      def render_text(results)
        list = Array(results)
        return render_enumeration(list) if list.any? && list.all?(&:enumerated)

        list.each_with_index do |result, index|
          @out.puts("") unless index.zero?
          render_one_text(result)
        end
      end

      # A bare `FILE:LINE` asks "what are the types on this line", and the answer is a table: one row per
      # expression, outermost first at each column, so a method chain reads top to bottom.
      def render_enumeration(results)
        @out.puts("#{results.first.file}:#{results.first.line}")
        render_enumeration_rows(results)
        # After the table, never interleaved with it: a `--trace` fallback list between two rows would break the
        # column alignment the whole form exists for.
        results.each { |result| render_text_fallbacks(result) }
      end

      def render_enumeration_rows(results)
        width = results.map { |result| node_label(result).length }.max
        results.each do |result|
          @out.puts(format("  %4d  %-#{width}s  %s", result.column, node_label(result), result.type.describe))
        end
      end

      def node_label(result)
        result.node.class.name.to_s.delete_prefix("Prism::")
      end

      def render_one_text(result)
        @out.puts("#{result.file}:#{result.line}:#{result.column}")
        @out.puts("node:    #{result.node.class}")
        @out.puts("type:    #{result.type.describe}")
        @out.puts("erased:  #{result.type.erase_to_rbs}")
        render_text_fallbacks(result)
      end

      def render_text_fallbacks(result)
        tracer = result.tracer
        return if tracer.nil?

        if tracer.empty?
          @out.puts("fallbacks: none")
        else
          @out.puts("fallbacks (#{tracer.size}):")
          tracer.each { |event| @out.puts("  - #{format_fallback_text(event, result.file)}") }
        end
      end

      # A single result keeps the flat object it has always emitted, so existing consumers are untouched; a
      # multi-position request wraps them in `results` rather than printing several documents to one stream.
      def render_json(results)
        list = Array(results)
        payload = list.size == 1 ? result_to_h(list.first) : { results: list.map { |r| result_to_h(r) } }
        @out.puts(JSON.pretty_generate(payload))
      end

      def result_to_h(result)
        payload = {
          file: result.file,
          line: result.line,
          column: result.column,
          node: result.node.class.name,
          type: result.type.describe,
          erased: result.type.erase_to_rbs
        }
        payload[:fallbacks] = result.tracer.map { |event| fallback_to_h(event) } if result.tracer
        payload
      end

      def format_fallback_text(event, file)
        "#{event.node_class} (#{event.family}) @ #{location_text(event.location, file)}"
      end

      def location_text(location, file)
        return "<no location>" unless location.respond_to?(:start_line)

        "#{file}:#{location.start_line}:#{location.start_column + 1}"
      end

      def fallback_to_h(event)
        hash = {
          node_class: event.node_class.name,
          family: event.family,
          inner_type: event.inner_type.describe
        }
        location = event.location
        if location.respond_to?(:start_line)
          hash[:line] = location.start_line
          hash[:column] = location.start_column + 1
        end
        hash
      end
    end
  end
end
