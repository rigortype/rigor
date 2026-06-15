# frozen_string_literal: true

require "prism"

require_relative "../configuration"
require_relative "../environment"
require_relative "../inference/precision_scanner"
require_relative "../scope"
require_relative "coverage_report"

module Rigor
  class CLI
    # Shared type-precision scan behind both `rigor coverage` (the
    # dedicated command) and `rigor check --coverage` (the in-run
    # coverage block). Walks each file's AST, types every expression via
    # `Scope#type_of`, and accumulates the precision-tier breakdown into a
    # `CoverageReport`. Extracted so the two surfaces stay byte-identical
    # on the same file set.
    module CoverageScan
      module_function

      # @param files [Array<String>] explicit `.rb` file paths to scan.
      # @param configuration [Rigor::Configuration]
      # @return [Rigor::CLI::CoverageReport]
      def precision_report(files:, configuration:)
        scope = Scope.empty(environment: project_environment(configuration))
        scanner = Inference::PrecisionScanner.new(scope: scope)
        accumulator = CoverageAccumulator.new
        files.each { |path| scan_into(path, scanner, accumulator, configuration) }
        accumulator.to_report(files, {})
      end

      def project_environment(configuration)
        Environment.for_project(
          libraries: configuration.libraries,
          signature_paths: configuration.signature_paths
        )
      end

      # Parses one file and feeds the scan result (or a parse-error
      # record) into `accumulator`. `scanner` / `accumulator` are a
      # matched pair — a `PrecisionScanner` + `CoverageAccumulator`, or a
      # `ProtectionScanner` + `ProtectionAccumulator` — both of which
      # respond to `scan(node)` and `absorb(path, result)`.
      def scan_into(path, scanner, accumulator, configuration)
        source = File.read(path)
        parse_result = Prism.parse(source, filepath: path, version: configuration.target_ruby)
        if parse_result.errors.any?
          accumulator.record_parse_error(path, parse_result.errors)
          return
        end

        accumulator.absorb(path, scanner.scan(parse_result.value))
      end
    end
  end
end
