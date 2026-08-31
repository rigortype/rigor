# Opacity-attribution sweep harness — 2026-09-01

Instruments and per-target reports for the corpus-wide "where do types not attach" sweep (25 targets: rigor-lib, redmine, mastodon, 22 gems/corpora). The synthesis lives in `docs/notes/20260901-corpus-opacity-attribution.md` on master; this branch preserves the harness and the raw per-target case reports it cites.

- `probe_attrib.rb` — the shared attribution probe: mirrors the precision lens (CoverageScan seeding + PrecisionScanner walk/classifier, plugin-aware environment) and records, per opaque expression, the node class, local-read parameter bucket, call-receiver tier, and the (precise receiver, method) pairs whose dispatch still answers Dynamic. Run from the rigor repo root inside the Flake: `bundle exec ruby probe_attrib.rb TARGET_DIR OUT_JSON [PATHS...]`.
- `reports/<target>.md` + `<target>.summary.json` — the eight analysis agents' per-target case reports (mechanism, category A-G, verified example sites).
- `repros/` — the minimal reproduction scripts the reports cite (same-file dispatch controls, bisect harnesses, the `minisplat/` two-file lens-seeding repro project).

Caveat carried from the sweep: the probe shares issue #513's under-seeded lens (it seeds discovered_classes + param table only), so per-target site counts OVERSTATE product-level holes wherever `rigor check`'s eleven-table seed resolves a cross-file call the lens cannot. Mechanisms verified by same-file controls are unaffected.
