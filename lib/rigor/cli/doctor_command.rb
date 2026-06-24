# frozen_string_literal: true

require "json"
require "optionparser"

require_relative "../configuration"
require_relative "../config_audit"
require_relative "../analysis/baseline"
require_relative "../analysis/result"
require_relative "../plugin"
require_relative "../plugin/loader"
require_relative "../plugin/services"
require_relative "../reflection"
require_relative "../type/combinator"
require_relative "check_runner_factory"
require_relative "command"
require_relative "options"

module Rigor
  class CLI
    # `rigor doctor` — classify existing project findings into setup-problem
    # vs clean-run with a routed next action (ADR-77 WD1).
    #
    # It is a presentation/aggregation layer over data `rigor check` already
    # produces — no new analysis pass and no new diagnostic rule.  The
    # command runs a scoped analysis to gather stats, audits the
    # configuration, validates plugins, and checks baseline drift, then
    # reports a small fixed set of checks with a hint for each failure.
    class DoctorCommand < Command # rubocop:disable Metrics/ClassLength
      USAGE = "Usage: rigor doctor [options]"

      # Check identifiers — the stable JSON contract (`checks[].id`).
      CHECK_CONFIG = "config_audit"
      CHECK_RBS = "rbs_environment"
      CHECK_PLUGINS = "plugins"
      CHECK_BASELINE = "baseline"
      CHECK_RAILS = "rails_plugins"

      RAILS_LOCK_MARKERS = %w[railties actionpack activerecord actioncable].freeze
      RAILS_PLUGIN_MARKERS = %w[
        rigor-activerecord rigor-actionpack rigor-actionmailer rigor-activejob
        rigor-rails-routes rigor-rails-i18n rigor-actioncable rigor-activestorage rigor-rails
      ].freeze

      # @return [Integer] CLI exit status.
      def run
        options = parse_options
        configuration = Configuration.load(options.fetch(:config))
        findings = []

        # 1. Config audit (cheap — no analysis needed).
        findings.concat(audit_config(configuration))

        # 2. Run a scoped analysis to gather stats + diagnostics for the
        #    deeper checks.  Use no-cache so the probe doesn't churn disk.
        runner = CheckRunnerFactory.build(
          configuration: configuration,
          options: { no_cache: true, explain: false, stats: true, workers: 0 },
          buffer: nil,
          cache_root: configuration.cache_path
        )
        result = runner.run(configuration.paths)

        # 3. RBS environment check.
        findings.concat(check_rbs_environment(result))

        # 4. Plugin load check.
        findings.concat(check_plugins(configuration))

        # 5. Baseline drift check.
        findings.concat(check_baseline(configuration, result))

        # 6. Rails locked but no Rails plugins.
        findings.concat(check_rails_plugins(configuration))

        report(findings, options.fetch(:format))
        findings.any? { |f| f[:status] == :fail } ? 1 : 0
      rescue OptionParser::InvalidArgument => e
        @err.puts(e.message)
        CLI::EXIT_USAGE
      end

      private

      def parse_options
        options = { config: nil, format: "text" }
        OptionParser.new do |opts|
          opts.banner = USAGE
          Options.add_config(opts, options)
          opts.on("--format=FORMAT", "Output format: text (default) or json") { |v| options[:format] = v }
        end.parse!(@argv)
        validate!(options)
        options
      end

      def validate!(options)
        return if %w[text json].include?(options.fetch(:format))

        raise OptionParser::InvalidArgument, "unsupported format: #{options.fetch(:format)}"
      end

      # ------------------------------------------------------------------
      # Individual checks — each returns an Array of finding Hashes.
      # A finding has: :check, :status (:pass/:fail/:warn), :message, :hint
      # ------------------------------------------------------------------

      def audit_config(configuration)
        warnings = ConfigAudit.warnings(configuration, project_root: Dir.pwd)
        return [] if warnings.empty?

        messages = warnings.map(&:message)
        [
          {
            check: CHECK_CONFIG,
            status: :fail,
            message: "Configuration warnings: #{messages.size}",
            hint: "Review and fix the flagged entries in your config file."
          }
        ]
      end

      def check_rbs_environment(result)
        stats = result.stats
        return [] unless stats

        if stats.rbs_classes_total.zero?
          [
            {
              check: CHECK_RBS,
              status: :fail,
              message: "RBS environment is empty (#{stats.rbs_classes_total} classes available)",
              hint: "The RBS environment failed to build or loaded no signatures. " \
                    "Check `signature_paths:` for duplicate declarations, or run " \
                    "`rbs collection install` for gem signatures."
            }
          ]
        else
          [
            {
              check: CHECK_RBS,
              status: :pass,
              message: "RBS environment healthy (#{stats.rbs_classes_total} classes available)",
              hint: nil
            }
          ]
        end
      end

      def check_plugins(configuration)
        services = Plugin::Services.new(
          reflection: Reflection,
          type: Type::Combinator,
          configuration: configuration,
          cache_store: nil
        )
        registry = Plugin::Loader.load(configuration: configuration, services: services)
        errors = registry.load_errors
        return [] if errors.empty?

        [
          {
            check: CHECK_PLUGINS,
            status: :fail,
            message: "Plugin load errors: #{errors.size}",
            hint: "Run `rigor plugins --strict` for the full per-plugin report."
          }
        ]
      end

      def check_baseline(configuration, result)
        path = configuration.baseline_path
        return [] if path.nil? || !File.exist?(path)

        baseline = Analysis::Baseline.load(path, project_root: Dir.pwd)
        return [] if baseline.nil? || baseline.empty?

        drifted = baseline.audit(result.diagnostics).reject { |row| row.status == :within }
        return [] if drifted.empty?

        [
          {
            check: CHECK_BASELINE,
            status: :fail,
            message: "Baseline drift detected (#{baseline_drift_summary(drifted)})",
            hint: "Run `rigor baseline regenerate` to refresh the baseline."
          }
        ]
      rescue Analysis::Baseline::LoadError, Psych::SyntaxError => e
        [
          {
            check: CHECK_BASELINE,
            status: :warn,
            message: "Baseline load failed: #{e.message}",
            hint: "Check the baseline file path in your config."
          }
        ]
      end

      def baseline_drift_summary(drifted)
        counts = drifted.group_by(&:status).transform_values(&:size)
        parts = []
        parts << "#{counts.fetch(:over, 0)} over threshold" if counts.key?(:over)
        parts << "#{counts.fetch(:cleared, 0)} cleared" if counts.key?(:cleared)
        parts << "#{counts.fetch(:reducible, 0)} reducible" if counts.key?(:reducible)
        parts.join(", ")
      end

      def check_rails_plugins(configuration)
        return [] unless rails_unconfigured?(configuration)

        [
          {
            check: CHECK_RAILS,
            status: :fail,
            message: "Rails detected but no Rails plugins enabled",
            hint: "Add Rails plugins (e.g. rigor-activerecord, rigor-actionpack) to " \
                  "`.rigor.yml` `plugins:` so framework calls resolve."
          }
        ]
      end

      # True when Rails is in Gemfile.lock but the config enables no
      # Rails plugin — the same probe {ProjectStateProbe} uses.
      def rails_unconfigured?(_configuration)
        config_path = Configuration.discover
        return false if config_path.nil?
        return false unless File.file?(config_path)

        lock = File.join(Dir.pwd, "Gemfile.lock")
        return false unless File.file?(lock) && file_mentions_any?(lock, RAILS_LOCK_MARKERS)

        !file_mentions_any?(config_path, RAILS_PLUGIN_MARKERS)
      end

      def file_mentions_any?(path, markers)
        content = File.read(path)
        markers.any? { |marker| content.include?(marker) }
      rescue StandardError
        false
      end

      # ------------------------------------------------------------------
      # Reporting
      # ------------------------------------------------------------------

      def report(findings, format)
        case format
        when "json" then report_json(findings)
        else report_text(findings)
        end
      end

      def report_json(findings)
        payload = {
          "status" => findings.any? { |f| f[:status] == :fail } ? "issues_found" : "clean",
          "checks" => findings.map do |f|
            {
              "id" => f[:check].to_s,
              "status" => f[:status].to_s,
              "message" => f[:message],
              "hint" => f[:hint]
            }
          end
        }
        @out.puts(JSON.pretty_generate(payload))
      end

      def report_text(findings)
        failures = findings.select { |f| f[:status] == :fail }
        warnings = findings.select { |f| f[:status] == :warn }
        passes = findings.select { |f| f[:status] == :pass }

        if failures.empty? && warnings.empty?
          @out.puts("rigor doctor: all checks passed — no setup problems detected.")
        else
          @out.puts("rigor doctor: #{failures.size} issue(s) found")
          failures.each { |f| print_finding(f) }
          warnings.each { |f| print_finding(f) } unless warnings.empty?
        end

        passes.each { |f| print_finding(f) } unless passes.empty?
      end

      def print_finding(finding)
        label = case finding[:status]
                when :fail then "[FAIL]"
                when :warn then "[WARN]"
                else "[PASS]"
                end
        @out.puts("#{label} #{finding[:check]}: #{finding[:message]}")
        @out.puts("  → #{finding[:hint]}") if finding[:hint]
      end
    end
  end
end
