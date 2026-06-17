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
    # Walks every Prism node in one or more files, infers its type via
    # `Rigor::Scope#type_of`, and classifies the result into precision tiers
    # (constant / nominal / shaped / refined / bot / dynamic_specific /
    # dynamic_top / top).  Reports aggregate and per-file statistics so
    # maintainers can track type-precision trends and SKILL pipelines can
    # measure the impact of adding new constant-fold or shape-dispatch rules.
    #
    # Exit codes:
    #   0  — scan complete, precision ratio ≥ threshold (or no threshold given)
    #   1  — precision ratio < threshold, or parse errors encountered
    #   64 — usage error
    class CoverageCommand < Command
      include CoverageMutation

      USAGE = "Usage: rigor coverage [options] PATH..."

      # ADR-70 — the default test runner hook for `--with-tests`. The
      # conventional Ruby test task; override with `--test-command`.
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
                    with_tests: false, test_command: DEFAULT_TEST_COMMAND, include_dynamic: false }
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
        opts.on("--threshold=RATIO", Float, "Exit 1 when the precision (or, with --protection, " \
                                            "protection/effectiveness) ratio is below RATIO (0.0–1.0)") do |v|
          options[:threshold] = v
        end
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
        environment = project_environment(configuration)
        scope = scope_with_inferred_params(paths, configuration, environment)
        scanner = Inference::ProtectionScanner.new(scope: scope)
        accumulator = ProtectionAccumulator.new

        paths.each { |path| scan_one(path, scanner, accumulator, configuration) }
        accumulator.to_report
      end

      # ADR-67 WD3 — seed the call-site parameter-inference table so the
      # protection scan counts an inferred-parameter receiver (e.g. `node.loc`
      # where `node` is a `def compile(node)` parameter) as protected when its
      # call sites resolve to concrete argument types. ONLY the parameter table
      # is seeded — no cross-file discovery — so every site that does not gain
      # an inferred parameter type is classified byte-identically to the
      # un-inferred baseline. Collection spans the scanned `paths`.
      def scope_with_inferred_params(paths, configuration, environment)
        base = Scope.empty(environment: environment)
        table = Inference::ParameterInferenceCollector.collect(
          files: paths, environment: environment, target_ruby: configuration.target_ruby
        )
        return base if table.empty?

        base.with_discovery(base.discovery.with(param_inferred_types: table))
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

      # Delegated to the shared scan module (see {CoverageScan}); the
      # protection path below reuses both, and `rigor check --coverage`
      # reuses `precision_report` over the same machinery.
      def project_environment(configuration)
        CoverageScan.project_environment(configuration)
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
