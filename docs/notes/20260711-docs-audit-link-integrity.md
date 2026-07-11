# Docs audit — whole-tree link integrity (2026-07-11)

Part of the comprehensive "other docs" consistency audit (step 2 follow-up). The L0 `link_integrity_spec`
previously covered only `docs/handbook/` + `docs/manual/`. Swept every relative markdown link across the
whole `docs/` tree + top-level READMEs.

## Result

**Shipping / normative docs are link-clean: 0 broken across 259 files / 2,664 relative links** (with
`#anchor` fragments and `:line` source-pointer suffixes stripped, and code spans ignored). This covers
`docs/{type-specification,internal-spec,adr,design}`, the top-level `docs/*.md` (ROADMAP, compatibility,
types, install, CURRENT_WORK), and README / plugins / examples.

## The one real cluster — frozen archive changelogs (NOT fixed, by decision)

`docs/CHANGELOG-0.0.x.md` and `docs/CHANGELOG-0.1.x.md` carry ~200 broken relative links. Root cause: they
were split out of the root `CHANGELOG.md` (where `docs/adr/…` / `lib/…` root-relative links resolve
correctly) into `docs/` **without rewriting the links**, so from their new location `docs/adr/…` resolves
to `docs/docs/adr/…`. Additionally, several targets (`lib/rigor/flow_contribution.rb`,
`docs/internal-spec/cache.md`, `docs/MILESTONES.md`, …) point to files renamed or removed since the 0.1.x
era.

**Decision: leave them.** These are frozen historical records; the links were correct relative to the repo
root when authored, and mass-rewriting ~200 links — several to files that no longer exist — is high-churn,
partially-impossible revisionism on a changelog archive. Recorded here, excluded from the gate.

`docs/notes/` also carries root-relative and external-paper links (transient review/session memos, not
shipping docs) — likewise excluded.

## Change landed

Extended `spec/docs/link_integrity_spec.rb` to gate the **whole `docs/` tree** (not just handbook +
manual), excluding `docs/notes/` and the `CHANGELOG-0.*.x.md` archives, and to strip a trailing
`:line`/`:line:col` source-pointer suffix before the existence check. 230 `make docs-check` examples green.
