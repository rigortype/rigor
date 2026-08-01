# frozen_string_literal: true

require "English"
require "optionparser"
require "prism"
require "shellwords"

require_relative "../configuration"
require_relative "options"
require_relative "../environment"
require_relative "../inference/precision_scanner"
require_relative "../inference/protection_scanner"
require_relative "../inference/parameter_inference_collector"
require_relative "../protection/mutation_scanner"
require_relative "../protection/test_suite_oracle"
require_relative "../language_server/project_context"
require_relative "../runtime/jit"
require_relative "../scope"
require_relative "coverage_report"
require_relative "coverage_renderer"
require_relative "coverage_scan"
require_relative "protection_report"
require_relative "protection_renderer"
require_relative "mutation_protection_report"
require_relative "mutation_protection_renderer"
require_relative "fused_protection_report"
require_relative "fused_protection_renderer"
require_relative "coverage_mutation"
require_relative "protection_fork_scan"
require_relative "mutation_fork_scan"
require_relative "check_runner_factory"
require_relative "command"

module Rigor
  class CLI
    # Executes the `rigor coverage` command.
    #
    # Walks every Prism node in one or more files, infers its type via `Rigor::Scope#type_of`, and classifies the result
    # into precision tiers (constant / nominal / shaped / refined / bot / dynamic_specific /
    # dynamic_top / top).  Reports aggregate and per-file statistics so
    # maintainers can track type-precision trends and SKILL pipelines can measure the impact of adding new constant-fold
    # or shape-dispatch rules.
    #
    # Exit codes:
    #   0  — scan complete, precision ratio ≥ threshold (or no threshold given)
    #   1  — precision ratio < threshold, or parse errors encountered
    #   64 — usage error
    class CoverageCommand < Command
      include CoverageMutation

      USAGE = "Usage: rigor coverage [options] PATH..."

      # ADR-70 — the default test runner hook for `--with-tests`. The conventional Ruby test task; override with
      # `--test-command`.
      DEFAULT_TEST_COMMAND = %w[bundle exec rake].freeze

      # @return [Integer] CLI exit status.
      def run # rubocop:disable Metrics/AbcSize
        # Arm deferred YJIT enablement (Runtime::Jit): a scan long enough to
        # amortize JIT compile cost enables mid-flight; a short one finishes
        # first and never pays it. Same seam as `rigor check`.
        Runtime::Jit.enable_after(Runtime::Jit.deadline_seconds)
        options = parse_options
        return mutation_misuse_error if options[:mutation] && !options[:protection]
        return with_tests_misuse_error if options[:with_tests] && !options[:mutation]
        return include_dynamic_misuse_error if options[:include_dynamic] && !options[:with_tests]
        return run_mutation_protection(options) if options[:mutation]

        configuration = Configuration.load(options.fetch(:config))
        paths = resolve_paths(configuration)
        return CLI::EXIT_USAGE if paths.nil?
        return usage_error if paths.empty?

        return run_protection(paths, options, configuration) if options[:protection]

        report = scan_paths(paths, configuration)
        CoverageRenderer.new(out: @out).render(report, format: options.fetch(:format))
        determine_exit(report, options)
      end

      private

      # Like `rigor check`, fall back to the configured `paths:` when no path is given on the command line
      # (`coverage` previously required an explicit path — operational friction the two commands should not
      # differ on). The mutation mode keeps its own git-changed-files default and returns before this.
      def resolve_paths(configuration)
        args = @argv.empty? ? configuration.paths : @argv
        collect_paths(args, command_name: "coverage")
      end

      def parse_options
        options = { format: "text", threshold: nil, config: nil, protection: false, mutation: false,
                    with_tests: false, test_command: DEFAULT_TEST_COMMAND, include_dynamic: false,
                    limit: nil, seed: 1, workers: nil }
        OptionParser.new { |opts| define_options(opts, options) }.parse!(@argv)
        options
      end

      def define_options(opts, options)
        opts.banner = USAGE
        opts.on("--format=FORMAT", "Output format: text or json") { |v| options[:format] = v }
        Options.add_config(opts, options)
        opts.on("--protection", "Report type-protection coverage (ADR-63 Tier 1) instead of type precision") do
          options[:protection] = true
        end
        define_mutation_options(opts, options)
        opts.on("--workers=N", Integer, "With --protection (with or without --mutation, but not --with-tests, " \
                                        "which must stay sequential): fork N workers over the scanned files " \
                                        "(default: config parallel.workers / RIGOR_RACTOR_WORKERS / 0)") do |v|
          options[:workers] = v
        end
        opts.on("--threshold=RATIO", Float, "Exit 1 when the precision (or, with --protection, " \
                                            "protection/effectiveness) ratio is below RATIO (0.0–1.0)") do |v|
          options[:threshold] = v
        end
      end

      def define_mutation_options(opts, options)
        opts.on("--mutation", "With --protection: measure actual mutation effectiveness (ADR-63 Tier 2). " \
                              "Scopes to git-changed files when no paths are given; explicit paths override.") do
          options[:mutation] = true
        end
        opts.on("--with-tests", "With --mutation: also measure dynamic (test-suite) protection (ADR-70). " \
                                "Runs --test-command against each type-survivor; reports the fused map.") do
          options[:with_tests] = true
        end
        opts.on("--test-command=CMD", "The test runner hook for --with-tests " \
                                      "(default: #{DEFAULT_TEST_COMMAND.join(' ')})") do |v|
          options[:test_command] = Shellwords.split(v)
        end
        opts.on("--include-dynamic", "With --with-tests: also mutate Dynamic-receiver (untyped) sites, where a " \
                                     "test is the only protection (ADR-69 Seam 2). Completes the map, runs more.") do
          options[:include_dynamic] = true
        end
        opts.on("--limit=N", Integer,
                "Sample at most N mutations/file under --mutation (caps cost; ratios become estimates)") do |v|
          options[:limit] = v
        end
        opts.on("--seed=N", Integer, "RNG seed for --limit sampling (default 1)") { |v| options[:seed] = v }
      end

      def mutation_misuse_error
        @err.puts("coverage: --mutation requires --protection")
        @err.puts(USAGE)
        CLI::EXIT_USAGE
      end

      def with_tests_misuse_error
        @err.puts("coverage: --with-tests requires --mutation (and --protection)")
        @err.puts(USAGE)
        CLI::EXIT_USAGE
      end

      def include_dynamic_misuse_error
        @err.puts("coverage: --include-dynamic requires --with-tests (a Dynamic site's only protection is a test)")
        @err.puts(USAGE)
        CLI::EXIT_USAGE
      end

      def run_protection(paths, options, configuration)
        report = scan_protection(paths, options, configuration)
        ProtectionRenderer.new(out: @out).render(report, format: options.fetch(:format))
        determine_protection_exit(report, options)
      end

      # Builds the plugin-aware environment and the seeded scope ONCE on the parent, then fork-pools the
      # per-file scan across the resolved worker count (P3-10). The scan is pure-read and each file is
      # independent, so this is a fork-map + ordered reduce: {ProtectionForkScan} returns `{path => result}`
      # and the parent absorbs in `paths` order so the report is byte-identical to a sequential run.
      def scan_protection(paths, options, configuration)
        environment = plugin_aware_environment(configuration)
        workers = CheckRunnerFactory.resolve_workers(options, configuration)
        scope = scope_with_inferred_params(paths, configuration, environment, workers)
        scanner = Inference::ProtectionScanner.new(scope: scope)
        accumulator = ProtectionAccumulator.new

        results = ProtectionForkScan.run(
          paths: paths, scanner: scanner, environment: environment,
          configuration: configuration, workers: workers
        )
        paths.each { |path| absorb_protection_result(accumulator, path, results.fetch(path)) }
        accumulator.to_report
      end

      def absorb_protection_result(accumulator, path, result)
        if result.is_a?(ProtectionForkScan::ParseError)
          accumulator.record_parse_error_count(path, result.count)
        else
          accumulator.absorb(path, result)
        end
      end

      # Seed the protection scan's scope with the same cross-file facts `rigor check` resolves against, so a receiver
      # reads the type it actually has rather than a stripped-scope `Dynamic`:
      #
      # - `discovered_classes` — a project constant referring to a class
      #   defined in a *sibling* file (`Account`, `User`) types as
      #   `singleton(Account)` instead of `Dynamic`. Without this, a
      #   single-file scan cannot see a class it does not itself declare,
      #   so every cross-file class-constant dispatch was miscounted as
      #   unprotected (the model-constant undercount found 2026-07-04).
      # - `param_inferred_types` (ADR-67 WD3) — an inferred-parameter
      #   receiver (`node.loc` where `node` is a `def compile(node)`
      #   parameter) counts as protected when its call sites resolve to
      #   concrete argument types.
      #
      # Both span the scanned `paths` only (no whole-project pre-pass) — a site that gains neither is classified exactly
      # as before.
      #
      # Tier 2's analogue is {Protection::DiscoverySeed} (#253, #260): the same idea over a *fuller* table set,
      # because Tier 2 must also let its kill oracle resolve the method on the receiver, not merely name its
      # class. Tier 1 seeds unconditionally because it only reclassifies sites it already counted; Tier 2 adds
      # sites to a denominator `--threshold` gates CI on, which is why only the latter is gated on a feature id.
      def scope_with_inferred_params(paths, configuration, environment, workers)
        base = Scope.empty(environment: environment)
        seed = {}

        discovered = Inference::ScopeIndexer.discovered_classes_for_paths(paths)
        seed[:discovered_classes] = discovered unless discovered.empty?

        table = Inference::ParameterInferenceCollector.collect(
          files: paths, environment: environment, target_ruby: configuration.target_ruby, workers: workers
        )
        seed[:param_inferred_types] = table unless table.empty?

        return base if seed.empty?

        base.with_discovery(base.discovery.with(**seed))
      end

      def determine_protection_exit(report, options)
        return 1 unless report.parse_errors.empty?

        threshold = options[:threshold]
        return 0 if threshold.nil?

        report.ratio < threshold ? 1 : 0
      end

      def usage_error
        @err.puts("coverage: at least one path is required")
        @err.puts(USAGE)
        CLI::EXIT_USAGE
      end

      def scan_paths(paths, configuration)
        CoverageScan.precision_report(files: paths, configuration: configuration)
      end

      # The protection scan must see the same receiver types `rigor check` does — including plugin-contributed
      # `dynamic_return` types (a controller's `params` → `ActionController::Parameters`, a `Model.where` →
      # `ActiveRecord::Relation[Model]`). The bare `CoverageScan.project_environment` carries only the RBS environment
      # (no plugin registry), so every plugin-typed receiver reads `Dynamic` and its dispatch site is miscounted as
      # *unprotected* — a systematic undercount of what Rigor actually types on a plugin-using project.
      # `ProjectContext` builds the plugin-aware environment (registry materialised + the per-run prepare pass that
      # primes producers like the controller / model index) exactly as the LSP and the runner do.
      def plugin_aware_environment(configuration)
        LanguageServer::ProjectContext.new(configuration: configuration).environment
      end

      def determine_exit(report, options)
        return 1 unless report.parse_errors.empty?

        threshold = options[:threshold]
        return 0 if threshold.nil?

        report.precision_ratio < threshold ? 1 : 0
      end
    end
  end
end
