# Design Notes

Forward-looking **design documents** — roadmaps, slicing decisions, and feature
sketches authored *before* a decision is ratified. They explore a problem space,
weigh options, and propose a direction.

These documents are **non-normative**. When a design here is accepted it graduates
into an [ADR](../adr/README.md) (rationale) and/or the
[type specification](../type-specification/README.md) / [internal spec](../internal-spec/README.md)
(binding behaviour); the spec and the ADR bind, the design note does not. A note may
be partially superseded, stale, or never sliced — read the **Status** line at the
top of each before relying on it.

Filenames are `YYYYMMDD-<slug>.md`, dated to authorship.

## Index

| Date | Document | Status |
| --- | --- | --- |
| 2026-05-05 | [Cache slice taxonomy — pre-v0.1.0 design notes](20260505-cache-slice-taxonomy.md) | Draft (informs [ADR-6](../adr/6-cache-persistence-backend.md)) |
| 2026-05-05 | [v0.1.0 readiness — pre-plugin design notes](20260505-v0.1.0-readiness.md) | Draft (historical) |
| 2026-05-08 | [Rails Ecosystem Plugins — Roadmap](20260508-rails-plugins-roadmap.md) | Planning (live; linked from CLAUDE.md) |
| 2026-05-09 | [dry-rb Ecosystem Plugins — Survey](20260509-dry-plugins-roadmap.md) | Research (informs [ADR-12](../adr/12-dry-rb-packaging.md)) |
| 2026-05-09 | [Rigor and Tapioca — Comparison and Strategy](20260509-rigor-tapioca-comparison.md) | Notes |
| 2026-05-09 | [`rigor-tapioca`? — Tapioca DSL-RBI Coverage Investigation](20260509-rigor-tapioca-investigation.md) | Investigation |
| 2026-05-14 | [Ractor migration — staged plan](20260514-ractor-migration.md) | Draft (Phase 1 landed; see [ADR-15](../adr/15-ractor-concurrency.md)) |
| 2026-05-16 | [Editor mode — single-file fast-response analysis](20260516-editor-mode.md) | Draft |
| 2026-05-17 | [`rigor-dry-validation` — slicing decision](20260517-dry-validation-slicing.md) | Design note |
| 2026-05-17 | [Language Server — in-process Ruby LSP for Rigor](20260517-language-server.md) | Draft (→ [ADR-19](../adr/19-language-server-packaging.md)) |
| 2026-05-17 | [LSP v2 — type-aware hover + completion](20260517-lsp-hover-completion.md) | Draft |
| 2026-05-18 | [CLI editor mode — disk-backed `ProjectScan` snapshot cache](20260518-cli-disk-snapshot-cache.md) | Design note |
| 2026-05-22 | [VSCode extension — first-party marketplace client for `rigor lsp`](20260522-vscode-extension.md) | Draft |
| 2026-06-01 | [Plugin mechanism — pre-1.0 review (過不足 / ペインポイント / ボイラープレート)](20260601-plugin-mechanism-pre-1.0-review.md) | Research (pre-1.0 optimization; would inform an [ADR-2](../adr/2-extension-api.md) revision) |
| 2026-06-02 | [Plugin boilerplate reduction — phased plan](20260602-plugin-boilerplate-reduction-plan.md) | Plan (implements review §1; tied to [ADR-37](../adr/37-plugin-interface-segregation.md)) |

## Adding a design note

1. Name the file `YYYYMMDD-<slug>.md` using the authorship date.
2. Open with a `Status:` line stating the kind (Draft / Design note / Research /
   Investigation / Planning) and what would supersede it.
3. Add a row to the index table above.
4. When the design is ratified, open an ADR and/or amend the spec, and update the
   note's Status to point at the binding document.
