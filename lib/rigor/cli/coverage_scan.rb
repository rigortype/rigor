# frozen_string_literal: true

require "prism"

require_relative "../configuration"
require_relative "../environment"
require_relative "../inference/parameter_inference_collector"
require_relative "../inference/precision_scanner"
require_relative "../inference/scope_indexer"
require_relative "../language_server/project_context"
require_relative "../protection/discovery_seed"
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

      # @rbs files: Array[String] -- Explicit `.rb` file paths to scan.
      #
      # Issue #513 — the environment is PLUGIN-AWARE (`LanguageServer::ProjectContext`, the same builder
      # `--protection` uses), not the bare RBS environment this path carried until 2026-09-01. Without the
      # plugin registry every plugin-typed receiver read `Dynamic` and the precision ratio understated the
      # engine by ~1.2 points on a Rails target — the defect the protection path documented and fixed for
      # itself on 2026-07-04, never applied here.
      def precision_report(files:, configuration:)
        scope = discovery_seeded_scope(
          files: files,
          configuration: configuration,
          environment: LanguageServer::ProjectContext.new(configuration: configuration).environment,
          parameter_inference: configuration.parameter_inference
        )
        scanner = Inference::PrecisionScanner.new(scope: scope)
        accumulator = CoverageAccumulator.new
        files.each { |path| scan_into(path, scanner, accumulator, configuration) }
        accumulator.to_report(files, {})
      end

      # The cross-file facts a scan must see to report the types the engine actually infers, rather than the types a
      # file-at-a-time walk can reach on its own.
      #
      # Issue #513 — the seed is the FULL check-walk bundle (`Protection::DiscoverySeed.discovery_tables`: classes,
      # def nodes and sources for both kinds, superclasses, includes, visibilities, methods, and the Data / Struct
      # member layouts), not just `discovered_classes`. The two-table seed #505 introduced closed the biggest part of
      # the gap and left the rest: without the def-node / ancestry tables every cross-file call to a source-inferred
      # project method measured as unresolved while `rigor check` resolves it — +0.27pp on redmine, +0.77pp on
      # mastodon from the tables alone.
      #
      # `parameter_inference` is a parameter rather than a config read because the two callers want different answers:
      # the precision lens must mirror the walk it describes (`check` leaves the table empty unless
      # `parameter_inference:` is on, ADR-67 WD6a), while `--protection` seeds it unconditionally by ADR-67's own
      # wiring — it only ever reclassifies sites it already counted.
      def discovery_seeded_scope(files:, configuration:, environment:, parameter_inference:, workers: nil)
        base = Scope.empty(environment: environment)
        seed = Protection::DiscoverySeed.discovery_tables(files).dup

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
