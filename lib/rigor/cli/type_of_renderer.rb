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
      # answers up to 40 expressions on that line. A single exact result renders byte-identically to before.
      def render_text(results)
        list = Array(results)
        index = 0
        first = true
        while index < list.length
          @out.puts("") unless first
          result = list[index]
          enumeration = result.enumeration
          if enumeration
            finish = index + 1
            finish += 1 while finish < list.length && list[finish].enumeration.equal?(enumeration)
            render_enumeration(list[index...finish], enumeration)
            index = finish
          else
            render_one_text(result)
            index += 1
          end
          first = false
        end
      end

      # A bare `FILE:LINE` asks "what are the types on this line", and the answer is a table: one row per
      # expression, outermost first at each column, so a method chain reads top to bottom.
      def render_enumeration(results, enumeration)
        @out.puts("#{results.first.file}:#{results.first.line}")
        render_enumeration_rows(results)
        if enumeration.total > results.length
          omitted = enumeration.total - results.length
          @out.puts("  ... #{omitted} additional expressions omitted (limit #{results.length})")
        end
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
        enumerations = line_enumerations(list)
        payload[:line_enumerations] = enumerations unless enumerations.empty?
        @out.puts(JSON.pretty_generate(payload))
      end

      def line_enumerations(results)
        seen = {}.compare_by_identity
        results.filter_map do |result|
          enumeration = result.enumeration
          next if enumeration.nil? || seen.key?(enumeration)

          seen[enumeration] = true
          { file: result.file, line: result.line, shown: enumeration.shown, total: enumeration.total }
        end
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
