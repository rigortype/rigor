# Plugin boilerplate reduction — phased plan

Status: **Plan, 2026-06-02.** Implementation roadmap for the boilerplate
findings in
[`20260601-plugin-mechanism-pre-1.0-review.md`](20260601-plugin-mechanism-pre-1.0-review.md)
§1. Non-normative; public-surface additions (new `Rigor::Source` /
`Plugin::Base` helpers) are recorded in [ADR-2](../adr/2-extension-api.md) /
[ADR-37](../adr/37-plugin-interface-segregation.md) as they land and pinned in
`spec/rigor/public_api_drift_spec.rb`.

## Guiding principle

**Eliminate the *reason* the boilerplate exists, don't just DRY it.** The
largest single duplication — the hand-rolled AST walker in ~25 plugins —
exists *only* because `diagnostics_for_file` hands over the raw `root` and
tells authors to walk it themselves. ADR-37's `NodeRule` makes the engine own
the walk, so those walkers disappear with their reason. Hand-building a clever
shared `walk` helper would therefore be wasted work.

So the work is split by a single test: **does the duplication survive ADR-37?**

- **Survives** → extract now (no-regret). These pay off immediately and are
  untouched by the interface-segregation refactor.
- **Absorbed by ADR-37** → do *not* hand-build a helper; let the refactor
  remove it.

## Inventory split (review §1.1 counts)

| Duplication | Count | Resolution | Survives ADR-37? |
| --- | --- | --- | --- |
| Literal Symbol/String extraction | 20 + 4 in core | `Rigor::Source::Literals` | ✅ extract now |
| `Diagnostic` construction (`start_column + 1`) | 23 | `Diagnostic.from_node` / `Base#diagnostic` | ✅ extract now |
| levenshtein / did-you-mean | 4 | `Base#suggest` (`DidYouMean::SpellChecker`) | ✅ extract now |
| `config.fetch` + `DEFAULT_*` | 17 | `config_schema` `default:` slot | ✅ extract now |
| Inflector copies | several | `Plugin::Inflector` | ✅ extract now |
| Discoverer skeleton + `NameKeyedIndex` + load-error rescue + cache idiom | 4 + 6 + 10 | `ClassDiscoverer` / `NameKeyedIndex` base (FactProvider side, orthogonal to `NodeRule`) | ✅ mid |
| **AST walker** | **25** | **`NodeRule` (engine-owned walk)** | ❌ do not hand-build |
| dispatch-loop duplication / fan-out | 2 | ADR-37 slice 2 (indexed registry) | ❌ absorbed |

The two highest-count items (walker 25, dispatch 2) are deliberately *not*
hand-patched — ADR-37 removes them.

## Phases (dependency order)

### Phase 0 — no-regret extractions

Each collapses a duplication that survives ADR-37 **and** de-duplicates the
core's own copies, so it pays off on both sides of the plugin boundary.

- **0a `Rigor::Source::Literals`** — `symbol_or_string(node)`,
  `symbol(node)`, `symbol_arguments(call)`, `symbol_arg(call, index)`.
  Collapses the 4 core copies (`sig_gen/observation_collector`,
  `sig_gen/generator`, `analysis/dependency_source_inference/return_type_heuristic`,
  `inference/synthetic_method_scanner`) first as a pure refactor, then is
  exposed for plugins.
- **0b `Diagnostic.from_node(node, path:, message:, severity:, rule:)`** +
  `Plugin::Base#diagnostic(node, …)` — internalises the load-bearing
  `start_column + 1` convention; collapses the inline pattern in
  `analysis/check_rules.rb` (15+ sites) and gives plugins a builder.
- **0c `Plugin::Base#suggest(name, candidates)`** — `DidYouMean::SpellChecker`
  wrapper; retires the hand-rolled `levenshtein` copies.
- **0d `config_schema` `default:` slot** — `Manifest` schema change; `Base#config`
  merges declared defaults so the `DEFAULT_*`-constant idiom retires.
- **0e `Rigor::Plugin::Inflector`** — one inflection module; retires the
  routes (×2), activerecord, actionmailer / actionpack `underscore` copies.

### Phase 1 — bridge (minimal investment)

Expose the existing `Rigor::Source::NodeWalker` on the plugin surface + doc.
One `require` + documentation only — it retires naturally as plugins migrate
to `NodeRule`, so no further investment here.

### Phase 2 — discovery bases (FactProvider side, orthogonal to NodeRule)

`ClassDiscoverer` base + `NameKeyedIndex` + `discover_ruby_files`
(folds `ruby_files_under` + `read_safely` + the `rescue` triple) + the
standard `glob_descriptor` cache idiom. Migrate the four Rails discovery
plugins (activejob / actioncable / activestorage / actionmailer), deleting
~4 files of near-identical AST-walking + index code.

### Phase 3 — absorbed by ADR-37

`NodeRule` landing removes the 25 walkers, the 23 inline `Diagnostic` builds
(now via `Base#diagnostic`), and the duplicated dispatch loop. Add the
`ProtocolContractChecker` base (hanami / web verbatim duplication) here.

## Migration mechanics (safety)

- Each extraction is a **pure refactor** — behaviour-preserving. The safety
  net is the existing `run_plugin` integration specs used as a golden master,
  plus `make verify` (test-parallel + lint + self-check) staying green on
  every slice.
- Migrate **one plugin family per PR**; each PR demonstrates "duplication
  N → 1, tests unchanged".
- Track the review §1.1 duplication counts before/after so progress is
  quantitative.
- Public-surface additions update `spec/rigor/public_api_drift_spec.rb`
  snapshots and are recorded in ADR-2 / ADR-37.

## First step

**Phase 0a (`Rigor::Source::Literals`).** Highest ROI: it de-duplicates 4
core copies and 20 plugins, survives ADR-37 untouched, and is a pure refactor
with minimal regression risk.
