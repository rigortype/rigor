# frozen_string_literal: true

require "optionparser"

require_relative "../configuration"
require_relative "../analysis/runner"
require_relative "../cache/store"
require_relative "command"
require_relative "effects_renderer"
require_relative "effects_report"
require_relative "effects_snapshot_command"
require_relative "options"

module Rigor
  class CLI
    # ADR-103 — executes `rigor effects`.
    #
    # Two surfaces behind one command, the shape `rigor baseline` already has:
    #
    # - `rigor effects [PATH…]` — the **report**. Runs the same analysis `rigor check` runs, with effect
    #   collection on, and prints the resulting summaries instead of the diagnostic stream.
    # - `rigor effects {update,check,diff,explain}` — the committed **effect snapshot** and its drift
    #   gate, in {EffectsSnapshotCommand}.
    #
    # Neither emits a diagnostic nor enters `rigor check`'s stream; the report always exits 0, and only
    # `check` ever exits non-zero (1 on drift, 64 on a usage error).
    #
    # The command turns collection on for its own run by loading the project's configuration and enabling
    # an implicit `effects: {}` when the file carries no `effects:` block — the ad-hoc mode ADR-103 WD14
    # describes. A project that *does* configure `effects:` gets its own settings instead, and then this
    # run shares the whole cache with `rigor check`: the diagnostics come from the ADR-45 run entry and the
    # summaries from the effects sidecar keyed beside it (#382), so `rigor effects` after `rigor check` in
    # the same job is a warm hit plus the fixpoint. The ad-hoc mode digests a different `effects:` block
    # than the project's, so it shares the diagnostics entry and keys its own effects slot.
    class EffectsCommand < Command
      USAGE = "Usage: rigor effects [options] [paths]"

      # @return [Integer] CLI exit status: 0 on success, 1 on `check` drift, 64 on a usage error.
      def run
        verb = @argv.first
        return run_verb(verb) if EffectsSnapshotCommand::VERBS.include?(verb)
        return print_help if %w[help --help -h].include?(verb)

        run_report
      end

      private

      def run_verb(verb)
        @argv.shift
        EffectsSnapshotCommand.new(argv: @argv, verb: verb, out: @out, err: @err).run
      end

      def print_help
        @out.puts(help)
        0
      end

      def help
        <<~HELP
          #{USAGE}

          With no subcommand, prints one line per method: its proven effect labels and whether that
          list is exhaustive.

          Subcommands (the committed effect snapshot, ADR-103 WD7):
            update      Write the snapshot to effects.snapshot.path. Commit it; review its diff.
            check       Recompute and compare; exits 1 on drift, 0 when fresh.
            diff        The same comparison, never gating.
            explain     The shortest edge path behind a reach change (--symbol KEY for one unit).

          Run `rigor effects <subcommand> --help` for subcommand options.
        HELP
      end

      def run_report
        options = parse_options
        return usage_error("unsupported format: #{options.fetch(:format)}") unless FORMATS.include?(options[:format])

        configuration = Configuration.load(options.fetch(:config)).with_effects_enabled
        table = analyze(configuration)
        report = EffectsReport.build(table, full: options.fetch(:full))
        EffectsRenderer.new(out: @out).render(report, format: options.fetch(:format))
        0
      end

      FORMATS = %w[text json].freeze
      private_constant :FORMATS

      def parse_options
        options = { config: nil, format: "text", full: false, no_tolerated: false }
        OptionParser.new do |opts|
          opts.banner = USAGE
          Options.add_config(opts, options)
          opts.on("--format=FORMAT", "Output format: text (default) or json") { |value| options[:format] = value }
          opts.on("--full", "List every method, including exhaustive ones with no effects beyond mutate.local") do
            options[:full] = true
          end
          # Accepted here and deliberately inert, exactly as it is on `update`: the report is an
          # observation, and observations are undischarged. Only a JUDGMENT reads `effects.tolerated:` —
          # `rigor effects check` / `diff`, and `rigor check`'s envelope contract.
          opts.on("--no-tolerated-effects", "Judge as if effects.tolerated: were empty (inert on the report)") do
            options[:no_tolerated] = true
          end
        end.parse!(@argv)
        options
      end

      def usage_error(message)
        @err.puts(message)
        @err.puts(USAGE)
        CLI::EXIT_USAGE
      end

      # Sequential and cache-backed, through the same ADR-45 whole-run result cache `rigor check` uses:
      # the diagnostics entry serves the run and the #382 effects sidecar serves the collections, leaving
      # only the fixpoint. Sequential is not a cache decision — the run-result cache declines pool mode —
      # but a collecting run is pinned to the fork backend anyway, so `workers: 0` costs nothing here.
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
