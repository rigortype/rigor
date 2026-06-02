# Plugin doc migration playbook (the "(ii)" split)

A self-contained handoff for a fresh / rewound session continuing
the per-plugin documentation migration. Read this **plus** the
checklist in [`docs/CURRENT_WORK.md`](../CURRENT_WORK.md) §
"Documentation overhaul" — together they let you continue at the
same quality without the originating session's accumulated context.

This is a **doc-only** track (no engine/spec code). Commits land on
`master`, not pushed.

## The decision

User-facing per-plugin docs live in the published manual; in-tree
READMEs keep developer/contract material. **Single-sourced — no
duplication.**

- **User page** → `docs/manual/plugins/<id>.md` (what it checks /
  infers, config, limitations).
- **README** (`plugins/<id>/README.md`) → internals (layout,
  architecture, demo, the plugin-contract surfaces it exercises),
  slimmed, with a top pointer up to the user page.
- **Index** → `docs/manual/plugins/README.md` (one line per
  plugin), already wired into `docs/manual/README.md` item 7.

24 of 31 done; 7 remain (the Tier-3 tail) — see the CURRENT_WORK
checklist for the exact `[x]`/`[ ]` list.

## CRITICAL: reconcile, don't copy

The single most important rule. Many plugin READMEs are **frozen at
their v0.1.0 landing** and are materially stale vs shipped
behaviour. Copying a README into the manual republishes stale
claims (this already happened once and had to be fixed). For each
plugin, **verify current behaviour before writing**:

1. `grep -niE "rigor-<id>" CHANGELOG.md` — read every behaviour
   entry since the plugin landed (skip the cross-cutting
   boilerplate entries: `config_schema` / `Source::Literals` /
   `node_rule` migration / meta-gem scaffold).
2. Read the plugin source: the manifest (`config_schema`,
   `consumes:` / `produces:`, `signature_paths:`) and the
   analyzer/parser (the rule IDs and shapes it actually handles).
3. Write the **current** capability/limitation set; **discard the
   README's frozen `(v0.1.0)` scope lists** ("Recognised DSL
   surface (v0.1.0)", "Out of scope (v0.1.0)").

### Catalog of recurring stale patterns (check every plugin for these)

These recur across the Rails family especially. Each is a real
correction made during this pass:

1. **Title cruft.** `# rigor-<id> — example Rigor plugin` (the
   "example" suffix; fixed on 10 plugins in `85e27336`). Also
   `(Phase N — …)` parentheticals implying partial when all phases
   landed (actionpack). Target: bare `# rigor-<id>` or an accurate
   descriptor.
2. **`.gemspec` in the Layout tree.** Per-plugin gemspecs were
   **removed** (only `rigor-playground` still has one). Any
   `├── rigor-<id>.gemspec` line in a README layout is stale →
   delete it.
3. **`diagnostics_for_file` in the authoring-surface table.**
   ADR-37 migrated every diagnostic-emitting plugin onto
   `node_rule` (+ `NodeContext` where the rule needs lexical
   context — enclosing class/action). Replace the row with
   `node_rule` (+ `NodeContext`).
4. **Hand-rolled inflection.** ADR-39 moved rails-routes /
   activerecord / actionpack / actionmailer / factorybot onto
   `Plugin::Inflector` (the **real `ActiveSupport::Inflector`**).
   So limitations like "regular plurals only; `Person→people` needs
   `table_name`" are stale (the real inflector handles irregulars).
   The genuine remaining gap: project-custom
   `config/initializers/inflections.rb` rules aren't ingested
   (ADR-39 slice 3).
5. **Retired distribution model.** subtree-split was retired
   (2026-06-02). Plugins ship **bundled in `rigortype`**; there is
   no per-plugin gem. Stale: `gem "rigor-<id>"` install lines,
   "Publication status", "extract via `git subtree split`",
   "publish to RubyGems", "`path:` overrides", "meta-gem".
6. **"Future direction" items that already landed.** Cross-plugin
   consumption claims especially — rails-routes "actionpack Phase 4
   will consume `:helper_table`" (done), rails-i18n "lazy lookup
   when actionpack lands" (done via NodeContext), factorybot "no AR
   column cross-check yet" (Phase 1c landed). Verify each against
   CHANGELOG before keeping it as "future".
