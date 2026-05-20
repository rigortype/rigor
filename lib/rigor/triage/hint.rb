# frozen_string_literal: true

module Rigor
  module Triage
    # ADR-23 — one heuristic finding produced by the {Catalogue}.
    #
    # - `id`     — stable kebab-case identifier (`activesupport-core-ext`, …).
    # - `confidence` — `:likely` or `:possible`. Surfaced in the
    #   `[likely …]` / `[possible …]` report framing; a hint is
    #   signal, never a verdict.
    # - `diagnostic_count` — size of the matched cluster.
    # - `summary` — one-line evidence string (what was matched).
    # - `action`  — the suggested next step, phrased imperatively
    #   for a human / agent (ADR-23 WD4: triage never acts itself).
    Hint = Data.define(:id, :confidence, :diagnostic_count, :summary, :action) do
      def to_h
        {
          "id" => id,
          "confidence" => confidence.to_s,
          "diagnostic_count" => diagnostic_count,
          "summary" => summary,
          "action" => action
        }
      end
    end
  end
end
