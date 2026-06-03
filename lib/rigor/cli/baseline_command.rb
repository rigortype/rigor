# frozen_string_literal: true

require "optparse"

require_relative "../analysis/baseline"
require_relative "../analysis/runner"
require_relative "../cache/store"
require_relative "../configuration"
require_relative "command"

module Rigor
  class CLI
    # ADR-22 — `rigor baseline {generate,regenerate,dump,drift,
    # prune}` subcommands, backed by `Rigor::Analysis::Baseline`.
    #
    #   rigor baseline generate              # default: rule-ID rows
    #   rigor baseline generate --match-mode message
    #   rigor baseline generate --force      # overwrite existing
    #   rigor baseline generate --output=PATH
    #   rigor baseline regenerate            # slice 5: unconditional rewrite
    #   rigor baseline dump
    #   rigor baseline drift
    #   rigor baseline prune
    class BaselineCommand < Command # rubocop:disable Metrics/ClassLength
      EXIT_USAGE = 64
      DEFAULT_BASELINE_PATH = ".rigor-baseline.yml"

      SUBCOMMANDS = %w[generate regenerate dump drift prune].freeze

      def run
        subcommand = @argv.shift
        case subcommand
        when nil, "help", "-h", "--help"
          @out.puts(help)
          0
        when "generate" then run_generate
        when "regenerate" then run_regenerate
        when "dump" then run_dump
        when "drift" then run_drift
        when "prune" then run_prune
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
          @err.puts("rigor: #{path} already exists. Re-run with --force to " \
                    "overwrite, or use `rigor baseline regenerate`.")
          return EXIT_USAGE
        end

        write_baseline(options, verb: "wrote baseline to")
      end

      # ADR-22 slice 5 — `regenerate` is `generate --force`: the
      # end-of-quality-improvement-session refresh after landing
      # baseline-reducing fixes. It rewrites the file
      # unconditionally (no existence guard, no `--force` flag),
      # so `rigor baseline regenerate` reads cleanly as "make the
      # baseline match reality again".
      def run_regenerate
        options = parse_generate_options(subcommand: "regenerate")
        write_baseline(options, verb: "regenerated baseline")
      end

      def write_baseline(options, verb:)
        path = options.fetch(:output)
        configuration = Configuration.load(options.fetch(:config))
        diagnostics = collect_diagnostics(configuration, options)

        baseline = Analysis::Baseline.from_diagnostics(diagnostics, match_mode: options.fetch(:match_mode),
                                                                    project_root: Dir.pwd)
        File.write(path, baseline.to_yaml)

        @err.puts(
          "rigor: #{verb} #{path} " \
          "(#{baseline.size} bucket(s) covering #{diagnostics.size} diagnostic(s); " \
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

      def parse_generate_options(subcommand: "generate")
        options = {
          config: nil,
          output: DEFAULT_BASELINE_PATH,
          match_mode: :rule,
          force: false
        }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: rigor baseline #{subcommand} [options]"
          opts.on("--config=PATH", "Path to the Rigor configuration file") { |v| options[:config] = v }
          opts.on("--output=PATH", "Write baseline to PATH (default: #{DEFAULT_BASELINE_PATH})") do |v|
            options[:output] = v
          end
          opts.on("--match-mode=MODE", %i[rule message],
                  "Row form: rule (default) or message") do |v|
            options[:match_mode] = v
          end
          # `regenerate` always overwrites — no `--force` to offer.
          if subcommand == "generate"
            opts.on("--force", "Overwrite an existing baseline file") { options[:force] = true }
          end
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
          "plugins" => configuration.plugins,
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

      # ---- dump --------------------------------------------------

      def run_dump
        options = parse_dump_options
        baseline = load_baseline_or_exit(options.fetch(:baseline))
        return EXIT_USAGE if baseline == :error

        rows = filter_dump_rows(baseline.buckets, options)
        case options.fetch(:format)
        when :json then @out.puts(JSON.pretty_generate(dump_to_json(rows)))
        else dump_text(rows, options)
        end
        0
      end

      def parse_dump_options
        options = { baseline: DEFAULT_BASELINE_PATH, format: :text, rule: nil, file: nil }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: rigor baseline dump [options]"
          opts.on("--baseline=PATH", "Path to the baseline file (default: #{DEFAULT_BASELINE_PATH})") do |v|
            options[:baseline] = v
          end
          opts.on("--format=FORMAT", %i[text json], "Output format: text (default) or json") do |v|
            options[:format] = v
          end
          opts.on("--rule=RULE", "Filter rows by exact rule id") { |v| options[:rule] = v }
          opts.on("--file=GLOB", "Filter rows by File.fnmatch? glob") { |v| options[:file] = v }
        end
        parser.parse!(@argv)
        options
      end

      def filter_dump_rows(buckets, options)
        buckets.select do |b|
          next false if options[:rule] && b.rule != options[:rule]
          next false if options[:file] && !File.fnmatch?(options[:file], b.file)

          true
        end
      end

      def dump_text(rows, options)
        if rows.empty?
          @out.puts("(no baseline rows matching the supplied filters)")
          return
        end

        # Group by rule for readability; rules with the most
        # entries first.
        by_rule = rows.group_by(&:rule).sort_by { |_rule, group| -group.size }
        by_rule.each do |rule, group|
          total = group.sum(&:count)
          @out.puts("#{rule}  (#{group.size} bucket(s), #{total} occurrence(s))")
          group.sort_by { |b| [-b.count, b.file] }.each do |bucket|
            label = if bucket.message_regex
                      "  #{bucket.file}: #{bucket.count}  ~/#{bucket.message_regex.source}/"
                    else
                      "  #{bucket.file}: #{bucket.count}"
                    end
            @out.puts(label)
          end
          @out.puts("")
        end
        @out.puts("Total: #{rows.size} bucket(s), #{rows.sum(&:count)} occurrence(s)")
        _ = options # reserved for future flags
      end

      def dump_to_json(rows)
        {
          "version" => Analysis::Baseline::CURRENT_VERSION,
          "ignored" => rows.map do |b|
            row = { "file" => b.file, "rule" => b.rule, "count" => b.count }
            row["message"] = b.message_regex.source if b.message_regex
            row
          end
        }
      end

      # ---- drift --------------------------------------------------

      def run_drift
        options = parse_drift_options
        baseline = load_baseline_or_exit(options.fetch(:baseline))
        return EXIT_USAGE if baseline == :error

        configuration = Configuration.load(options.fetch(:config))
        diagnostics = collect_diagnostics(configuration, options)
        drift_rows = baseline.audit(diagnostics)

        shown = if options.fetch(:only).nil?
                  drift_rows.reject { |r| r.delta.zero? }
                else
                  drift_rows.select { |r| r.status == options.fetch(:only) }
                end

        if shown.empty?
          @out.puts("No drift detected.")
          return 0
        end

        report_drift_rows(shown, baseline_path: options.fetch(:baseline))
        0
      end

      def parse_drift_options
        options = {
          config: nil,
          baseline: DEFAULT_BASELINE_PATH,
          only: nil
        }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: rigor baseline drift [options]"
          opts.on("--config=PATH", "Path to the Rigor configuration file") { |v| options[:config] = v }
          opts.on("--baseline=PATH", "Path to the baseline file (default: #{DEFAULT_BASELINE_PATH})") do |v|
            options[:baseline] = v
          end
          opts.on("--only=STATUS", %i[within over cleared reducible],
                  "Show only buckets with the given status (within|over|cleared|reducible)") do |v|
            options[:only] = v
          end
        end
        parser.parse!(@argv)
        options
      end

      def report_drift_rows(rows, baseline_path:) # rubocop:disable Metrics/AbcSize
        @out.puts("Drift report against #{baseline_path}:")
        @out.puts("")
        groups = rows.group_by(&:status)
        %i[over cleared reducible within].each do |status|
          group = groups[status] || []
          next if group.empty?

          @out.puts(drift_section_header(status, group.size))
          group.sort_by { |r| [r.bucket.file, r.bucket.rule] }.each do |row|
            delta_str = row.delta.positive? ? "+#{row.delta}" : row.delta.to_s
            @out.puts("  #{row.bucket.file}  [#{row.bucket.rule}]  " \
                      "#{row.bucket.count} → #{row.actual_count}  (Δ#{delta_str})")
          end
          @out.puts("")
        end
      end

      def drift_section_header(status, count)
        case status
        when :over then "## Over threshold (#{count}) — bucket exceeded; check the regular diagnostic output."
        when :cleared then "## Cleared (#{count}) — `rigor baseline prune` can drop these."
        when :reducible then "## Reducible (#{count}) — tightening opportunity; run `rigor baseline regenerate`."
        when :within then "## Within threshold (#{count})"
        end
      end

      # ---- prune --------------------------------------------------

      def run_prune
        options = parse_prune_options
        baseline = load_baseline_or_exit(options.fetch(:baseline))
        return EXIT_USAGE if baseline == :error

        configuration = Configuration.load(options.fetch(:config))
        diagnostics = collect_diagnostics(configuration, options)
        drift_rows = baseline.audit(diagnostics)
        cleared = drift_rows.select { |r| r.status == :cleared }

        if cleared.empty?
          @out.puts("No cleared buckets to prune.")
          return 0
        end

        announce_prune(cleared, options.fetch(:baseline))
        return 0 if options.fetch(:dry_run)

        pruned = baseline.without(cleared.map(&:bucket))
        File.write(options.fetch(:baseline), pruned.to_yaml)
        @err.puts("rigor: pruned #{cleared.size} bucket(s); baseline now has #{pruned.size} entries.")
        0
      end

      def parse_prune_options
        options = {
          config: nil,
          baseline: DEFAULT_BASELINE_PATH,
          dry_run: false
        }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: rigor baseline prune [options]"
          opts.on("--config=PATH", "Path to the Rigor configuration file") { |v| options[:config] = v }
          opts.on("--baseline=PATH", "Path to the baseline file (default: #{DEFAULT_BASELINE_PATH})") do |v|
            options[:baseline] = v
          end
          opts.on("--dry-run", "Show what would be dropped without writing the file") { options[:dry_run] = true }
        end
        parser.parse!(@argv)
        options
      end

      def announce_prune(cleared, baseline_path)
        @out.puts("#{cleared.size} bucket(s) to prune from #{baseline_path}:")
        cleared.sort_by { |r| [r.bucket.file, r.bucket.rule] }.each do |row|
          @out.puts("  - #{row.bucket.file}  [#{row.bucket.rule}]  (was: #{row.bucket.count})")
        end
      end

      # ---- shared helpers ----------------------------------------

      def load_baseline_or_exit(path)
        unless File.exist?(path)
          @err.puts("rigor: baseline file not found: #{path}")
          return :error
        end
        Analysis::Baseline.load(path, project_root: Dir.pwd)
      rescue Analysis::Baseline::LoadError => e
        @err.puts("rigor: baseline load failed: #{e.message}")
        :error
      end

      def help
        <<~HELP
          Usage: rigor baseline <subcommand> [options]

          Subcommands:
            generate    Write a fresh baseline file from a `rigor check` run.
            regenerate  Rewrite the baseline unconditionally (post-fix refresh).
            dump        Print the contents of an existing baseline.
            drift       Compare baseline vs current diagnostics (reduction / regression hints).
            prune       Drop cleared buckets (`actual == 0`) from the baseline.

          Run `rigor baseline <subcommand> --help` for subcommand options.
        HELP
      end
    end
  end
end
