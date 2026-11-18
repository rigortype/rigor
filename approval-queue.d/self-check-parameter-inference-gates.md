# Keep `parameter_inference:` off for the self-check's consistency and precision gates

- **PR:** [#3353](https://github.com/rigortype/rigor/pull/3353)
- **Issue:** [#3324](https://github.com/rigortype/rigor/issues/3324)
- **Class:** scope
- **Precedent:** none — sets one
- **Decided:** 2026-11-19

## Background

#3324 turns `parameter_inference: true` on in `.rigor.dist.yml`. Before this PR, that one file configured every
self-check path: `make check`, `check-json`, `check-plugins`, `check-incremental`, `make coverage`, CI's cold, warm
and bleeding-edge self-check jobs, the memo audit, the `type_of` shadow runs and `ruby-next.yml`'s weekly self-check.
The lane first kept the key out of `make coverage` alone. Review showed the key also roughly doubles the required
`acceptance-gates` job: about 27 min to about 54 min, of which the memo audit is +18 min (2.4x locally),
`check-incremental` +5.5 min (1.8x) and the shadow +3 min. The maintainer ruled on the split on 2026-11-19
(variant B in the PR).

## Options and trade-offs

- **A: every consumer inherits the key.** One configuration everywhere. The gates also check cache and incremental
  consistency, and the memo audit, under parameter-inferred types on Rigor's own tree. `acceptance-gates` goes to
  about 54 min.
- **B: only the self-check proper and `check-plugins` use the key.** `make check`, `check-json`, `check-plugins`,
  the CI self-check jobs and `ruby-next.yml` read `.rigor.dist.yml` with the key on. These keep the key off through
  `.rigor.gates.yml` (`includes: .rigor.dist.yml` plus `parameter_inference: false`): `make coverage`, both
  `make check-incremental` lines, the memo audit and both `type_of` shadow runs. `acceptance-gates` stays at about
  27 min.

## Decision

B, as ruled by the maintainer. Those gates check the same things they checked on master, where every step ran with
the key off, so nothing they gated before is lost. `make coverage` also keeps its threshold, which is calibrated on
the key-off engine.

What is therefore not gated: cache and incremental consistency (ADR-46), the callee-floor memo audit (ADR-127 WD3)
and the `type_of` shadow (ADR-129) on Rigor's own tree with the key on. On fixtures, the incremental
parameter-table path is covered by `spec/rigor/analysis/incremental_session_spec.rb`.
`spec/rigor/self_check_gates_config_spec.rb` holds the split in place: the gates file may differ from
`.rigor.dist.yml` only in `parameter_inference:`, and each listed Makefile target and CI step must pass it with
`--config`.

Revisit when the memo audit and the incremental check become cheap enough with the key on to run in
`acceptance-gates` without roughly doubling it.

## To undo

Drop `--config .rigor.gates.yml` from the `check-incremental` and `coverage` targets in the `Makefile`, and from
the memo-audit and shadow steps in `.github/workflows/ci.yml`. Delete `.rigor.gates.yml` and
`spec/rigor/self_check_gates_config_spec.rb`, and re-calibrate the coverage threshold against the key-on figure
(64.45 % on 2026-11-19).
