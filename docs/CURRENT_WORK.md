# Current Work — Inference Engine Checkpoint

This is a transient bookmark used to break a long implementation thread into reviewable chunks. The **normative** contracts and slice roadmap remain in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md). The release-by-release commitment envelope lives in [`docs/MILESTONES.md`](MILESTONES.md). If this file disagrees with any of those, the spec / ADR / milestone binds and this file is out of date.

## Status

**v0.0.5 released 2026-05-03.** The branch is at a clean shipping state: 1313 RSpec examples / 0 failures, RuboCop 135 files / 0 offenses, `bundle exec exe/rigor check lib` reports 0 diagnostics, `gem build rigortype.gemspec` produces `rigortype-0.0.5.gem` cleanly. `lib/rigor/version.rb`, `Gemfile.lock`, and `CHANGELOG.md`'s `[0.0.5]` heading agree on the release version. `v0.0.5` tag pushed to `origin`; gem published to RubyGems.

The summary of what shipped in v0.0.5 is in `CHANGELOG.md`'s `[0.0.5] - 2026-05-03` section and the v0.0.5 row of [`docs/MILESTONES.md`](MILESTONES.md). Not duplicated here.

**v0.0.6 in progress on `master`.** Fourteen commits since `v0.0.5`:
1. `edfc197` — BlockFolding Phase 1: constant-block predicates and filters (`select` / `filter` / `reject` / `take_while` / `drop_while` / `all?` / `any?` / `none?`).
2. `8035204` — BlockFolding Phase 2: per-position Tuple element-wise re-typing for `:map` / `:collect`.
3. `37512fc` — BlockFolding extension: `find` / `detect` / `find_index` / `index` / `count` short-circuit folds.
4. `6335574` — Per-element block fold for `:filter_map` (drops `Constant[nil]` / `Constant[false]` positions).
5. `6b84a74` — Branch elision for expression-position `if` / `unless` on `Type::Constant` predicates.
6. `05d4c29` — `&&` / `||` short-circuit elision on Constant-shaped left operands.
7. `08a9ab0` — Per-element block fold for `:flat_map` (concatenates Tuple-shaped per-position results).
8. `5b40e2b` — Truthy-block side of `:find` / `:detect` / `:find_index` / `:index` per-position over Tuple receivers.
9. `1c2a733` — Mixed-shape `:flat_map` tightening: `Type::Constant` per-position results contribute single elements.
10. `5b47960` — Empty array literal `[]` resolves to the empty `Tuple[]` carrier.
11. `1c8e760` — IntegerRange-aware ternary fold for `Comparable#between?` / `Comparable#clamp` through `try_fold_ternary`.
12. `0b44f34` — Pathname catalog import + extractor `BeginNode`-bodied-`def` classifier fix (rescue-on-def idiom support).
13. `2c33d6d` — Per-element block fold accepts finite-bound `Constant<Range>` receivers (cardinality-capped at 8).

(Plus `cdbeade`, `d8dab79`, `e6a148c`, and `f3af880` — incremental CURRENT_WORK refreshes.)

Working state: 1396 RSpec examples / 0 failures, RuboCop 138 files / 0 offenses, `bundle exec exe/rigor check lib` reports 0 diagnostics. No version bump yet — version stays at `0.0.5` until the v0.0.6 surface is locked in.

The composite payoff: `[1, 2, 3].filter_map { |n| n.even? ? n.to_s : nil }` now resolves to `Tuple[Constant["2"]]` (Phase 2 element-wise re-typing + per-position `:filter_map` fold + ternary elision composing through three layers); `[1, 2, 3, 4].find { |n| n.even? }` resolves to `Constant[2]`; `int<3, 7>.between?(0, 10)` folds to `Constant[true]`.

## Where the Work Resumes

The next preview is **v0.0.6** (or whichever version captures the next slice — bump deferred until that scope is decided). The full planned surface — including the items deferred from v0.0.5 — lives in [`docs/MILESTONES.md`](MILESTONES.md); the items below are the operational entry points for restarting work, not a re-statement of the milestone.

### Highest-leverage next slices

- **Predicate-complement narrowing.** `narrow_not_refinement` covers Difference, IntegerRange, and Intersection (via De Morgan) but punts on `Refined[base, predicate]`. `~lowercase-string` could in principle narrow to `uppercase-string | mixed-case-string`, but mixed-case strings have no carrier today; landing the predicate-complement requires either a new carrier or per-predicate paired-complement registry entries.
- **Block-shaped fold dispatch — remaining gaps.** Most of the slice family is now closed (Phase 1, Phase 2 + Range, both find-family sides, `:filter_map`, `:flat_map` initial + mixed-shape, if/unless/&&/|| elision, empty-array carrier, IntegerRange ternary fold). The narrower remaining levers:
  - `:flat_map` over `Nominal[Array[T]]` per-position results — the current fold treats those as opaque and declines. A "flatten one level into T" rule for that carrier specifically would catch the `arr.flat_map { |x| x.split(",") }` shape.
  - `IntegerRange` receiver per-element fold — today only `Constant<Range>` participates; an `IntegerRange[a, b]` carrier with finite bounds (e.g. via `1.upto(n)` block-param typing) could iterate the same per-element loop with a slightly larger cap.
  - Range-shaped *arguments* on the 2-arg ternary path — `5.between?(int<0, 10>, int<5, 15>)` could decide via the bounds, but the call shape is unusual and the marginal value low; left explicitly out of scope for v0.0.6.
- **More catalog imports.** Concrete classes still in the queue: Date / DateTime / Rational / Complex / Pathname imports all landed (the latter through the v0.0.6 BeginNode-rescue extractor fix). Remaining stdlib candidates: URI (pure-Ruby stdlib gem, no C surface — needs hand-rolled or custom-scaffold approach per [`docs/MILESTONES.md`](MILESTONES.md)). Module candidates beyond Comparable / Enumerable: Kernel (already in BASE_CLASS_VARS as `rb_mKernel`), ObjectSpace.
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
