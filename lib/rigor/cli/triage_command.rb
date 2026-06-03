# frozen_string_literal: true

require "optionparser"

require_relative "../configuration"
require_relative "../analysis/runner"
require_relative "../cache/store"
require_relative "../triage"
require_relative "triage_renderer"
require_relative "command"

module Rigor
  class CLI
    # ADR-23 — executes `rigor triage`.
    #
    # Runs the same analysis as `rigor check`, then summarises the
    # diagnostic stream (rule distribution, per-file hotspots,
    # heuristic hints) instead of printing the raw per-line list.
    # Read-only and advisory (WD4): never edits config, never
    # writes a baseline. Always exits 0 — it is an inspection
    # command, not a gate (`rigor check` remains the gate).
    class TriageCommand < Command
      USAGE = "Usage: rigor triage [options] [paths]"
      DEFAULT_SECTIONS = %i[distribution hotspots hints].freeze

      # @return [Integer] CLI exit status (always 0).
      def run
        options = parse_options
        configuration = Configuration.load(options.fetch(:config))
        diagnostics = analyze(configuration)

        report = Triage.analyze(diagnostics, top: options.fetch(:top),
                                             hints: options.fetch(:sections).include?(:hints))
        renderer = TriageRenderer.new(report, sections: options.fetch(:sections))
        @out.puts(options.fetch(:format) == "json" ? renderer.json : renderer.text)
        0
      end

      private

      def parse_options
        options = { config: nil, format: "text", top: 10, sections: DEFAULT_SECTIONS }
        OptionParser.new do |opts|
          opts.banner = USAGE
          opts.on("--config=PATH", "Path to the Rigor configuration file") { |v| options[:config] = v }
          opts.on("--format=FORMAT", "Output format: text (default) or json") { |v| options[:format] = v }
          opts.on("--top=N", Integer, "Hotspot-file count (default 10)") { |v| options[:top] = v }
          opts.on("--hints-only", "Print only the heuristic-hints section") { options[:sections] = %i[hints] }
          opts.on("--no-hints", "Print distribution + hotspots only") do
            options[:sections] = %i[distribution hotspots]
          end
        end.parse!(@argv)
        validate!(options)
        options
      end

      def validate!(options)
        return if %w[text json].include?(options.fetch(:format))

        raise OptionParser::InvalidArgument, "unsupported format: #{options.fetch(:format)}"
      end

      # Sequential, cache-backed, no run-stats: triage only needs
      # the diagnostic stream, and sequential keeps the rule
      # distribution deterministic (the fork pool's cross-file
      # divergence would skew the histogram).
      def analyze(configuration)
        runner = Analysis::Runner.new(
          configuration: configuration,
          cache_store: Cache::Store.new(root: configuration.cache_path),
          collect_stats: false,
          workers: 0
        )
        runner.run(@argv.empty? ? configuration.paths : @argv).diagnostics
      end
    end
  end
end
