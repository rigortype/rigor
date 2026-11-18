# Keep `parameter_inference:` out of the `make coverage` precision gate

- **PR:** [#3353](https://github.com/rigortype/rigor/pull/3353)
- **Issue:** [#3324](https://github.com/rigortype/rigor/issues/3324)
- **Class:** scope
- **Precedent:** none — sets one
- **Decided:** 2026-11-19

## Background

#3324 turns `parameter_inference: true` on in `.rigor.dist.yml`, the one configuration every self-check
path reads: `make check`, `check-plugins`, `check-incremental`, the memo audit, the `type_of` shadow
runs, the warm, cold and bleeding-edge self-check jobs and `bin/verify-changed`. `make coverage` reads it
too, through `CoverageScan#precision_report`, which seeds the parameter table when the key is on. The
lane brief left open whether the precision gate should inherit the key.

## Options and trade-offs

- **Inherit it.** One configuration for every self-check path, and the gate measures the engine
  `make check` runs. Measured on this machine (load average 12–55): 101.7 s -> 307.2 s and 0.99 GB ->
  1.26 GB, in the acceptance-gates job, already the slowest; precision 59.45 % -> 64.45 %, so the
  58 % threshold would carry about 6.5 points of slack where the Makefile's own calibration note
  argues for about 1.5 ("a gate that carries slack cannot fail on any regression a person would ship").
  Keeping the gate useful would mean re-calibrating the threshold in this PR.
- **Keep it out** with `.rigor.coverage.yml` (`includes: .rigor.dist.yml` plus `parameter_inference:
  false`) and `--config` in the target. The gate keeps its calibration and its cost; it measures a
  different engine from `make check`, which the Makefile comment says.

## Decision

Keep it out. The precision gate's job is to catch a regression against a calibrated band, and that
band was measured with the key off; re-calibrating it belongs with the Dynamic-share ratchet #3315
ends at, which will be measured with the key on.

## To undo

Delete `.rigor.coverage.yml` and the `--config` argument in the `coverage` target, and re-calibrate
the threshold against the key-on figure (64.45 % on 2026-11-19).
