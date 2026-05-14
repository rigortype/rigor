# frozen_string_literal: true

require "json"
require "optionparser"

module Rigor
  class CLI
    # Executes `rigor diff <baseline.json> [paths...]`. Compares
    # the current `rigor check` diagnostics against a saved
    # baseline JSON (the output of a previous `rigor check
    # --format=json` run) and prints the delta:
    #
    # - **new** — diagnostics in the current run that were not
    #   in the baseline (typically a regression introduced in
    #   this PR).
    # - **fixed** — diagnostics in the baseline that no longer
    #   appear in the current run (typically progress).
    #
    # Identity for matching is the tuple
    # `(path, line, column, rule, source_family, message)`.
    # An edit that moves a diagnostic to a new line surfaces as
    # one fixed + one new pair, which lines up with the user's
    # mental model of "you changed the line, the analyzer's
    # position changed too."
    #
    # CI usage: commit a `rigor.baseline.json` produced once
    # with `rigor check --format=json > rigor.baseline.json`,
    # then run `rigor diff rigor.baseline.json` in CI. Exit code
    # is `1` when any new diagnostic appears, `0` otherwise —
    # so adding new errors fails CI but legacy errors recorded
    # in the baseline don't.
    class DiffCommand
      USAGE = "Usage: rigor diff [options] <baseline.json> [paths...]"

      def initialize(argv:, out:, err:)
        @argv = argv
        @out = out
        @err = err
      end

      # @return [Integer] CLI exit status.
      def run
        options = parse_options

        baseline_path = @argv.shift
        if baseline_path.nil?
          @err.puts(USAGE)
          return CLI::EXIT_USAGE
        end

        baseline = load_diagnostics(baseline_path)
        current = options.fetch(:current_path) ? load_diagnostics(options.fetch(:current_path)) : run_current(options)
        return CLI::EXIT_USAGE if baseline.nil? || current.nil?

        diff = compute_diff(baseline, current)
        write_diff(
          diff, options.fetch(:format),
          baseline_path: baseline_path,
          baseline_count: baseline.size,
          current_count: current.size
        )
        diff[:new].any? ? 1 : 0
      end

      private

      def parse_options
        options = { format: "text", current_path: nil, config: nil }
        OptionParser.new do |opt|
          opt.banner = USAGE
          opt.on("--format=FORMAT", %w[text json], "Output format (text | json). Default: text.") do |fmt|
            options[:format] = fmt
          end
          opt.on("--current=PATH", "Compare to the saved current JSON instead of running `rigor check`.") do |path|
            options[:current_path] = path
          end
          opt.on("--config=PATH", "Path to .rigor.yml. Forwarded to the implicit `rigor check` run.") do |path|
            options[:config] = path
          end
        end.parse!(@argv)
        options
      end

      # Runs `rigor check` against the remaining argv (or the
      # configured paths) and returns the diagnostics array.
      # Reuses the analyzer + configuration plumbing the
      # check-command path uses.
      def run_current(options)
        require_relative "../analysis/runner"
        require_relative "../configuration"

        configuration = Configuration.load(options.fetch(:config))
        paths = @argv.empty? ? configuration.paths : @argv
        result = Analysis::Runner.new(configuration: configuration).run(paths)
        result.diagnostics.map(&:to_h)
      end

      def load_diagnostics(path)
        unless File.file?(path)
          @err.puts("Baseline file not found: #{path}")
          return nil
        end

        payload = JSON.parse(File.read(path))
        payload.is_a?(Hash) ? Array(payload["diagnostics"]) : Array(payload)
      rescue JSON::ParserError => e
        @err.puts("Invalid JSON in #{path}: #{e.message}")
        nil
      end

      KEY_FIELDS = %w[path line column rule source_family message].freeze
      private_constant :KEY_FIELDS

      def compute_diff(baseline, current)
        baseline_keys = baseline.to_set { |d| identity_for(d) }
        current_keys = current.to_set { |d| identity_for(d) }

        new_diags = current.reject { |d| baseline_keys.include?(identity_for(d)) }
        fixed = baseline.reject { |d| current_keys.include?(identity_for(d)) }
        { new: new_diags, fixed: fixed }
      end

      def identity_for(diagnostic)
        KEY_FIELDS.map { |k| diagnostic[k] }
      end

      def write_diff(diff, format, baseline_path:, baseline_count:, current_count:)
        case format
        when "json"
          write_diff_json(diff, baseline_path, baseline_count, current_count)
        else
          write_diff_text(diff, baseline_path, baseline_count, current_count)
        end
      end

      def write_diff_json(diff, baseline_path, baseline_count, current_count)
        @out.puts(JSON.pretty_generate(
                    "baseline" => baseline_path,
                    "baseline_count" => baseline_count,
                    "current_count" => current_count,
                    "new" => diff[:new],
                    "fixed" => diff[:fixed]
                  ))
      end

      def write_diff_text(diff, baseline_path, baseline_count, current_count)
        @out.puts("# diff against #{baseline_path} (#{baseline_count} baseline / #{current_count} current)")
        diff[:new].each { |d| @out.puts("+ NEW   #{render_diagnostic(d)}") }
        diff[:fixed].each { |d| @out.puts("- FIXED #{render_diagnostic(d)}") }
        @out.puts("")
        @out.puts("#{diff[:new].size} new, #{diff[:fixed].size} fixed")
      end

      def render_diagnostic(diagnostic)
        rule = qualified_rule_for(diagnostic)
        position = "#{diagnostic['path']}:#{diagnostic['line']}:#{diagnostic['column']}"
        "#{position} [#{rule}] #{diagnostic['message']}"
      end

      def qualified_rule_for(diagnostic)
        family = diagnostic["source_family"]
        rule = diagnostic["rule"]
        return rule if family.nil? || family == "" || family == "builtin"

        "#{family}.#{rule}"
      end
    end
  end
end