7. **Internal contradictions within one README.** A later-added
   section contradicting an older "does NOT do" list — dry-struct
   (ADR-18 precision-uplift section vs "reader is Dynamic[T]" +
   "rigor-dry-types not yet authored"); dry-types ("does NOT do:
   user-authored compositions" though slice 3 added them). Resolve
   in favour of the newer/true section.
8. **RBS-overlay wiring.** `signature_paths: vendor/bundle/…/rigor-<id>-0.1.0/sig`
   is stale under bundling. The clean form is a manifest
   `signature_paths: ["sig"]` (ADR-25) — activerecord does this;
   **dry-validation does NOT yet** (flagged open item — a one-line
   plugin-code fix, left for review).

Quick stale-marker grep per plugin:
`grep -nE "gemspec|diagnostics_for_file|Out of scope \(v0.1.0\)|Publication status|subtree|example Rigor plugin" plugins/rigor-<id>/README.md`

## House style for the user page

Short and proportional. Most Tier-3 plugins are simpler than the
Rails core — fact-providers or macro-substrate consumers with **no
diagnostics and no config** — so their pages are short and skip the
mini-TOC (mini-TOCs are for long multi-section pages only).

Structure:

1. **Intro** (1 paragraph) — what it checks/infers; end with "It
   ships bundled in `rigortype`."
2. **Activate** — a `plugins:` YAML block (note any producer it
   needs, e.g. dry-types, and whether the dep is `optional`).
3. **What it checks / What it infers** — a short example + a
   diagnostics table (rule id / severity / fires-when) for
   diagnostic plugins; a contributed-types description for
   inference plugins.
4. **Configuration** — the config keys (with ADR-40 defaults). If
   none: a "**No diagnostics, no config**" section stating it
   supplies type info to other plugins / contributes synthesised
   methods.
5. **Limitations** — the *current*, reconciled ones only.
6. **Plugin internals** — a pointer: "…are in the
   [plugin's README](../../../plugins/rigor-<id>/README.md). To
   write a plugin, see [`examples/`](../../../examples/README.md)
   and the [`rigor-plugin-author`](../08-skills.md) skill."

**Handbook-pointer case:** when a handbook chapter already covers
the plugin deeply (Sorbet = handbook ch. 10), keep the manual page
thin and point to the chapter instead of duplicating it.

## README slimming

Keep dev sections: Layout (minus the `.gemspec` line), Architecture,
Running the demo, "Plugin authoring surface this exercises" (with
`node_rule` / `Plugin::Inflector` / `Base.suggest` rows corrected),
Future direction (de-staled), License. Add a top pointer block:

```
> **Using this plugin?** The user guide — <what> — lives in the
> manual at
> [docs/manual/plugins/rigor-<id>.md](../../docs/manual/plugins/rigor-<id>.md).
> This README covers the plugin's internals.
```

Remove the user-facing sections (they moved to the page).

## Link-path conventions (verified)

From `docs/manual/plugins/<id>.md`:
- plugin README → `../../../plugins/rigor-<id>/README.md`
- examples → `../../../examples/README.md`
- skill page → `../08-skills.md`
- handbook chapter → `../../handbook/NN-*.md`
- ADR → `../../adr/NN-*.md`
- sibling plugin page → `rigor-<other>.md`

From `plugins/<id>/README.md`:
- user page → `../../docs/manual/plugins/rigor-<id>.md`

## Index entry

Add to `docs/manual/plugins/README.md` "Available pages":
`- [rigor-<id>](rigor-<id>.md) — <one-line scope>.`

## Verification (before each commit)

1. Link existence — bash-check the relative paths resolve (page →
   README, README → page, and any handbook/adr targets).
2. Stale-marker grep on the touched README (the grep above) returns
   nothing.
3. **If** the page has a mini-TOC (rare for these short pages):
   spawn a read-only cold-read subagent to compute github-slugger
   anchors and confirm they resolve (no leading/trailing hyphens,
   no collisions). Short pages without a TOC skip this.
4. `git diff --check` (whitespace).

## Recommended execution shape (for the continuing session)

Hybrid keeps quality while parallelising the slow part:

- Fan out **read-only reconciliation scouts** (one per plugin, the
  `Explore` agent type) that produce a structured report: current
  capabilities / config / diagnostics / **detected stale claims** /
  a recommended user-page outline + README de-stale list. They
  don't write, so there are no index/file conflicts and no risk to
  the repo.
- The driving session writes the page + slims the README from each
  vetted report, then serialises the **index edits + link
  verification + commits** (the index is a shared mutable file —
  never let parallel writers touch it).

Or simply continue 4-at-a-time in the driving session — the tail is
short, so the cost difference is small and the quality is proven.
Do **not** use parallel *writers* (index conflicts + style drift +
weaker stale-detection).

## Special cases in the remaining tail

- **`rigor-playground`** — the browser-playground backend, not a
  checker plugin (still has the only per-plugin gemspec). Probably
  warrants only a one-line README pointer, not a full user page.
- **`rigor-activesupport-core-ext`** — an RBS-only bundle, not a
  walker; the page should explain it's an opt-in RBS bundle (the
  ActiveSupport core_ext methods like `3.days` / `"x".squish`), the
  single largest FP source on Rails apps if omitted.
- **`rigor-rbs-inline`** — has a handbook home (ch. 7 §
  "Inline RBS in Ruby source"); thin page + pointer, like sorbet.
- **`rigor-typescript-utility-types`** — covered in handbook ch. 4
  (shape projections) + the TypeScript appendix; thin + pointer.
- **`rigor-rspec-rails` / `rigor-shoulda-matchers`** — the rspec
  README already documents the boundary with these; reconcile
  against it.
