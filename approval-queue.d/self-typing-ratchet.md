# Hold `make coverage` to two-sided pins on precision and the Dynamic call share

- **PR:** [#3356](https://github.com/rigortype/rigor/pull/3356)
- **Issue:** [#3315](https://github.com/rigortype/rigor/issues/3315)
- **Class:** open-choice
- **Precedent:** [ADR-97](../docs/adr/97-adr-index-budgets.md)
- **Decided:** 2026-11-19

## Background

#3315 step 4 asked for a gate that stops the share of Dynamic call sites in Rigor's own `lib/` from growing back.
The only committed figure was `make coverage`'s precision ratio, held by a one-sided `--threshold 0.58` with about
1.6 points of slack. That is about 6,400 expressions, while the whole #3290–#3319 series moved the ratio by 0.12
points. The call-site figures quoted in #3315, #3353 and #3354 came from scratch scripts. The maintainer ruled
out a second whole-`lib` pass in CI: the ratchet rides on the scan `make coverage` already runs, with the key off.

## Options and trade-offs

- **Where the tally lives.** A second scanner would duplicate `PrecisionScanner`, which already types every
  `Prism::CallNode`. An internal-only seam would hide a figure users can act on. Three new keys in `rigor coverage
  --format json` are additive, which ADR-126 WD2 allows within `schema_version` 1. They also need a changelog entry
  and a manual paragraph.
- **Gate shape.** A one-sided threshold with drift margin (the old line) lets real regressions through. A two-sided
  pin with a small slack fails on gains too, so every typing batch must also edit the pins file, as the provenance
  residue pins do. Several small drifts can add up and trip an unrelated change, whose author then re-pins with a
  reason.
- **Slack size.** The scan is deterministic, so the slack only bounds the drift an ordinary change may carry
  unedited. Measured: ordinary commits moved either figure by at most 0.01 points per window of about 17 commits;
  removing four of #3354's declarations moves the share by 0.12 points, and all 28 of them moved it by 0.26.

## Decision

The tally goes in `PrecisionScanner` and is exposed in `rigor coverage`'s report. `tool/coverage_ratchet.rb` runs
that scan in-process and holds both figures to `tool/coverage_ratchet.yml`, at 0.10 points of slack each way. That
is ten times the drift measured on ordinary commits, and it still fails the four-declaration removal. A batch the
size of #3354 then has to lock its gain in. The one-sided 0.58 threshold is
replaced by the precision pin rather than kept beside it. The tool refuses another config, missing fields, parse
errors, a scan under the floors, and a move over `max_step`. ADR-97's index budgets are the closest precedent: a
committed number with a gate that names the fix.

## To undo

Restore `bundle exec exe/rigor coverage --config .rigor.gates.yml --threshold 0.58 lib` as the `coverage` recipe and
delete `tool/coverage_ratchet.rb`, its pins file and `spec/tool/coverage_ratchet_spec.rb`. The JSON keys can stay:
removing them now is a breaking change to `rigor coverage --format json`.
