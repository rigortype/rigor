# frozen_string_literal: true

require "json"
require "optionparser"

require_relative "../bleeding_edge"
require_relative "../configuration"
require_relative "command"

module Rigor
  class CLI
    # Executes `rigor show-bleedingedge` (ADR-50 § WD2).
    #
    # Prints the bleeding-edge overlay — the Rigor-maintained set of the
    # next major's queued changes ({Rigor::BleedingEdge}) — as an
    # explicit list, and reports which of them the project's
    # `bleeding_edge:` configuration adopts. The overlay is empty in this
    # release, so the command currently reports an empty set; it becomes
    # the inspection surface ADR-50 describes once a feature is queued.
    #
    # Read-only: it loads `.rigor.yml` to resolve the active selection
    # but runs no analysis.
    class ShowBleedingedgeCommand < Command
      USAGE = "Usage: rigor show-bleedingedge [options]"

      # @return [Integer] CLI exit status.
      def run
        options = parse_options
        configuration = load_configuration(options)
        return CLI::EXIT_USAGE if configuration.nil?

        case options.fetch(:format)
        when "json" then render_json(configuration)
        else render_text(configuration)
        end
        0
      end

      private

      def parse_options
        options = { format: "text", config: nil }
        OptionParser.new do |opt|
          opt.banner = USAGE
          opt.on("--format=FORMAT", %w[text json], "Output format (text | json). Default: text.") do |fmt|
            options[:format] = fmt
          end
          opt.on("--config=PATH", "Path to a .rigor.yml (default: auto-discovery).") do |path|
            options[:config] = path
          end
        end.parse!(@argv)
        options
      end

      def load_configuration(options)
        Configuration.load(options.fetch(:config))
      rescue StandardError => e
        @err.puts("show-bleedingedge: could not load configuration: #{e.message}")
        nil
      end

      def render_json(configuration)
        selector = configuration.bleeding_edge
        @out.puts(JSON.pretty_generate(
                    "overlay" => BleedingEdge.features.map(&:to_h),
                    "selector" => configuration.to_h.fetch("bleeding_edge"),
                    "active" => BleedingEdge.active_features(selector).map(&:id),
                    "unknown_selected" => BleedingEdge.unknown_selected_ids(selector)
                  ))
      end

      def render_text(configuration)
        @out.puts("Bleeding-edge overlay (ADR-50 § WD2)")
        @out.puts("")
        if BleedingEdge.features.empty?
          render_empty_overlay
        else
          render_overlay
        end
        @out.puts("")
        render_selection(configuration)
      end

      def render_empty_overlay
        @out.puts("The overlay is empty in this release — no features are queued for")
        @out.puts("the next major. The `bleeding_edge:` mechanism is wired and ready;")
        @out.puts("there is simply nothing to adopt yet.")
      end

      def render_overlay
        @out.puts("#{BleedingEdge.features.length} feature(s) queued for the next major:")
        @out.puts("")
        BleedingEdge.features.each do |feature|
          @out.puts("  #{feature.id}")
          @out.puts("    #{feature.summary}")
          feature.severity_overrides.each do |rule, severity|
            @out.puts("    severity: #{rule} → :#{severity}")
          end
        end
      end

      def render_selection(configuration)
        selector = configuration.bleeding_edge
        active = BleedingEdge.active_features(selector).map(&:id)
        @out.puts("Your configuration adopts: #{active.empty? ? '(none)' : active.join(', ')}")

        unknown = BleedingEdge.unknown_selected_ids(selector)
        return if unknown.empty?

        @out.puts("Selected but not in this overlay (ignored): #{unknown.join(', ')}")
      end
    end
  end
end
