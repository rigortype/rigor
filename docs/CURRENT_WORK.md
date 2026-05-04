# Current Work — Inference Engine Checkpoint

This is a transient bookmark used to break a long implementation thread into reviewable chunks. The **normative** contracts and slice roadmap remain in [`docs/internal-spec/inference-engine.md`](internal-spec/inference-engine.md) and [`docs/adr/4-type-inference-engine.md`](adr/4-type-inference-engine.md). The release-by-release commitment envelope lives in [`docs/MILESTONES.md`](MILESTONES.md). If this file disagrees with any of those, the spec / ADR / milestone binds and this file is out of date.

## Status

**v0.0.6 released 2026-05-05.** The full release summary is in `CHANGELOG.md`'s `[0.0.6] - 2026-05-05` section and the v0.0.6 row of [`docs/MILESTONES.md`](MILESTONES.md).

**v0.0.7 in progress on `master`** — the pre-plugin coverage push. Seven slices since `v0.0.6`:
1. `02f369f` — `key_of[T]` / `value_of[T]` type functions (parser registry + Combinator factories + `lower_snake` head support + nested type-args on class arguments).
2. `1366f9f` — `int_mask[…]` / `int_mask_of[T]` type functions (bitwise-OR closure with cardinality cap; integer-literal arguments now accepted in `[…]` payloads).
3. `5703ca8` — `Constant<Range>` unary precision (`to_a` lift to Tuple; `first`/`last`/`min`/`max`/`count`/`size`/`length` no-arg folds).
4. `6102b7f` — `Rational` / `Complex` literal lift (`Prism::ImaginaryNode` / `Prism::RationalNode` + `Kernel#Rational(...)` / `Kernel#Complex(...)` Kernel-call folding; `foldable_constant_value?` widened to match `Type::Constant::SCALAR_CLASSES`).
5. `6a10ac3` — `~Refined[base, predicate]` narrowing through `Difference[base, refined]` (replaces the conservative "current_type unchanged" fallback).
6. `c85382d` — `T[K]` indexed-access type operator (Combinator factory + parser trailing `[K]` chain + class-name-headed top-level types).
7. `acc83ea` — HashShape projections `keys` / `values` / `count` / `empty?` / `any?` for closed shapes with no optional keys.

(Plus `035057a` — the v0.0.7 scope plan commit and `b50959d` — the mid-batch checkpoint refresh.)

Working state: 1470 RSpec examples / 0 failures, RuboCop 138 files / 0 offenses, `bundle exec exe/rigor check lib` reports 0 diagnostics. No version bump yet — version stays at `0.0.6` until the v0.0.7 surface is locked in.

Slice 4 of the original plan — the `rigor:v1:conforms-to` directive — was deferred because landing it without a real structural-conformance check would just add a no-op directive parser. The check is bigger than v0.0.7 wants; it stays in the deferral list.

Composite payoff:
- `Rational(3, 4)` → `Constant<Rational(3, 4)>`; `r.numerator` folds to `Constant[3]`; `r + Rational(1, 2)` folds to `Constant<Rational(5, 4)>`.
- `Complex(3, 4)` → `Constant<Complex(3, 4)>`; `c.abs` folds to `Constant[5.0]`.
- `(1..3).to_a` folds to `Tuple[Constant[1], Constant[2], Constant[3]]`; `(1..5).count` folds to `Constant[5]`.
- `assert value is ~lowercase-string` narrows `String` to `Difference[String, lowercase-string]`.
- `key_of[Hash[Symbol, Integer]]` parses to `Symbol`; `int_mask[1, 2, 4]` parses to `Constant[0] | … | Constant[7]`; `Hash[Symbol, Integer][Symbol]` parses to `Integer`.
- `{a: 1, b: "two"}.keys` folds to `Tuple[Constant[:a], Constant[:b]]`; `{}.empty?` folds to `Constant[true]`.

## Where the Work Resumes

**v0.0.7 — pre-plugin coverage push.** Theme: close the gap between the type-language / built-in-coverage surface that the v0.0.x specs already commit to and what the analyzer actually implements, so the plugin API designed against this surface in v0.1.0 has a complete substrate to attach to. The release is deliberately **breadth-over-depth**: many small fills, no architecture changes.

The full planned surface — including items deferred from v0.0.6 — lives in [`docs/MILESTONES.md`](MILESTONES.md). The items below are the operational entry points for restarting work, not a re-statement of the milestone.

### Spec ↔ implementation gaps surveyed for v0.0.7

