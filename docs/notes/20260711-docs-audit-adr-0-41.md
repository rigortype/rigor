# ADR status-fidelity audit — ADR-0 through ADR-41 (2026-07-11)

Lens: status accuracy only (not decision quality, not writing). For each ADR the four
sources checked were {ADR file `Status:` field · `docs/adr/README.md` index row ·
`CLAUDE.md` ADR bullet · reality (CHANGELOG-0.1.x / CHANGELOG.md / `lib/`)}.

## Drift table

| ADR (file) | file status | README status | CLAUDE.md | reality | drift | severity | proposed fix |
| --- | --- | --- | --- | --- | --- | --- | --- |
| ADR-19 (`19-language-server-packaging.md`) | "Accepted, 2026-05-17" (no impl note) | "Accepted" (no impl note) | title pointer only | **shipped** — `rigor lsp` command (`lib/rigor/cli/lsp_command.rb` + `lib/rigor/language_server/`); LSP v1/v2 + follow-ups across v0.1.x; the ADR's own body line 13 states "Language Server v1 landed in v0.1.6" | Status field and README row understate: both say bare "Accepted" while the file body **and** reality confirm implementation. Sibling implemented-feature ADRs (17/18/32/33/34) carry "implemented in v0.1.x" in both their status line and README row; ADR-19 alone omits it. | Low (understatement, not a contradiction) | Status line → "Accepted, 2026-05-17; LSP v1 implemented in v0.1.6"; README-19 row → "Accepted (LSP v1 implemented in v0.1.6; v2 + follow-ups across v0.1.x)". |
| ADR-37 (`37-plugin-interface-segregation.md`) | "Slices 1–3 implemented; `flow_contribution_for` REMOVED 2026-06-11 (ADR-52 WD3)" | "(Slices 1–3 implemented; all bundled walker plugins migrated)" — **no removal note** | "accepted, Slices 1–3" | hook genuinely deleted — verified: remaining `flow_contribution_for` refs in `lib/rigor/plugin/registry.rb` are the fail-closed load-time ArgumentError guard, the rest are historical comments; ADR-52 WD3/5b confirm the deletion | README (and CLAUDE bullet) omit the removal milestone the ADR file records. Not a contradiction — README is merely stale on the post-migration deletion. | Low | Append to README-37 row: "; the legacy `flow_contribution_for` hook was deleted 2026-06-11 (ADR-52 WD3)". Optional — informational only. |

## Everything else in range: consistent

- ADR-0–5, 8, 12: bare "Accepted" in file + README + CLAUDE; foundational/shipped, no
  claim of un-implemented, no contradiction. Not defects.
- Version-stamped implemented ADRs — 9 (v0.1.1), 10/11/13/14 (v0.1.4), 17 (v0.1.13),
  18 (v0.1.6), 22 (v0.1.7–0.1.9), 23 (v0.1.9), 32/33 (v0.1.10), 34 (v0.1.13): file
  status, README, and CLAUDE all agree with the CHANGELOG.
- Partial/deferred ADRs — 15 (fork active / Ractor deferred), 16 (slices 1–7 + 6a/6b),
  20 (partial HKT), 27 (partial; single binary deferred), 35 (slices 1–4; 5 deferred),
  36 (Slice A), 38 (def-form; block deferred), 39 (Inflector + 3 consumers; slice 3
  deferred), 40 (mechanism + 13 plugins): the per-WD / per-slice sub-statuses match
  across all three doc sources.
- Proposed / not-implemented ADRs — 21 (Rubydex evaluation), 30 (`rigor-ffi`; confirmed
  no `plugins/`|`examples/` ffi gem exists), 41 (inference budgets; spec `budgets:`
  table genuinely unwired — `BudgetTrace` is trace instrumentation only, not the spec
  table): "Proposed" is accurate in all three sources.
- ADR-24 → ADR-57 cross-reference ("WD3 in-body adoption gate opened by ADR-57,
  2026-06-12"): target exists, relationship reciprocated in README-24 + CLAUDE + ADR-57.
- ADR-26 (ActiveRecord relation typing / `open_receivers`): file "implemented", README
  "Accepted", CLAUDE accepted; `open_receivers` present in `lib/rigor/plugin/manifest.rb`
  + `registry.rb` — implemented, sources compatible (README "Accepted" not wrong).
- ADR-7 "partially superseded by ADR-54" (body) — status correctly stays Accepted;
  target ADR-54 exists. No wholesale-Superseded ADR in the 0–41 range.

## Verdict

Status hygiene across ADR-0–41 is strong: 40 of 42 records agree across file /
README / CLAUDE / reality, with no reversed status (nothing "Proposed/not-implemented"
that shipped, nothing "Accepted/implemented" that is vapour). The two findings are both
low-severity **understatements**, not contradictions: ADR-19's status field and README
row omit the "implemented in v0.1.6" milestone that the ADR's own body and every
comparable implemented-feature ADR record, and README-37 lags the file on the
`flow_contribution_for` deletion. Neither misleads a reader about whether the work
shipped; both are one-line touch-ups. The cross-cycle items called out for confirmation
— ADR-26 (implemented) and the ADR-24→ADR-57 module-singleton gate reference — are
current and correctly reflected.
