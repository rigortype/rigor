# Current Work — Inference Engine Checkpoint

This is a transient bookmark used to break a long implementation thread into reviewable chunks. The **normative** contracts and slice roadmap remain in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md). The release-by-release commitment envelope lives in [`docs/MILESTONES.md`](MILESTONES.md). If this file disagrees with any of those, the spec / ADR / milestone binds and this file is out of date.

## Status

**v0.0.5 released 2026-05-03.** The branch is at a clean shipping state: 1313 RSpec examples / 0 failures, RuboCop 135 files / 0 offenses, `bundle exec exe/rigor check lib` reports 0 diagnostics, `gem build rigortype.gemspec` produces `rigortype-0.0.5.gem` cleanly. `lib/rigor/version.rb`, `Gemfile.lock`, and `CHANGELOG.md`'s `[0.0.5]` heading agree on the release version. `v0.0.5` tag pushed to `origin`; gem published to RubyGems.

The summary of what shipped in v0.0.5 is in `CHANGELOG.md`'s `[0.0.5] - 2026-05-03` section and the v0.0.5 row of [`docs/MILESTONES.md`](MILESTONES.md). Not duplicated here.

## Where the Work Resumes

The next preview is **v0.0.6** (or whichever version captures the next slice — bump deferred until that scope is decided). The full planned surface — including the items deferred from v0.0.5 — lives in [`docs/MILESTONES.md`](MILESTONES.md); the items below are the operational entry points for restarting work, not a re-statement of the milestone.

### Highest-leverage next slices

- **Predicate-complement narrowing.** `narrow_not_refinement` covers Difference, IntegerRange, and Intersection (via De Morgan) but punts on `Refined[base, predicate]`. `~lowercase-string` could in principle narrow to `uppercase-string | mixed-case-string`, but mixed-case strings have no carrier today; landing the predicate-complement requires either a new carrier or per-predicate paired-complement registry entries.
- **Block-shaped fold dispatch.** Two-arg dispatch landed in v0.0.5 and unlocks `Comparable#between?(min, max)` and the explicit-bounds form of `Comparable#clamp(min, max)`. The remaining gap is block-taking methods: Enumerable's `select { |x| … }`, `inject(seed) { |memo, x| … }`, `min_by { … }`, etc. all need the constant-folding tier to grow a block-parameter path that synthesises the block's body type from the receiver's element type. (Block-parameter *typing* — what each yielded variable binds to — already works for `each_with_index` / `each_with_object` / `inject` / `reduce` / `group_by` / `partition` / `each_slice` / `each_cons` via `IteratorDispatch`; the open work is folding the block's *return* into a precise carrier.) Range operands on the existing 2-arg path are also still held back — `int<0,10>.between?(0, 10)` could fold to `Constant[true]` once `try_fold_ternary` learns IntegerRange semantics.
- **More catalog imports.** Concrete classes still in the queue: Date / DateTime imports landed in v0.0.5; remaining stdlib candidates include URI, Pathname (already partial), Rational, Complex. Module candidates beyond Comparable / Enumerable: Kernel (already in BASE_CLASS_VARS as `rb_mKernel`), ObjectSpace.
- **C-body classifier upgrades.** Track indirect mutator helpers (`str_modifiable`, `ary_resize`, `time_modify`, `set_compare_by_identity`, …) so per-class blocklists shrink. The pure-`rb_check_frozen`-wrapper detection landed in v0.0.5 covers the narrowest case; the next step is a wider transitive scan that does not over-flag legitimate non-mutators like `Array#to_a`.

### Out of v0.0.5 / v0.0.x scope (intentional)

- Caches and the plugin API (ADR-2) are reserved for v0.1.0. See [`docs/MILESTONES.md`](MILESTONES.md).
- New CheckRules rule families beyond the v0.0.3 `always-raises` line. Type-incompatible writes, return-type mismatch, unreachable branches stay deferred until the inference surface they depend on is sturdy.

## Open Engineering Items

Persistent items that have come up across v0.0.x slices and that the next implementer benefits from seeing without re-reading the full thread:

1. **`spec/rigor/source/node_locator_spec.rb:82`** — `String#index` returns `Integer | nil` followed by an unguarded `+ 1`. The `possible-nil-receiver` rule flags it correctly; the spec uses a load-bearing nil-or-throw idiom that is awkward to express. Either add a `# rigor:disable possible-nil-receiver` line or rewrite the spec to guard explicitly. Not a blocker — the analyzer is correct.

2. **C-body classifier indirect mutators.** The catalog extractor's regex does not follow `str_modifiable` / `time_modify` / similar helper indirection; methods like `String#replace`, `Time#localtime`, and `Set#reset` land as `:leaf` even though they mutate. The pure-`rb_check_frozen`-wrapper detection landed in v0.0.5 narrows the gap, but per-class blocklists in `STRING_CATALOG` / `TIME_CATALOG` / `SET_CATALOG` still absorb false positives the narrow regex misses. Long-term: the classifier should track the helpers transitively without over-flagging legitimate non-mutators (the `Array#to_a` regression that gated the v0.0.5 fix).

3. **`numeric.yml` `unknown` entries.** Two methods stay `unknown` after the v0.0.3 extraction:
   - `Numeric#clone` (cfunc `num_clone` aliases to `rb_immutable_obj_clone` in `object.c`, not in the indexed C files).
   - `Integer#ceildiv` (prelude body delegates to user-overridable `#div`, classified as `composed`).
   Adding `references/ruby/object.c` to the Numeric topic's `c_index_paths` resolves the first; the second is intrinsically `dispatch` once the prelude classifier learns to flag `composed` bodies that call user-overridable methods.

## Reading Order for a Returning Implementer

1. `git log --oneline master ^v0.0.3` — every v0.0.4 slice in commit order.
2. `CHANGELOG.md` `[0.0.4]` section — user-visible summary.
3. [`docs/MILESTONES.md`](MILESTONES.md) — what v0.0.5 commits to and what stays out.
4. [`docs/adr/3-type-representation.md`](adr/3-type-representation.md) Working Decisions — OQ1 / OQ2 / OQ3 outcomes (with the v0.0.4 status notes).
5. [`docs/adr/5-robustness-principle.md`](adr/5-robustness-principle.md) — the asymmetric authorship rule that drives every catalog and refinement decision.
6. [`.codex/skills/rigor-builtin-import/SKILL.md`](../.codex/skills/rigor-builtin-import/SKILL.md) — the procedure for importing a new built-in class. Stage 0 documents `tool/scaffold_builtin_catalog.rb`, the v0.0.4 automation that drives the mechanical 70 % of an import.

After those, the v0.0.4 implementation surface is locatable from grep over `lib/rigor/type/`, `lib/rigor/inference/`, `lib/rigor/inference/method_dispatcher/`, and `data/builtins/ruby_core/`.
