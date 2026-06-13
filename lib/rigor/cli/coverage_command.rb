# frozen_string_literal: true

require "optionparser"
require "prism"

require_relative "../configuration"
require_relative "../environment"
require_relative "../inference/precision_scanner"
require_relative "../inference/protection_scanner"
require_relative "../scope"
require_relative "coverage_report"
require_relative "coverage_renderer"
require_relative "protection_report"
require_relative "protection_renderer"
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
        options = { format: "text", threshold: nil, config: nil, protection: false }

        OptionParser.new do |opts|
          opts.banner = USAGE
          opts.on("--format=FORMAT", "Output format: text or json") { |v| options[:format] = v }
          opts.on("--config=PATH", "Path to the Rigor configuration file") { |v| options[:config] = v }
          opts.on(
            "--protection",
            "Report type-protection coverage (ADR-63 Tier 1) instead of type precision"
          ) { options[:protection] = true }
          opts.on(
            "--threshold=RATIO", Float,
            "Exit 1 when the precision (or, with --protection, protection) ratio is below RATIO (0.0–1.0)"
          ) { |v| options[:threshold] = v }
        end.parse!(@argv)

        options
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
