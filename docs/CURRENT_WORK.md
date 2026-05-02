# Current Work — Inference Engine Checkpoint

This is a transient bookmark used to break a long implementation thread into reviewable chunks. The **normative** contracts and slice roadmap remain in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md). The release-by-release commitment envelope lives in [`docs/MILESTONES.md`](MILESTONES.md). If this file disagrees with any of those, the spec / ADR / milestone binds and this file is out of date.

## Status

**v0.0.4 released 2026-05-02.** The branch is at a clean shipping state: 1250 RSpec examples / 0 failures, RuboCop clean, `bundle exec exe/rigor check lib` reports 0 diagnostics, `gem build rigortype.gemspec` produces `rigortype-0.0.4.gem` cleanly. `lib/rigor/version.rb`, `Gemfile.lock`, and `CHANGELOG.md`'s `[0.0.4]` heading agree on the release version.

The summary of what shipped in v0.0.4 is in `CHANGELOG.md`'s `[0.0.4] - 2026-05-02` section and the v0.0.4 row of [`docs/MILESTONES.md`](MILESTONES.md). Not duplicated here.

## Where the Work Resumes

The next preview is **v0.0.5**. The full planned surface is in [`docs/MILESTONES.md`](MILESTONES.md); the items below are the operational entry points for restarting work, not a re-statement of the milestone.

### Highest-leverage next slices

- **More Enumerable methods.** `#each_with_index` landed in v0.0.4. The natural follow-ups are `#each_with_object` (memo type follows the second argument), `#inject` / `#reduce` (memo + element pairs, with seed-from-first-element semantics), `#group_by` / `#partition` (returning shaped containers), and IO line iteration. Each can land independently in `IteratorDispatch`.
- **Refinement negation in `assert:` / `predicate-if-*:`.** Refinement-form directives currently reject `~T` payloads. Landing them needs a small difference-against-refinement algebra so `assert value is ~non-empty-string` narrows the local to `Constant[""]`. The arithmetic lives entirely in `Inference::Narrowing`; the parser already accepts the syntax.
- **Catalog imports continue.** The next concrete-class candidates are Date / DateTime (stdlib gems under `references/ruby/ext/date/`). Comparable / Enumerable are modules and need a different topic shape than concrete-class imports — `tool/scaffold_builtin_catalog.rb` may grow a `--module` mode for that, or a sibling `tool/scaffold_builtin_module.rb` script.
- **C-body classifier upgrades.** Track indirect mutator helpers (`str_modifiable`, `ary_resize`, `time_modify`, `set_compare_by_identity`, …) so per-class blocklists shrink. Each new class import currently re-discovers the helpers the regex misses; the long-term direction is for `:leaf` to be a high-precision set so blocklists are the exception.
- **Catalog diff tooling.** A `make catalog-diff` that prints (additions, removals, purity-changes) between two extractor runs would catch CRuby submodule bumps shifting symbol names; today the only signal is per-method test breakage.

### Out of v0.0.5 / v0.0.x scope (intentional)

- Caches and the plugin API (ADR-2) are reserved for v0.1.0. See [`docs/MILESTONES.md`](MILESTONES.md).
- New CheckRules rule families beyond the v0.0.3 `always-raises` line. Type-incompatible writes, return-type mismatch, unreachable branches stay deferred until the inference surface they depend on is sturdy.

## Open Engineering Items

Persistent items that have come up across v0.0.x slices and that the next implementer benefits from seeing without re-reading the full thread:

1. **`spec/rigor/source/node_locator_spec.rb:82`** — `String#index` returns `Integer | nil` followed by an unguarded `+ 1`. The `possible-nil-receiver` rule flags it correctly; the spec uses a load-bearing nil-or-throw idiom that is awkward to express. Either add a `# rigor:disable possible-nil-receiver` line or rewrite the spec to guard explicitly. Not a blocker — the analyzer is correct.

2. **C-body classifier indirect mutators.** The catalog extractor's regex does not follow `str_modifiable` / `time_modify` / similar helper indirection; methods like `String#replace`, `Time#localtime`, and `Set#reset` land as `:leaf` even though they mutate. Per-class blocklists in `STRING_CATALOG` / `TIME_CATALOG` / `SET_CATALOG` absorb the false positives. Long-term: the classifier should track the helpers transitively so blocklists shrink.

3. **`numeric.yml` `unknown` entries.** Two methods stay `unknown` after the v0.0.3 extraction:
   - `Numeric#clone` (cfunc `num_clone` aliases to `rb_immutable_obj_clone` in `object.c`, not in the indexed C files).
   - `Integer#ceildiv` (prelude body delegates to user-overridable `#div`, classified as `composed`).
   Adding `references/ruby/object.c` to the Numeric topic's `c_index_paths` resolves the first; the second is intrinsically `dispatch` once the prelude classifier learns to flag `composed` bodies that call user-overridable methods.

4. **Catalogue diff tooling.** Tracked in the `rigor-builtin-import` skill's "Future Optimisation Surface" section. A `make catalog-diff` between two extractor runs would catch CRuby submodule bumps shifting symbol names; today the only signal is per-method test breakage.

## Reading Order for a Returning Implementer

1. `git log --oneline master ^v0.0.3` — every v0.0.4 slice in commit order.
2. `CHANGELOG.md` `[0.0.4]` section — user-visible summary.
3. [`docs/MILESTONES.md`](MILESTONES.md) — what v0.0.5 commits to and what stays out.
4. [`docs/adr/3-type-representation.md`](adr/3-type-representation.md) Working Decisions — OQ1 / OQ2 / OQ3 outcomes (with the v0.0.4 status notes).
5. [`docs/adr/5-robustness-principle.md`](adr/5-robustness-principle.md) — the asymmetric authorship rule that drives every catalog and refinement decision.
6. [`.codex/skills/rigor-builtin-import/SKILL.md`](../.codex/skills/rigor-builtin-import/SKILL.md) — the procedure for importing a new built-in class. Stage 0 documents `tool/scaffold_builtin_catalog.rb`, the v0.0.4 automation that drives the mechanical 70 % of an import.

After those, the v0.0.4 implementation surface is locatable from grep over `lib/rigor/type/`, `lib/rigor/inference/`, `lib/rigor/inference/method_dispatcher/`, and `data/builtins/ruby_core/`.
