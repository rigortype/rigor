# Hold `make coverage` to one-sided pins on precision and the Dynamic call share

- **PR:** [#3356](https://github.com/rigortype/rigor/pull/3356)
- **Issue:** [#3315](https://github.com/rigortype/rigor/issues/3315)
- **Class:** process
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
- **Two-sided or one-sided.** The first version of #3356 failed past ±0.10 points either way, so gains were locked in
  by force. The review measured the figures across 17 merged PRs, and an ordinary refactor moved one by 0.02 to 0.047
  points. Walking a pin forward from `a8967d161`, the first failures were #3301 and then #3308, both refactors, both
  on the improvement side. That is a failure about every 1.5 days at the current merge rate, and it blames the PR in
  hand. One-sided, a refactor fails only when it pushes a figure more than 0.10 points worse than the pin. The cost
  is that nothing forces tightening, so a gain can sit unclaimed and later absorb a real loss.
- **Slack size.** The scan is deterministic, so the slack only bounds the drift changes carry against a pin. Ordinary
  single-PR movement peaks near 0.05 points. Removing four of #3354's declarations moves the share by 0.12 points, and
  all 28 of them moved it by 0.26.

## Decision

The tally goes in `PrecisionScanner` and is exposed in `rigor coverage`'s report. `tool/coverage_ratchet.rb` runs
that scan in-process and holds both figures to `tool/coverage_ratchet.yml`, one-sided, at 0.10 points. That is
twice the largest ordinary single-PR movement measured, and it still fails the four-declaration removal. A gain past
the slack passes with a notice that prints the new pin lines. `make coverage-tighten` writes gains in and never
loosens a pin. Tightening has two owners: the PR that lands a typing batch, and release prep, whose checklist now
runs it. Moving a pin the worse way is a `gate-row` decision (contribution-flow.md). The first such move has no
precedent in the pins file and is therefore serious. The one-sided 0.58 threshold is replaced by the precision pin
rather than kept beside it. The tool refuses another config, missing fields, parse errors, a scan under the floors,
and a move over `max_step` either way. ADR-97's index budgets are the closest precedent: a committed number with a
gate that names the fix.

Revisit when a release window sees more than two incidental worse-side failures, where the change's own delta was
within the slack and earlier drift made up the rest. Revisit too when a release finds a pin lagging its measured
figure by more than 0.5 points, which would mean the two owners are not tightening.

## To undo

Restore `bundle exec exe/rigor coverage --config .rigor.gates.yml --threshold 0.58 lib` as the `coverage` recipe,
drop `coverage-tighten`, and delete `tool/coverage_ratchet.rb`, its pins file, `spec/tool/coverage_ratchet_spec.rb`
and the release-prep checklist line. The JSON keys can stay: removing them now is a breaking change to `rigor
coverage --format json`.
