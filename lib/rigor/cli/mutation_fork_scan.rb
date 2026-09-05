# frozen_string_literal: true

require "prism"

require_relative "../inference/fork_map"

module Rigor
  class CLI
    # Fork-pool for the `rigor coverage --protection --mutation` scan (#134 slice 1) — the Tier-2 analogue of
    # {ProtectionForkScan}. The expensive shared state is built ONCE on the parent (the RBS environment, the
    # plugin registry, and the whole-project pre-pass {Analysis::ProjectScan}, all held by the
    # {Protection::MutationScanner}'s oracle) and children copy-on-write inherit it via {Inference::ForkMap},
    # each measuring a contiguous slice of paths.
    #
    # Why this is safe to parallelise where Tier 1 already is: a Tier-2 per-file measurement is pure-read
    # against that shared state — every mutant is analysed through `Runner.new(prebuilt:)#run_source`, an
    # in-memory overlay that writes nothing to disk and, because `prebuilt:` disables the run-result cache, has
    # no cache store to race on. The returned {Protection::MutationScanner::FileResult} is a Data of primitives
    # (and `SurvivingSite` likewise), so it marshals back verbatim.
    #
    # Determinism: {MutationProtectionAccumulator#absorb} is order-dependent (the per-file list and the
    # "add a type here" example paths follow absorption order), so the parent MUST iterate the original `paths`
    # and `fetch` each result rather than consume completion order. A missing key then raises instead of
    # silently under-reporting an effectiveness ratio a `--threshold` gate reads.
    #
    # NOT used by the fused `--with-tests` path: {Protection::TestSuiteOracle} shells out to the project's test
    # runner, and concurrent suite invocations would race over the same working tree.
    module MutationForkScan
      module_function

      # A parse failure for one file, carrying only the marshalable error count (Prism error objects are not
      # reliably marshalable, and the accumulator only needs the count).
      ParseError = Data.define(:count)

      # @rbs paths: Array[String] -- The files to measure, in caller order.
      # @rbs scanner: Protection::MutationScanner -- Built on the parent; COW-inherited by workers.
      # @rbs environment: Rigor::Environment -- The scanner's environment, prewarmed here before forking.
      # @rbs configuration: Rigor::Configuration -- For the Prism `target_ruby` version.
      # @rbs workers: Integer -- Resolved worker count (≤1 → sequential).
      # @rbs return: Hash[String, Protection::MutationScanner::FileResult | ParseError] -- One entry per path.
      def run(paths:, scanner:, environment:, configuration:, workers:)
        # Force the full RBS load on the parent so children copy-on-write inherit a warm environment rather
        # than each rebuilding it after the fork. A no-op on the sequential path but cheap.
        environment.rbs_loader&.prewarm if Inference::ForkMap.parallel?([workers, paths.size].min)

        payloads = Inference::ForkMap.call(items: paths, workers: workers) do |slice|
          slice.to_h { |path| [path, scan_path(path, scanner, configuration)] }
        end
        payloads.each_with_object({}) { |slice_results, merged| merged.merge!(slice_results) }
      end

      # Measures one file and returns the scanner's {Protection::MutationScanner::FileResult}, or a
      # {ParseError} when the source does not parse — the same read → parse → guard → scan order the sequential
      # loop used, so a broken file is reported identically either side of the fork.
      def scan_path(path, scanner, configuration)
        source = File.read(path)
        parse_result = Prism.parse(source, filepath: path, version: configuration.target_ruby)
        return ParseError.new(count: parse_result.errors.size) if parse_result.errors.any?

        scanner.scan_file(path, source: source)
      end
    end
  end
end
