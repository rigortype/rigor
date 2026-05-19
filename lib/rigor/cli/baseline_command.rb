# frozen_string_literal: true

require "optparse"

require_relative "../analysis/baseline"
require_relative "../analysis/runner"
require_relative "../cache/store"
require_relative "../configuration"

module Rigor
  class CLI
    # ADR-22 Slice 1 — `rigor baseline {generate}` subcommands.
    # Backed by `Rigor::Analysis::Baseline`. Future slices
    # extend the subcommand surface with `dump`, `drift`,
    # `prune`, `regenerate`.
    #
    # Initial subcommand: `generate`.
    #
    #   rigor baseline generate              # default: rule-ID rows
    #   rigor baseline generate --match-mode message
    #   rigor baseline generate --force      # overwrite existing
    #   rigor baseline generate --output=PATH
    class BaselineCommand
      EXIT_USAGE = 64
      DEFAULT_BASELINE_PATH = ".rigor-baseline.yml"

      SUBCOMMANDS = %w[generate].freeze

      def initialize(argv:, out: $stdout, err: $stderr)
        @argv = argv
        @out = out
        @err = err
      end

      def run
        subcommand = @argv.shift
        case subcommand
        when nil, "help", "-h", "--help"
          @out.puts(help)
          0
        when "generate"
          run_generate
        else
          @err.puts("Unknown baseline subcommand: #{subcommand.inspect}")
          @err.puts(help)
          EXIT_USAGE
        end
      rescue OptionParser::ParseError => e
        @err.puts(e.message)
        EXIT_USAGE
      end

      private

      def run_generate
        options = parse_generate_options
        path = options.fetch(:output)

        if File.exist?(path) && !options.fetch(:force)
          @err.puts("rigor: #{path} already exists. Re-run with --force to overwrite.")
          return EXIT_USAGE
        end

        configuration = Configuration.load(options.fetch(:config))
        diagnostics = collect_diagnostics(configuration, options)

        baseline = Analysis::Baseline.from_diagnostics(diagnostics, match_mode: options.fetch(:match_mode))
        File.write(path, baseline.to_yaml)

        bucket_count = baseline.size
        diagnostic_count = diagnostics.size
        @err.puts(
          "rigor: wrote baseline to #{path} " \
          "(#{bucket_count} bucket(s) covering #{diagnostic_count} diagnostic(s); " \
          "match-mode: #{options.fetch(:match_mode)})"
        )
        if configuration.baseline_path.nil?
          @err.puts(
            "rigor: note — `.rigor.yml` does not declare `baseline:`; " \
            "add `baseline: #{path}` to activate the suppression."
          )
        end
        0
      end

      def parse_generate_options
        options = {
          config: nil,
          output: DEFAULT_BASELINE_PATH,
          match_mode: :rule,
          force: false
        }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: rigor baseline generate [options]"
          opts.on("--config=PATH", "Path to the Rigor configuration file") { |v| options[:config] = v }
          opts.on("--output=PATH", "Write baseline to PATH (default: #{DEFAULT_BASELINE_PATH})") do |v|
            options[:output] = v
          end
          opts.on("--match-mode=MODE", %i[rule message],
                  "Row form: rule (default) or message") do |v|
            options[:match_mode] = v
          end
          opts.on("--force", "Overwrite an existing baseline file") { options[:force] = true }
        end
        parser.parse!(@argv)
        options
      end

      def collect_diagnostics(configuration, _options)
        cache_store = Cache::Store.new(root: configuration.cache_path)
        # IMPORTANT: do NOT activate the existing baseline when
        # generating a fresh one — otherwise the new file
        # records the post-filter (silenced) diagnostic set,
        # which is empty after a successful first run.
        configuration_for_generation = override_configuration_baseline_off(configuration)
        runner = Analysis::Runner.new(
          configuration: configuration_for_generation,
          cache_store: cache_store,
          collect_stats: false
        )
        runner.run(configuration_for_generation.paths).diagnostics
      end

      def override_configuration_baseline_off(configuration)
        # Synthesise a new Configuration with `baseline` explicitly
        # disabled. The original Configuration is frozen-ish so we
        # round-trip through the constructor with an override hash.
        defaults = Configuration::DEFAULTS.merge(
          "paths" => configuration.paths,
          "exclude" => configuration.exclude_patterns,
          "plugins" => configuration.plugins.map(&:to_h),
          "disable" => configuration.disabled_rules,
          "libraries" => configuration.libraries,
          "signature_paths" => configuration.signature_paths,
          "pre_eval" => configuration.pre_eval,
          "severity_profile" => configuration.severity_profile.to_s,
          "severity_overrides" => configuration.severity_overrides,
          "baseline" => false,
          "cache" => { "path" => configuration.cache_path }
        )
        Configuration.new(defaults)
      end

      def help
        <<~HELP
          Usage: rigor baseline <subcommand> [options]

          Subcommands:
            generate    Write a fresh baseline file from a `rigor check` run.

          Run `rigor baseline <subcommand> --help` for subcommand options.
        HELP
      end
    end
  end
end
