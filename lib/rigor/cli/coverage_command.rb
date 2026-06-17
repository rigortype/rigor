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
      USAGE = "Usage: rigor coverage [options] PATH..."

      # ADR-70 — the default test runner hook for `--with-tests`. The
      # conventional Ruby test task; override with `--test-command`.
      DEFAULT_TEST_COMMAND = %w[bundle exec rake].freeze

      # @return [Integer] CLI exit status.
      def run
        options = parse_options
        return mutation_misuse_error if options[:mutation] && !options[:protection]
        return with_tests_misuse_error if options[:with_tests] && !options[:mutation]
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
                    with_tests: false, test_command: DEFAULT_TEST_COMMAND }

        OptionParser.new do |opts|
          opts.banner = USAGE
          opts.on("--format=FORMAT", "Output format: text or json") { |v| options[:format] = v }
          Options.add_config(opts, options)
          opts.on(
            "--protection",
            "Report type-protection coverage (ADR-63 Tier 1) instead of type precision"
          ) { options[:protection] = true }
          opts.on(
            "--mutation",
            "With --protection: measure actual mutation effectiveness (ADR-63 Tier 2). " \
            "Scopes to git-changed files when no paths are given; explicit paths override."
          ) { options[:mutation] = true }
          opts.on(
            "--with-tests",
            "With --mutation: also measure dynamic (test-suite) protection (ADR-70). " \
            "Runs --test-command against each type-survivor; reports the fused static∪dynamic map."
          ) { options[:with_tests] = true }
          opts.on(
            "--test-command=CMD", "The test runner hook for --with-tests (default: #{DEFAULT_TEST_COMMAND.join(' ')})"
          ) { |v| options[:test_command] = Shellwords.split(v) }
          opts.on(
            "--threshold=RATIO", Float,
            "Exit 1 when the precision (or, with --protection, protection/effectiveness) ratio is below RATIO (0.0–1.0)"
          ) { |v| options[:threshold] = v }
        end.parse!(@argv)

        options
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

      # ADR-63 Tier 2 — the mutation-effectiveness deep dive. Builds the RBS
      # environment + project pre-pass once (the warm loop), then re-analyses
      # each target file's mutants against its clean baseline. Defaults to the
      # git-changed `.rb` files; explicit paths override (and enable the
      # whole-project opt-in, which is minutes).
      def run_mutation_protection(options)
        explicit = collect_paths(@argv, command_name: "coverage")
        return CLI::EXIT_USAGE if explicit.nil?

        target_files = explicit.empty? ? changed_ruby_files : explicit
        if target_files.empty?
          @out.puts("No changed Ruby files to measure — pass paths to measure explicitly.")
          return 0
        end

        return run_fused_protection(target_files, options) if options[:with_tests]

        report = scan_mutation_protection(target_files, options)
        MutationProtectionRenderer.new(out: @out).render(report, format: options.fetch(:format))
        determine_protection_exit(report, options)
      end

      # ADR-70 — the fused static∪dynamic deep dive. The type pass is the ADR-63
      # Tier 2 warm loop; each type-survivor is then run against the project's
      # test suite (the runner hook). The suite MUST pass on clean code first, or
      # "a mutant survived" is meaningless — abort with a clear message if not.
      def run_fused_protection(paths, options)
        configuration = Configuration.load(options.fetch(:config))
        test_oracle = Protection::TestSuiteOracle.new(command: options.fetch(:test_command))
        return suite_not_green_error(options) unless test_oracle.green?

        context = LanguageServer::ProjectContext.new(configuration: configuration)
        scanner = Protection::MutationScanner.new(
          configuration: configuration, environment: context.environment, project_scan: context.project_scan
        )
        accumulator = FusedProtectionAccumulator.new
        paths.each { |path| scan_fused_one(path, scanner, accumulator, test_oracle, configuration) }
        report = accumulator.to_report
        FusedProtectionRenderer.new(out: @out).render(report, format: options.fetch(:format))
        determine_protection_exit(report, options)
      end

      def scan_fused_one(path, scanner, accumulator, test_oracle, configuration)
        source = File.read(path)
        parse_result = Prism.parse(source, filepath: path, version: configuration.target_ruby)
        if parse_result.errors.any?
          accumulator.record_parse_error(path, parse_result.errors)
          return
        end

        accumulator.absorb(scanner.scan_file_fused(path, source: source, test_oracle: test_oracle))
      end

      def suite_not_green_error(options)
        @err.puts(
          "coverage: the test suite must pass on clean code to measure test protection " \
          "(ran: #{options.fetch(:test_command).join(' ')})"
        )
        @err.puts(
          "  the command must exit 0 on a clean tree. A non-zero exit on otherwise-passing " \
          "tests also trips this — e.g. a SimpleCov coverage floor on a file-scoped run; " \
          "point --test-command at a plain pass/fail runner."
        )
        1
      end

      def scan_mutation_protection(paths, options)
        configuration = Configuration.load(options.fetch(:config))
        context = LanguageServer::ProjectContext.new(configuration: configuration)
        scanner = Protection::MutationScanner.new(
          configuration: configuration, environment: context.environment, project_scan: context.project_scan
        )
        accumulator = MutationProtectionAccumulator.new

        paths.each { |path| scan_mutation_one(path, scanner, accumulator, configuration) }
        accumulator.to_report
      end

      def scan_mutation_one(path, scanner, accumulator, configuration)
        source = File.read(path)
        parse_result = Prism.parse(source, filepath: path, version: configuration.target_ruby)
        if parse_result.errors.any?
          accumulator.record_parse_error(path, parse_result.errors)
          return
        end

        accumulator.absorb(scanner.scan_file(path, source: source))
      end

      # The git-changed (modified / added / untracked) `.rb` files that exist on
      # disk — the default Tier 2 scope. Returns [] outside a git work tree or
      # when git is unavailable; the caller then reports "nothing to measure".
      def changed_ruby_files
        output = git_status_porcelain
        return [] if output.nil?

        output.each_line.filter_map { |line| changed_path(line) }.uniq.select { |p| File.file?(p) }
      end

      # Parse one `git status --porcelain` line (`XY <path>`, or `R  old -> new`)
      # into a candidate `.rb` path, or nil.
      def changed_path(line)
        path = line[3..]&.chomp
        return nil if path.nil? || path.empty?

        path = path.split(" -> ", 2).last if path.include?(" -> ")
        path = path.delete_prefix('"').delete_suffix('"')
        path.end_with?(".rb") ? path : nil
      end

      def git_status_porcelain
        output = IO.popen(%w[git status --porcelain --untracked-files=all], err: File::NULL, &:read)
        $CHILD_STATUS&.success? ? output : nil
      rescue SystemCallError
        nil
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
