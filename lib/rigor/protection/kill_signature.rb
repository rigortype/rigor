# frozen_string_literal: true

module Rigor
  module Protection
    # ADR-69 Seam 1 — the identity a *kill* is judged by, shared by every diagnostic-based oracle.
    #
    # A mutant is killed when re-analysis produces a diagnostic the clean baseline did not carry, so the
    # comparison needs an identity that is stable across two runs of the same code and distinct for two
    # genuinely different reports. `path` is part of it deliberately: the closure oracle (issue #254) pools
    # the baseline of several files into one set, and the same rule firing at the same line of a *different*
    # file must not be mistaken for the baseline's.
    #
    # Lifted out of {DiagnosticOracle} when {ClosureKillOracle} arrived: two oracles disagreeing about what
    # "the same diagnostic" means would show up only as an unexplained kill-count delta between them.
    module KillSignature
      module_function

      # @param diagnostic [Rigor::Analysis::Diagnostic]
      # @return [Array] the comparison key.
      def of(diagnostic)
        [diagnostic.rule, diagnostic.path, diagnostic.line, diagnostic.column, diagnostic.message]
      end

      # @param diagnostics [Enumerable<Rigor::Analysis::Diagnostic>]
      # @return [Set<Array>] the signature set of `diagnostics`.
      def signatures_of(diagnostics)
        diagnostics.to_set { |diagnostic| of(diagnostic) }
      end
    end
  end
end
