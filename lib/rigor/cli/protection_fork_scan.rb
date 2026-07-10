# frozen_string_literal: true

require "prism"

require_relative "../inference/fork_map"

module Rigor
  class CLI
    # Fork-pool for the `rigor coverage --protection` scan (P3-10). The plugin-aware environment and the
    # seeded scope are built ONCE on the parent — the expensive part: RBS env, plugin registry, and the
    # cross-file discovery + parameter-inference seed — and children copy-on-write inherit them (via
    # {Inference::ForkMap}), each analysing a contiguous slice of paths and returning per-path results the
    # parent merges in original path order.
    #
    # The scan is pure-read (no reporter drains, no plugin-emission merge, no prepare diagnostics), so a
    # slice payload is just `{path => result}`. Determinism: the parent merges slice payloads in slice order
    # and the accumulator absorbs in `paths` order, so the fused report is byte-identical to a sequential run
    # regardless of which worker produced which file.
    module ProtectionForkScan
      module_function

      # A parse failure for one file, carrying only the marshalable error count (Prism error objects are not
      # reliably marshalable, and the accumulator only needs the count).
      ParseError = Data.define(:count)

      # @param paths [Array<String>] the files to scan, in caller order.
      # @param scanner [Inference::ProtectionScanner] built on the parent; COW-inherited by workers.
      # @param environment [Rigor::Environment] the scanner's environment, prewarmed here before forking.
      # @param configuration [Rigor::Configuration] for the Prism `target_ruby` version.
      # @param workers [Integer] resolved worker count (≤1 → sequential).
      # @return [Hash{String => Inference::ProtectionScanner::FileResult, ParseError}] one entry per path.
      def run(paths:, scanner:, environment:, configuration:, workers:)
        # Force the full RBS load on the parent so children copy-on-write inherit a warm environment rather
        # than each rebuilding it after the fork (mirrors the check fork pool's parent-side prewarm). A
        # no-op on the sequential path but cheap.
        environment.rbs_loader&.prewarm if Inference::ForkMap.parallel?([workers, paths.size].min)

        payloads = Inference::ForkMap.call(items: paths, workers: workers) do |slice|
          slice.to_h { |path| [path, scan_path(path, scanner, configuration)] }
        end
        payloads.each_with_object({}) { |slice_results, merged| merged.merge!(slice_results) }
      end

      # Parses one file and returns the scanner's {Inference::ProtectionScanner::FileResult}, or a
      # {ParseError} when the source does not parse.
      def scan_path(path, scanner, configuration)
        source = File.read(path)
        parse_result = Prism.parse(source, filepath: path, version: configuration.target_ruby)
        return ParseError.new(count: parse_result.errors.size) if parse_result.errors.any?

        scanner.scan(parse_result.value)
      end
    end
  end
end
