# frozen_string_literal: true

require "optionparser"

require_relative "../configuration"
require_relative "../analysis/runner"
require_relative "../cache/store"
require_relative "command"
require_relative "effects_renderer"
require_relative "effects_report"
require_relative "options"

module Rigor
  class CLI
    # ADR-103 — executes `rigor effects`.
    #
    # Runs the same analysis `rigor check` runs, with effect collection on, and prints the resulting
    # summaries instead of the diagnostic stream. It is a **report**: it emits no diagnostic, never enters
    # `rigor check`'s stream, and always exits 0 on a successful run. The snapshot verbs (`update`,
    # `check`, `diff`, `explain`) and their drift gate land with #381; this slice is the bare report.
    #
    # The command turns collection on for its own run by loading the project's configuration and enabling
    # an implicit `effects: {}` when the file carries no `effects:` block — the ad-hoc mode ADR-103 WD14
    # describes. A project that *does* configure `effects:` gets its own settings instead.
    class EffectsCommand < Command
      USAGE = "Usage: rigor effects [options] [paths]"

      # @return [Integer] CLI exit status: 0 on success, 64 on a usage error.
      def run
        options = parse_options
        return usage_error("unsupported format: #{options.fetch(:format)}") unless FORMATS.include?(options[:format])

        configuration = Configuration.load(options.fetch(:config)).with_effects_enabled
        table = analyze(configuration)
        report = EffectsReport.build(table, full: options.fetch(:full))
        EffectsRenderer.new(out: @out).render(report, format: options.fetch(:format))
        0
      end

      private

      FORMATS = %w[text json].freeze
      private_constant :FORMATS

      def parse_options
        options = { config: nil, format: "text", full: false }
        OptionParser.new do |opts|
          opts.banner = USAGE
          Options.add_config(opts, options)
          opts.on("--format=FORMAT", "Output format: text (default) or json") { |value| options[:format] = value }
          opts.on("--full", "List every method, including exhaustive ones with no effects beyond mutate.local") do
            options[:full] = true
          end
        end.parse!(@argv)
        options
      end

      def usage_error(message)
        @err.puts(message)
        @err.puts(USAGE)
        CLI::EXIT_USAGE
      end

      # Sequential and cache-backed. The store still serves the RBS-environment and plugin-producer tiers;
      # the ADR-45 whole-run *result* cache declines on its own for a collecting run, because a
      # cache-served run collects nothing and the table would come back empty (the persisted sidecar that
      # lifts this is #382).
      def analyze(configuration)
        runner = Analysis::Runner.new(
          configuration: configuration,
          cache_store: Cache::Store.new(root: configuration.cache_path),
          collect_stats: false,
          workers: 0
        )
        runner.run(@argv.empty? ? configuration.paths : @argv)
        runner.effect_table
      end
    end
  end
end
