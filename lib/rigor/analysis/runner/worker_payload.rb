# frozen_string_literal: true

module Rigor
  module Analysis
    class Runner
      # ADR-116 WD3 (#1195) — what one analysing {WorkerSession} hands back to the {PoolCoordinator}: its
      # per-file results and every drain, taken in one place ({.harvest}) and folded in by one
      # ({PoolCoordinator#absorb_worker_payload}). A fork child marshals it to its payload file, the Ractor
      # backend sends it with `:done`, and the fork backend's degrade path harvests the parent session the
      # same way.
      #
      # Every field is Marshal-clean (#805) and, on the Ractor backend, copyable: the drains are frozen
      # `Data` entries and Hashes of Strings. `effects` is nil unless the run collects effects (ADR-103 WD13).
      #
      # The refusals are carried but not absorbed: their merge order is the file order of the whole run, so
      # each backend merges them itself (#1900).
      WorkerPayload = Data.define(:results, :reporters, :dependencies, :analysis_reads, :analysis_disclosures,
                                  :disclosures, :refusals, :effects) do
        # Drains `session` in the order the fork child always has: the reporters (which demand the HKT
        # registry) before the refusal delta, so a refusal that demand makes is reported.
        def self.harvest(session, results: {}, record_effects: false)
          new(
            results: results,
            reporters: session.drain_reporters,
            dependencies: session.drain_dependencies,
            analysis_reads: session.drain_analysis_reads,
            analysis_disclosures: session.drain_analysis_disclosures,
            disclosures: session.drain_run_disclosures,
            refusals: session.drain_trust_refusals,
            effects: record_effects ? session.drain_effects : nil
          )
        end
      end
    end
  end
end
