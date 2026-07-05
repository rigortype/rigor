# frozen_string_literal: true

require_relative "../analysis/runner"

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
      def initialize(configuration:, environment:, project_scan:)
        @configuration = configuration
        @environment = environment
        @project_scan = project_scan
      end

      # The clean per-file baseline: the diagnostic signatures a mutant must add to count as killed. Computed
      # once per file by the caller.
      def baseline(source:, path:)
        analyse(source, path).to_set { |d| sig(d) }
      end

      # Killed iff the mutant introduces a diagnostic not in `baseline`.
      def killed?(mutant_source:, path:, baseline:)
        analyse(mutant_source, path).any? { |d| !baseline.include?(sig(d)) }
      end

      private

      def analyse(source, path)
        Rigor::Analysis::Runner.new(
          configuration: @configuration, environment: @environment, prebuilt: @project_scan,
          cache_store: nil, collect_stats: false
        ).run_source(source: source, path: path).diagnostics
      end

      def sig(diagnostic)
        [diagnostic.rule, diagnostic.path, diagnostic.line, diagnostic.column, diagnostic.message]
      end
    end
  end
end
