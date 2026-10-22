# Seed rigor type-of from the incremental snapshot, at full check parity

- **PR:** [#2281](https://github.com/rigortype/rigor/pull/2281)
- **Issue:** [#512](https://github.com/rigortype/rigor/issues/512)
- **Class:** open-choice
- **Precedent:** [#2188](https://github.com/rigortype/rigor/pull/2188)
- **Decided:** 2026-10-22

## Background

`rigor type-of` used a bare single-file scope, so cross-file classes read `Dynamic[top]`. The issue withdrew the whole-project-parse fix (2x cost) and asked for a seed from something already built, with a warm cost of "a few hundred ms" and silent single-file fallback.

## Options and trade-offs

- **Fold the snapshot's seed bundles, full tables (taken).** Same tables `check` seeds, so answers agree with `check`. Needs a prior `rigor check --incremental`. Measured warm: redmine (352 files) 1.2s to 1.7-1.9s; Rigor's own `lib` (609 files, a dense file) 1.7s to 4.1s. The seed itself costs about 0.2-0.4s (fingerprint, snapshot load, fold); the rest is the engine now doing the cross-file inference `check` does for that file.
- **Seed only class and constant tables.** About +0.4s, but a class known without its method tables lets the RBS `Class`/`Object` tiers answer a method the project overrides (`def self.name`), a confident wrong type. Rejected on the false-positive discipline.
- **Parse the project when no snapshot exists.** The withdrawn approach.

## Decision

Full tables, snapshot only, silent fallback. The "few hundred ms" target is not met on dense files; correctness over `check` parity was preferred to a partial seed (ADR-5, false positives outrank). Not applied: the ADR-67 parameter-inference seed, and the `uncertain:` re-walk set (same as the LSP seed).

## To undo

Make `CoverageScan.probe_scope` return `Scope.empty(environment:)`. The docs paragraph in `docs/manual/02-cli-reference.md` and the changelog fragment go with it.
