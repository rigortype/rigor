# frozen_string_literal: true

require "English"
require "optionparser"
require "prism"

require_relative "../configuration"
require_relative "../environment"
require_relative "../inference/precision_scanner"
require_relative "../inference/protection_scanner"
require_relative "../protection/mutation_scanner"
require_relative "../language_server/project_context"
require_relative "../scope"
require_relative "coverage_report"
require_relative "coverage_renderer"
require_relative "protection_report"
require_relative "protection_renderer"
require_relative "mutation_protection_report"
require_relative "mutation_protection_renderer"
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

      # @return [Integer] CLI exit status.
      def run
        options = parse_options
        return mutation_misuse_error if options[:mutation] && !options[:protection]
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
        options = { format: "text", threshold: nil, config: nil, protection: false, mutation: false }

        OptionParser.new do |opts|
          opts.banner = USAGE
          opts.on("--format=FORMAT", "Output format: text or json") { |v| options[:format] = v }
          opts.on("--config=PATH", "Path to the Rigor configuration file") { |v| options[:config] = v }
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

      def run_protection(paths, options)
        report = scan_protection(paths, options)
        ProtectionRenderer.new(out: @out).render(report, format: options.fetch(:format))
        determine_protection_exit(report, options)
      end

      def scan_protection(paths, options)
        configuration = Configuration.load(options.fetch(:config))
        scope = Scope.empty(environment: project_environment(configuration))
        scanner = Inference::ProtectionScanner.new(scope: scope)
        accumulator = ProtectionAccumulator.new

        paths.each { |path| scan_one(path, scanner, accumulator, configuration) }
        accumulator.to_report
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

        report = scan_mutation_protection(target_files, options)
        MutationProtectionRenderer.new(out: @out).render(report, format: options.fetch(:format))
        determine_protection_exit(report, options)
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
        configuration = Configuration.load(options.fetch(:config))
        scope = Scope.empty(environment: project_environment(configuration))
        scanner = Inference::PrecisionScanner.new(scope: scope)
        accumulator = CoverageAccumulator.new

        paths.each { |path| scan_one(path, scanner, accumulator, configuration) }
        accumulator.to_report(paths, options)
      end

      def project_environment(configuration)
        Environment.for_project(
          libraries: configuration.libraries,
          signature_paths: configuration.signature_paths
        )
      end

      def scan_one(path, scanner, accumulator, configuration)
        source = File.read(path)
        parse_result = Prism.parse(source, filepath: path, version: configuration.target_ruby)
        if parse_result.errors.any?
          accumulator.record_parse_error(path, parse_result.errors)
          return
        end

        accumulator.absorb(path, scanner.scan(parse_result.value))
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
