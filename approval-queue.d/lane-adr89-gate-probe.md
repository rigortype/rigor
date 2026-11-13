# The ADR-89 gate declines every pair whose readers hold a run-scoped plugin row

- **PR:** [#3196](https://github.com/rigortype/rigor/pull/3196)
- **Issue:** [#3187](https://github.com/rigortype/rigor/issues/3187)
- **Class:** open-choice
- **Precedent:** [#3182](https://github.com/rigortype/rigor/pull/3182)
- **Decided:** 2026-11-13

## Background

A reader the WD2 gate skips replays the run-scoped plugin rows (`disclose_once`, `emit_once`) it
already holds. The ledger does not record which def or key each row came through. Crediting the
probe's rows to skipped readers gave readers rows they never reach, and those rows were never
retracted. Leaving the rows alone kept a row after the def stopped registering it, which base
already did. Both leave a warm-only notice that a cold run does not report.

## Options and trade-offs

- **Credit the probe's rows (round 1).** Keeps the gate on, but gives wrong answers (stale or
  over-credited notices).
- **Decline the pair when its probe registers a row, or any reader holds one (taken).** No stale
  warm-only notice, but it costs precision. A plugin that registers a standing notice from every
  file, such as rigor-rails-i18n's `emit_once(:view_diagnostics, …)`, turns the gate off for every
  pair with a reader. In a measured fixture that re-analysed 9 of 12 files instead of 1 of 12; the
  output still matches a cold run.
- **Record provenance per row.** Precise, but it needs new ledger bookkeeping (#3201).

## Decision

Decline. As in #3182, a doubt in the gate resolves to re-analysis, never to a served answer. The
cost falls only on projects with standing plugin notices, and #3201 can win it back.

## To undo

Once #3201 records which def and key each ledger row came through, narrow
`IncrementalSession#readers_hold_disclosures?` to rows that came through the pair's def.
Nothing else depends on the decline.
