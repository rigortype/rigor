# Overview-docs fidelity audit — 2026-07-11

Fidelity lens over Rigor's user-facing **overview** docs (front door +
one-pagers + catalogues), checked against the current tree on branch
`docs/consistency-audit-0.2.9` (`Rigor::VERSION = 0.2.8`, `[Unreleased]`
= the 0.2.9 cut). Scope: `README.md`, `docs/types.md`,
`docs/compatibility.md`, `docs/install.md`, `plugins/README.md`,
`examples/README.md`.

Verdict up front: the overviews are in good shape. No feature-currency
gaps, no catalogue-count drift, no dead commands/flags. Three genuine
inaccuracies, all in the reference layer (compatibility surface +
install routing); none in the README's design commitments.

## Findings

| Location (file:line + quote) | Problem | Severity | Proposed fix |
| --- | --- | --- | --- |
| `docs/compatibility.md:73` — "the [ADR-37] narrow protocols: `node_rule` / `dynamic_return` / `type_specifier`" | `type_specifier` was renamed to `narrowing_facts` in **v0.2.6** (ADR-80, shipped; `lib/rigor/plugin/base.rb:395` `def narrowing_facts`, `:413` `def type_specifier` is a deprecation-warning alias removed in 0.3.0). The public-surface *authority* doc names the deprecated verb as the canonical frozen hook. | MISLEADING | Change to `narrowing_facts` (optionally "`narrowing_facts` (was `type_specifier`, ADR-80)"). |
| `docs/compatibility.md:76` + `:103` — cache marker "(marker `4.2`)" / "Current value `4.2`" | The `schema_version.txt` marker is composed as `PAYLOAD_ABI_VERSION.SCHEMA_VERSION.FORMAT_VERSION` (`store.rb:127`), and `PAYLOAD_ABI_VERSION = Rigor::VERSION` (`store.rb:38`, folded in this cycle per `[Unreleased]`). Actual on-disk marker is `<version>.4.2` (e.g. `0.2.8.4.2`), not `4.2`. A pipeline keying on the literal value would be misled; the doc's two-part formula also omits the version component. | FRICTION | List the marker as `<Rigor::VERSION>.<SCHEMA>.<FORMAT>` (currently `<version>.4.2`), or drop the literal value and describe it as "version- + schema- + format-composed, invalidate-never-misread". |
| `docs/install.md:46-47` (Case A: `mise use ruby@4.0` project-local, "Commit `mise.toml`") vs `README.md:19-21,113-121` (global `-g`, "each project keeps its own Ruby") | The README's mechanism for "the tool runs on Ruby 4.0 while your project keeps its own Ruby" is the **global** `-g` install. install.md Case A instead pins `ruby@4.0` **project-locally** and commits it, which overrides the project's own Ruby — contradicting the README's central promise. The two front-door install paths disagree on global-vs-local. | FRICTION | Align Case A with the README: `mise use -g ruby@4.0` + `mise use -g gem:rigortype` (global tool pin), or add a sentence explaining the deliberate split and that project-local pins the project to Ruby 4.0. |

## Verified accurate (no drift)

- **Plugin catalogue count** — `plugins/README.md:2` "Thirty-one entries" matches the 31 directories under `plugins/`; every dir is listed in the catalogue. (The count CLAUDE.md warns about is currently correct.)
- **Examples catalogue** — `examples/README.md:3` "Six walkthroughs" matches the 6 dirs under `examples/` (`rigor-web` included).
- **All CLI commands** named across the docs resolve to `CLI::HANDLERS` (`cli.rb:23-47`): `check init annotate type-of explain sig-gen lsp mcp baseline triage coverage plugins plugin playground skill describe docs show-bleedingedge doctor upgrade` (+ `trace type-scan diff`).
- **`rigor docs` subforms** (`README.md:226-230`) — `rigor docs`, `rigor docs handbook/03-narrowing`, `rigor docs --list` all match `docs_command.rb` (category-qualified name / `--list`).
- **Skills referenced** — `rigor-plugin-author`, `rigor-baseline-reduce`, `rigor-next-steps`, `rigor-ask` all exist under `skills/`.
- **Cache dir** — README's "caches under `.rigor/`" matches the `.rigor/cache` default (`configuration.rb:59`).
- **Baseline version** `1`, **`documentation_uri` → master**, CI native formats, and the "Hello, Rigor" `demo.rb:7:3` line/column all check out.
- **README design commitments** — the no-annotations / infer-from-values / sig-gen-in-sync / FP-is-worst-bug / spec-assertions stance (ADR-59) statements do not contradict current behaviour.
- **This-cycle features** (`db/structure.sql`, actionpack strong-params, module-singleton ADR-57 WD3, external-gem provenance ADR-82 WD9, grape-path-helpers namespace, `coverage` parallelism + no-path `paths:` fallback) are all in `[Unreleased]`; the README `Status` correctly still reads `v0.2.8` (they are not yet released), so this is not a currency gap.

## Intentional simplification (not flagged)

- `docs/types.md` display convention (`Constant<3>`, `int<0, max>`) deliberately differs from the engine's `#describe` / internal-spec bracket forms — the doc says so explicitly (line 29). Conceptual quick-guide, correctly non-exhaustive.
- `docs/compatibility.md:71` CLI list ends in "…"; omitting newer `docs`/`doctor` from the named set is fine given the explicit non-exhaustive marker (nitpick at most).
- `plugins/README.md:6` "(v0.1.11)" is a historical anchor for when bundling landed, not a claim about the current version — accurate as written.

## Verdict

The overview docs are current and largely faithful: feature set, plugin
(31) and example (6) catalogue counts, every referenced command/flag,
skill, and the README's design commitments all check out against the
tree, and the this-cycle features are correctly held back as
`[Unreleased]`. The only real defects live in the two reference-authority
docs — `compatibility.md` still names the deprecated `type_specifier`
hook instead of `narrowing_facts` (a MISLEADING drift in the very doc
that defines the frozen vocabulary) and quotes a stale cache marker value
(`4.2`) now that `Rigor::VERSION` is folded into it — plus a global-vs-
project-local Ruby-pin inconsistency between `README.md` and
`install.md` Case A. All three are small, localized edits; none touch the
type-model prose or the plugin catalogues.
