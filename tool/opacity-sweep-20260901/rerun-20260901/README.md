# Re-run of the opacity probe on the merged master (2026-09-01, `a7e5d805`)

Post-campaign re-measurement discharging the parent sweep's under-seeded-lens caveat; the probe (`../probe_attrib.rb`, byte-identical) inherits the post-#535 full-seed plugin-aware lens via `CoverageScan.discovery_seeded_scope`. Synthesis: `docs/notes/20260901-post-campaign-opacity-recheck.md` on master.

- `<target>.json` — raw probe output per target (30 targets; `run_all.sh` is the batch driver, `aggregate.py` the cross-target aggregation).
- `attribution/tier_dump.rb` — the three-arm A/B lens (probe-identical classify + per-expression tier/type dump, `RIGOR_LIB` env override to point at a read-only engine checkout) that attributed the numo-narray −3.44pp / DSA-in-Ruby −0.54pp drops wholly to #537/#559. Arms used: base `2d0ffe6f`, base+#537 `3d5dddbb`, master `a7e5d805`.
- `attribution/repro/` — the minimal flip repros (`[true] * n`, numeric-arith joins, phantom-Hash).
