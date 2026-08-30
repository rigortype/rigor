# frozen_string_literal: true

require "prism"

require_relative "../configuration"
require_relative "../environment"
require_relative "../inference/parameter_inference_collector"
require_relative "../inference/precision_scanner"
require_relative "../inference/scope_indexer"
require_relative "../scope"
require_relative "coverage_report"

module Rigor
  class CLI
    # Shared type-precision scan behind both `rigor coverage` (the dedicated command) and `rigor check --coverage` (the
    # in-run coverage block). Walks each file's AST, types every expression via `Scope#type_of`, and accumulates the
    # precision-tier breakdown into a `CoverageReport`. Extracted so the two surfaces stay byte-identical on the same
    # file set.
    module CoverageScan
      module_function

      # @param files [Array<String>] explicit `.rb` file paths to scan.
      # @param configuration [Rigor::Configuration]
      # @return [Rigor::CLI::CoverageReport]
      def precision_report(files:, configuration:)
        scope = discovery_seeded_scope(
          files: files,
          configuration: configuration,
          environment: project_environment(configuration),
          parameter_inference: configuration.parameter_inference
        )
        scanner = Inference::PrecisionScanner.new(scope: scope)
        accumulator = CoverageAccumulator.new
        files.each { |path| scan_into(path, scanner, accumulator, configuration) }
        accumulator.to_report(files, {})
      end

      # The cross-file facts a scan must see to report the types the engine actually infers, rather than the types a
      # file-at-a-time walk can reach on its own:
      #
      # - `discovered_classes` — a project constant naming a class defined in a SIBLING file (`Account`, `User`) types
      #   as `singleton(Account)` instead of `Dynamic`. Without it a single-file scan cannot see a class it does not
      #   itself declare (the model-constant undercount found 2026-07-04).
      # - `param_inferred_types` (ADR-67 WD3) — an undeclared parameter seeded with the union of its call sites'
      #   argument types.
      #
      # Both spanned the `--protection` scan only until 2026-08-31, so the PRECISION ratio — the number `rigor
      # coverage`, `rigor check --coverage` and the `check-coverage` threshold gate all report — was measured on a
      # stripped scope and understated the engine by 4.87 points on this repository's own `lib`. The two surfaces now
      # build the same seed set, so their ratios describe the same engine.
      #
      # `parameter_inference` is a parameter rather than a config read because the two callers want different answers:
      # the precision lens must mirror the walk it describes (`check` leaves the table empty unless
      # `parameter_inference:` is on, ADR-67 WD6a), while `--protection` seeds it unconditionally by ADR-67's own
      # wiring — it only ever reclassifies sites it already counted.
      #
      # @return [Rigor::Scope]
      def discovery_seeded_scope(files:, configuration:, environment:, parameter_inference:, workers: nil)
        base = Scope.empty(environment: environment)
        seed = {}

        discovered = Inference::ScopeIndexer.discovered_classes_for_paths(files)
        seed[:discovered_classes] = discovered unless discovered.empty?

        if parameter_inference
          table = Inference::ParameterInferenceCollector.collect(
            files: files, environment: environment, target_ruby: configuration.target_ruby,
            workers: workers || configuration.parallel_workers
          )
          seed[:param_inferred_types] = table unless table.empty?
        end

        return base if seed.empty?

        base.with_discovery(base.discovery.with(**seed))
      end

      def project_environment(configuration)
        Environment.for_project(
          libraries: configuration.libraries,
          signature_paths: configuration.signature_paths
        )
      end

      # Parses one file and feeds the scan result (or a parse-error record) into `accumulator`. `scanner` /
      # `accumulator` are a matched pair — a `PrecisionScanner` + `CoverageAccumulator`, or a `ProtectionScanner` +
      # `ProtectionAccumulator` — both of which respond to `scan(node)` and `absorb(path, result)`.
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
