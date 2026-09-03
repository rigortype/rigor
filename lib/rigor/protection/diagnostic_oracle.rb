# frozen_string_literal: true

require_relative "../analysis/runner"
require_relative "analysis_guard"
require_relative "kill_signature"

module Rigor
  module Protection
    # ADR-69 Seam 1 — the **kill oracle** Rigor's analyzer-teeth measurement uses: a mutant is killed iff
    # re-analysing it introduces a diagnostic absent from the clean baseline. This is exactly the behaviour
    # ADR-62/63 shipped, lifted out of {MutationScanner} so a {TestSuiteOracle} (ADR-70) — which kills by
    # *running tests* rather than by re-analysis — can sit beside it without the scanner baking in either
    # assumption.
    #
    # The expensive builds (RBS environment + the whole-project pre-pass scan) are paid once by the caller and
    # threaded in; each mutant reuses them through `Runner.new(prebuilt:)#run_source` (in-memory overlay, no
    # disk write). Passing `prebuilt:` disables the run-result cache (whose key digests the *disk* file), so a
    # mutant is never served a stale clean hit.
    class DiagnosticOracle
      # @param discovery_seed [Hash, nil] issue #260 — the cross-file discovery tables (see {DiscoverySeed})
      #   the per-mutant analysis is seeded with, threaded through to `Runner.new(discovery_seed:)`. Without
      #   it the runner's `prebuilt:` path carries frozen-empty discovery tables, so a receiver whose class is
      #   declared in a *sibling* file reads `Dynamic` and NO mutation at that site can produce a diagnostic —
      #   a site the caller's site filter may nonetheless have admitted, and then measured as an unkillable
      #   survivor. nil (the default) keeps the shipped single-file oracle.
      def initialize(configuration:, environment:, project_scan:, discovery_seed: nil)
        @configuration = configuration
        @environment = environment
        @project_scan = project_scan
        @discovery_seed = discovery_seed
      end

      # The clean per-file baseline: the diagnostic signatures a mutant must add to count as killed. Computed
      # once per file by the caller.
      def baseline(source:, path:)
        KillSignature.signatures_of(analyse(source, path))
      end

      # Killed iff the mutant introduces a diagnostic not in `baseline`.
      def killed?(mutant_source:, path:, baseline:)
        analyse(mutant_source, path).any? { |d| !baseline.include?(KillSignature.of(d)) }
      end

      private

      # Issue #686 — the diagnostics of a CRASHED run are not an answer, and this oracle's whole job is to
      # compare two runs' diagnostics. Both sides of that comparison come through here, so refusing once
      # here covers `#baseline` and `#killed?` alike; {MutationScanner} turns the raise into a
      # `harness_errors` count rather than a kill or a survivor.
      def analyse(source, path)
        AnalysisGuard.checked(
          Rigor::Analysis::Runner.new(
            configuration: @configuration, environment: @environment, prebuilt: @project_scan,
            cache_store: nil, collect_stats: false, discovery_seed: @discovery_seed
          ).run_source(source: source, path: path).diagnostics,
          context: "DiagnosticOracle re-analysis of #{path}"
        )
      end
    end
  end
end
