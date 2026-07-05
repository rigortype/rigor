# frozen_string_literal: true

module Rigor
  module Analysis
    class Runner
      # Mutable per-run holder for the four end-of-pass snapshots that the analysis paths compute as a side
      # effect and the rest of the run reads back: the RBS `class_decl_paths` / `signature_paths` tables
      # (consumed by {RunStats}), the synthesized-namespace name list, and the `conforms-to` scan results
      # (consumed by the diagnostic aggregator).
      #
      # The snapshots are written by whichever analysis path ran ({PoolCoordinator} sequential / fork-pool /
      # fallback) and read by the {Runner} and {DiagnosticAggregator}. A shared mutable holder keeps the
      # write/read timing bit-for-bit with the original inline ivars (the same pattern the reporter
      # accumulators use) while letting the writer and readers live in separate objects without a
      # back-reference cycle.
      class RunSnapshots
        attr_accessor :class_decl_paths, :signature_paths,
                      :synthesized_namespaces, :conformance_results

        # Constructor defaults match the {Runner} constructor: the pre-seed values `build_run_stats` /
        # `pre_file_diagnostics` read before the first analysis path runs are frozen empties.
        def initialize
          @class_decl_paths = {}.freeze
          @signature_paths = [].freeze
          @synthesized_namespaces = [].freeze
          @conformance_results = [].freeze
        end

        # Per-`#run` reset. Mirrors the original `#run` body, which reset these to NON-frozen empties (distinct
        # from the frozen constructor defaults) at the top of each run.
        def reset_for_run
          @class_decl_paths = {}.freeze
          @signature_paths = []
          @synthesized_namespaces = []
          @conformance_results = []
        end
      end
    end
  end
end
