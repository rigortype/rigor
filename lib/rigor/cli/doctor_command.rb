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
    # `rigor doctor` — classify existing project findings into setup-problem vs clean-run with a routed next action
    # (ADR-77 WD1).
    #
    # It is a presentation/aggregation layer over data `rigor check` already
    # produces — no new analysis pass and no new diagnostic rule.  The
    # command runs a scoped analysis to gather stats, audits the configuration, validates plugins, and checks baseline
    # drift, then reports a small fixed set of checks with a hint for each failure.
    class DoctorCommand < Command # rubocop:disable Metrics/ClassLength
      USAGE = "Usage: rigor doctor [options]"

      # Check identifiers — the stable JSON contract (`checks[].id`).
      CHECK_CONFIG = "config_audit"
      CHECK_RBS = "rbs_environment"
      CHECK_PLUGINS = "plugins"
      CHECK_BASELINE = "baseline"
      CHECK_RAILS = "rails_plugins"
      CHECK_GEMFILE = "gemfile_install"
      CHECK_PLUGIN_SKEW = "plugin_skew"

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

        # 4. Plugin load check + 8. installation-skew check share one loaded registry.
        registry = load_plugin_registry(configuration)
        findings.concat(check_plugins(registry))

        # 5. Baseline drift check.
        findings.concat(check_baseline(configuration, result))

        # 6. Rails locked but no Rails plugins.
        findings.concat(check_rails_plugins(configuration))

        # 7. Rigor itself resolved as a project dependency.
        findings.concat(check_gemfile_install)

        # 8. A bundled plugin loaded from a different rigortype installation than the engine (#194 slice 3).
        findings.concat(check_plugin_skew(registry))

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
      # Individual checks — each returns an Array of finding Hashes. A finding has: :check, :status (:pass/:fail/:warn),
      # :message, :hint
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

        quarantined = quarantined_signature_diagnostics(result)
        if stats.rbs_classes_total.zero?
          [empty_rbs_env_finding(stats)]
        elsif quarantined.any?
          [degraded_rbs_env_finding(stats, quarantined)]
        else
          [healthy_rbs_env_finding(stats)]
        end
      end

      def empty_rbs_env_finding(stats)
        {
          check: CHECK_RBS,
          status: :fail,
          message: "RBS environment is empty (#{stats.rbs_classes_total} classes available)",
          hint: "The RBS environment failed to build or loaded no signatures. " \
                "Check `signature_paths:` for duplicate declarations, or run " \
                "`rbs collection install` for gem signatures."
        }
      end

      # The env is non-empty precisely BECAUSE the broken file was quarantined, so the class count alone reads
      # as healthy — this is the case doctor used to pass. Classify the diagnostic the run already produced
      # (ADR-77: route existing evidence) rather than re-probing the sig tree.
      def degraded_rbs_env_finding(stats, quarantined)
        {
          check: CHECK_RBS,
          status: :warn,
          message: "RBS environment degraded — #{quarantined.size} `signature_paths:` file(s) " \
                   "skipped, #{stats.rbs_classes_total} classes available",
          hint: "An unparseable `.rbs` is skipped so the rest of the env survives, which makes the " \
                "run quieter, not cleaner: the types it declares are gone. Run `rbs validate` on your " \
                "`sig/` set and fix the parse error. To make this fail the build, opt into the " \
                "`reject-unparseable-signatures` bleeding-edge feature."
        }
      end

      def healthy_rbs_env_finding(stats)
        {
          check: CHECK_RBS,
          status: :pass,
          message: "RBS environment healthy (#{stats.rbs_classes_total} classes available)",
          hint: nil
        }
      end

      def quarantined_signature_diagnostics(result)
        result.diagnostics.select { |diagnostic| diagnostic.rule == "rbs.coverage.quarantined-signature" }
      end

      def load_plugin_registry(configuration)
        services = Plugin::Services.new(
          reflection: Reflection,
          type: Type::Combinator,
          configuration: configuration,
          cache_store: nil
        )
        Plugin::Loader.load(configuration: configuration, services: services)
      end

      def check_plugins(registry)
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

      # WD5 (#194 slice 3) — a bundled plugin should load from the engine's own `plugins/` tree; slice 2
      # anchors it there. This guards the residual anchoring cannot see: a bundled plugin whose resolved file
      # sits OUTSIDE the engine tree — the fallback-require path, or a genuinely mixed installation where a
      # foreign copy was already loaded. That is the #194 skew, which ran the engine with a load-bearing
      # false-positive gate silently missing. Only plugins the engine bundles are checked; a third-party /
      # project-bundle plugin is not the engine's to vouch for and is never flagged, and a nil resolved path
      # (an injected requirer, an in-process no-op load) carries no provenance and is skipped.
      def check_plugin_skew(registry)
        registry.resolved_gem_paths.filter_map do |gem_name, resolved_path|
          next if resolved_path.nil?
          next unless Plugin::Loader.bundled_plugin_path(gem_name)
          next if inside_engine_tree?(resolved_path)

          plugin_skew_finding(gem_name, resolved_path)
        end
      end

      def plugin_skew_finding(gem_name, resolved_path)
        {
          check: CHECK_PLUGIN_SKEW,
          status: :warn,
          message: "Plugin #{gem_name} loaded from a different rigortype installation than the engine " \
                   "(loaded from #{resolved_path}; engine at #{Plugin::Loader::ENGINE_ROOT})",
          hint: "The engine and its bundled plugins are versioned together, so a copy resolved from another " \
                "installation can run the engine with a mismatched plugin (the cause of wrong diagnostics in " \
                "#194). Ensure a single `rigortype` is on the load path — remove any separately-installed " \
                "`rigortype` gem that shadows this checkout, or reinstall so the engine and its `plugins/` " \
                "tree come from one place."
        }
      end

      # True when `resolved_path` lives inside the engine's own tree. Both sides are resolved through
      # `File.realpath` first so a symlinked gem home / checkout (e.g. macOS `/var` → `/private/var`) does not
      # read as foreign; a vanished file degrades to `File.expand_path` rather than raising.
      def inside_engine_tree?(resolved_path)
        engine = real_or_expanded(Plugin::Loader::ENGINE_ROOT)
        target = real_or_expanded(resolved_path)
        target == engine || target.start_with?("#{engine}#{File::SEPARATOR}")
      end

      def real_or_expanded(path)
        File.realpath(path)
      rescue StandardError
        File.expand_path(path)
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

      # True when Rails is in Gemfile.lock but the config enables no Rails plugin — the same probe {ProjectStateProbe}
      # uses.
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

      # Rigor is a tool, not a library (ADR-27): resolving it as one of the project's own dependencies pins the
      # application to Rigor's Ruby and drags Rigor's dependency graph into the app's resolution. The gem carries
      # guardrails against arriving here, but they only fire during install and at boot — a project that already
      # made the mistake never sees them again, so doctor names the state.
      def check_gemfile_install
        lock = File.join(Dir.pwd, "Gemfile.lock")
        return [] unless File.file?(lock)
        return [] unless rubygems_sourced_rigortype?(lock)

        [
          {
            check: CHECK_GEMFILE,
            status: :fail,
            message: "Rigor is resolved as a dependency of this project (`rigortype` under GEM in Gemfile.lock)",
            hint: "Remove `rigortype` from the Gemfile and install Rigor on its own — see " \
                  "https://github.com/rigortype/rigor/blob/master/docs/install.md. To keep the version " \
                  "pinned, use `mise use --pin gem:rigortype`, or an isolated `BUNDLE_GEMFILE` holding only " \
                  "Rigor (the CI chapter's pattern), which leaves your application's resolution untouched."
          }
        ]
      end

      # True only when `rigortype` resolves from a GEM remote — i.e. an ordinary `gem "rigortype"` in the app's
      # Gemfile, the case worth reporting.
      #
      # The source is load-bearing, not decoration: Rigor's own repo, every fork of it, and any project vendoring
      # Rigor for development all carry `rigortype` in Gemfile.lock too — under PATH (`remote: .`, from the
      # `gemspec` directive) or GIT. Matching the name alone would fail this check on Rigor itself. Reading the
      # lock by section also keeps a CHECKSUMS entry and a *dependency* line nested under another gem (six-space
      # indent) from counting as a resolution.
      def rubygems_sourced_rigortype?(path)
        section = nil
        in_specs = false

        File.foreach(path) do |line|
          case line
          when /\A(\S.*?)\s*\z/ then (section = Regexp.last_match(1)) && (in_specs = false)
          when /\A  specs:\s*\z/ then in_specs = true
          when /\A    rigortype \(/ then return true if section == "GEM" && in_specs
          end
        end
        false
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
          # Count warnings too: a warn-only run (a degraded RBS env, a malformed baseline) used to headline
          # "0 issue(s) found" above the very finding it was reporting.
          @out.puts("rigor doctor: #{summary_counts(failures, warnings)}")
          failures.each { |f| print_finding(f) }
          warnings.each { |f| print_finding(f) } unless warnings.empty?
        end

        passes.each { |f| print_finding(f) } unless passes.empty?
      end

      def summary_counts(failures, warnings)
        parts = []
        parts << "#{failures.size} issue(s)" unless failures.empty?
        parts << "#{warnings.size} warning(s)" unless warnings.empty?
        "#{parts.join(', ')} found"
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