| Surface | Spec reference | Status | Notes |
| --- | --- | --- | --- |
| `key_of[T]` / `value_of[T]` type functions | [`imported-built-in-types.md`](type-specification/imported-built-in-types.md) "Initial type functions" | **missing** | Parser registry entry + projection over `HashShape` / `Tuple` / `Hash[K, V]`. |
| `int_mask[…]` / `int_mask_of[T]` | same | **missing** | Set-of-integers carrier; project a finite Constant<Integer> union into the bitwise closure. |
| `literal-string` / `non-empty-literal-string` | "Initial scalar refinements" table | **missing — needs flow tracking** | "String composed only of literals" is a flow property, not a value-domain refinement. Needs a `Literal` flow flag, which is bigger than the v0.0.7 envelope; deferred unless a tighter scope shows up. |
| `Constant<Range>#to_a`/`first`/`last`/`min`/`max` precision | n/a — implementation gap | catalog-blocked | `to_a` is `:leaf` but the Array result fails `foldable_constant_value?`; `first`/`last`/`min`/`max` are `:block_dependent` because of optional-block forms. Slice them with a Range-specific no-arg allow list and a Tuple-lift for `to_a`. |
| `Constant<Rational>` / `Constant<Complex>` literal lift | v0.0.5 deferral note | **missing** | `Prism::ImaginaryNode` (`1i`) and `Rational(…)` / `Complex(…)` Kernel-call folding. The catalog already exists; the typer side is unwired. |
| `rigor:v1:conforms-to` directive | [`rbs-extended.md`](type-specification/rbs-extended.md) | **deferred — parser-and-checker missing** | RBS::Extended says it's accepted; the implementation skeleton in `rbs_extended.rb` has not yet landed it. Needs parser + a CheckRules rule that reports unsatisfied conformance. |
| Refinement-form `~T` negation in `assert` / `predicate-if-*` | [`rbs-extended.md`](type-specification/rbs-extended.md) "MUST NOT" carrier-side | **deferred** | Difference-against-refinement algebra. Spec marks it deferred; v0.0.7 may attempt a narrow case (Refined-only base; difference produces a `Difference[base, Refined]`). |
| `self`-narrowing in `predicate-if-*` | [`rbs-extended.md`](type-specification/rbs-extended.md) Target grammar | **parsed but no scope edits** | The directive accepts `self` but the engine has no `self`-narrowing surface yet. Out of scope for v0.0.7 unless a small contained slice appears. |
| ObjectSpace catalog import | MILESTONES candidate pool | **out of scope for v0.0.7** | Thin module (5 module functions defined under `Init_GC`); user-visible payoff is small. |
| Pathname / URI delegation rules | MILESTONES stretch surfaces | **out of scope for v0.0.7** | Wider refactor needed — Pathname facade routing through File projections — and URI is a pure-Ruby stdlib gem with no C surface (custom-scaffold path). |
| `String#%` format-string parsing | MILESTONES stretch surfaces | **out of scope for v0.0.7** | Catalog-aware fold over Constant<String> templates with Constant<…> values. Self-contained but lower priority than the type-function gaps. |
| `numeric-string` recogniser via `String#match?(/\A\d+\z/)` | MILESTONES stretch surfaces | **out of scope for v0.0.7** | Pattern-recognition for regex literals in narrowing context. |

### Slice order (operational)

1. **`key_of[T]` / `value_of[T]`** — register parameterised type-function builders, define projection rules, ship parser support, refresh fixtures.
2. **`int_mask[…]` / `int_mask_of[T]`** — same shape, integer set computation.
3. **`Constant<Range>#to_a/first/last/min/max` precision** — Range-specific no-arg allow list in `ConstantFolding`, Array-result lift to Tuple for `to_a`.
4. **`rigor:v1:conforms-to`** — parser entry + CheckRules rule; structural-interface conformance check.
5. **`Constant<Rational>` / `Constant<Complex>` literal lift** — `Prism::ImaginaryNode` typing + Kernel-call folding for the unary forms.
6. **Refinement-form `~T` negation** — narrow attempt (Refined base only); declines outside that envelope.

Each slice is independent enough to ship as its own commit. The release converges on "every spec-listed initial-built-in / refinement / directive that does not require flow tracking is implemented end-to-end".

### Items intentionally deferred past v0.0.7

- **`literal-string` / `non-empty-literal-string`.** Need a flow-tracking infrastructure (Literal flag propagating through `+` / `<<` / interpolation), not a value-domain refinement. Reserved for after the plugin API in v0.1.0 because the plugin surface should be the place flow flags get registered.
- **Predicate-complement narrowing for `Refined[base, predicate]`.** `narrow_not_refinement` covers Difference, IntegerRange, and Intersection (via De Morgan) but punts on `Refined[base, predicate]`. The "negate a predicate" surface needs either a mixed-case carrier (e.g. `mixed-case-string` for `~lowercase-string`) or per-predicate paired-complement registry entries — both are larger architecture decisions than v0.0.7 wants to commit.
- **C-body classifier wider transitive mutator scan.** The pure-`rb_check_frozen`-wrapper detection from v0.0.5 narrows the gap; broader transitive scanning needs careful guards against the `Array#to_a` regression that originally gated the v0.0.5 fix.
- **`Data.define` override-aware initializer dispatch.** Block-body `def initialize(...)` as the canonical sig for `Const.new`. Architecturally a discovery-side change; deferred until the plugin API discussion is closer.
- **Pathname / URI delegation rules.** Wider refactor — Pathname facade routing through File projections — and URI is a pure-Ruby stdlib gem with no C surface (custom-scaffold path).
- **`String#%` format-string parsing** and **`numeric-string` regex-pattern recogniser.** Self-contained but lower-priority than the type-function gaps the v0.0.7 push targets.

### Out of v0.0.x scope (architectural)

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
