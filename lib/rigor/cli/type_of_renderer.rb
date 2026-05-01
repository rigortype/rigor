# frozen_string_literal: true

require "json"
require "optionparser"

module Rigor
  class CLI
    # Renders a `TypeOfCommand::Result` as either human-readable text or a
    # machine-readable JSON document.
    #
    # The renderer is a separate concern from the command itself so that future
    # output formats (sexp, lsp-style hover payloads, color decoration) can
    # plug in without disturbing argument parsing or the inference call site.
    class TypeOfRenderer
      def initialize(out:)
        @out = out
      end

      def render(result, format:)
        case format
        when "text" then render_text(result)
        when "json" then render_json(result)
        else
          raise OptionParser::InvalidArgument, "unsupported format: #{format}"
        end
      end

      private

      def render_text(result)
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

      def render_json(result)
        payload = {
          file: result.file,
          line: result.line,
          column: result.column,
          node: result.node.class.name,
          type: result.type.describe,
          erased: result.type.erase_to_rbs
        }
        payload[:fallbacks] = result.tracer.map { |event| fallback_to_h(event) } if result.tracer
        @out.puts(JSON.pretty_generate(payload))
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
