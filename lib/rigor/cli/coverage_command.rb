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
      def run
        options = parse_options
        return mutation_misuse_error if options[:mutation] && !options[:protection]
        return with_tests_misuse_error if options[:with_tests] && !options[:mutation]
        return include_dynamic_misuse_error if options[:include_dynamic] && !options[:with_tests]
        return run_mutation_protection(options) if options[:mutation]

        paths = collect_paths(@argv, command_name: "coverage")
        return CLI::EXIT_USAGE if paths.nil?
        return usage_error if paths.empty?

        return run_protection(paths, options) if options[:protection]

        report = scan_paths(paths, options)
        CoverageRenderer.new(out: @out).render(report, format: options.fetch(:format))
        determine_exit(report, options)
      end

      private

      def parse_options
        options = { format: "text", threshold: nil, config: nil, protection: false, mutation: false,
                    with_tests: false, test_command: DEFAULT_TEST_COMMAND, include_dynamic: false,
                    limit: nil, seed: 1 }
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

      def run_protection(paths, options)
        report = scan_protection(paths, options)
        ProtectionRenderer.new(out: @out).render(report, format: options.fetch(:format))
        determine_protection_exit(report, options)
      end

      def scan_protection(paths, options)
        configuration = Configuration.load(options.fetch(:config))
        environment = plugin_aware_environment(configuration)
        scope = scope_with_inferred_params(paths, configuration, environment)
        scanner = Inference::ProtectionScanner.new(scope: scope)
        accumulator = ProtectionAccumulator.new

        paths.each { |path| scan_one(path, scanner, accumulator, configuration) }
        accumulator.to_report
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
      def scope_with_inferred_params(paths, configuration, environment)
        base = Scope.empty(environment: environment)
        seed = {}

        discovered = Inference::ScopeIndexer.discovered_classes_for_paths(paths)
        seed[:discovered_classes] = discovered unless discovered.empty?

        table = Inference::ParameterInferenceCollector.collect(
          files: paths, environment: environment, target_ruby: configuration.target_ruby
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

      def scan_paths(paths, options)
        CoverageScan.precision_report(files: paths, configuration: Configuration.load(options.fetch(:config)))
      end

      # Delegated to the shared scan module (see {CoverageScan}); the protection path below reuses both, and `rigor
      # check --coverage` reuses `precision_report` over the same machinery.
      def project_environment(configuration)
        CoverageScan.project_environment(configuration)
      end

      # The protection scan must see the same receiver types `rigor check` does — including plugin-contributed
      # `dynamic_return` types (a controller's `params` → `ActionController::Parameters`, a `Model.where` →
      # `ActiveRecord::Relation[Model]`). The bare `project_environment` carries only the RBS environment (no plugin
      # registry), so every plugin-typed receiver reads `Dynamic` and its dispatch site is miscounted as *unprotected* —
      # a systematic undercount of what Rigor actually types on a plugin-using project. `ProjectContext` builds the
      # plugin-aware environment (registry materialised + the per-run prepare pass that primes producers like the
      # controller / model index) exactly as the LSP and the runner do.
      def plugin_aware_environment(configuration)
        LanguageServer::ProjectContext.new(configuration: configuration).environment
      end

      def scan_one(path, scanner, accumulator, configuration)
        CoverageScan.scan_into(path, scanner, accumulator, configuration)
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
