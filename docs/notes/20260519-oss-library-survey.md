# 22-library OSS survey — recurring false-positive clusters + landed BigDecimal-coerce fix

**Date.** 2026-05-18 → 2026-05-19. Survey at `e44cfee`; fix landed at
`acc9882` (`OverloadSelector: receiver-affinity pre-sort + Acceptance
ancestor fallback`).

**Scope.** 22 widely-used OSS Ruby gems cloned outside the rigor repo
(at `~/repo/ruby/rigor-survey/`) and analyzed with `rigor check`. Goal:
identify recurring false-positive clusters that don't reproduce in
rigor's own self-check corpus, rank them by user-visible impact, and
land at least one concrete fix end-to-end with regression coverage.

**Outcome.** Three survey rounds (Round 1: 11 general-purpose libs;
Round 2: 11 templating / serialization libs; Round 3: fix landed).
Family 3 (BigDecimal misinference) eliminated entirely across the
corpus — 25 mentions in 7 libraries → 0 — through a 7-file change
(2 lib + 1 new module + 2 spec + CHANGELOG + CURRENT_WORK). Five other
diagnostic clusters remain queued; this note records the survey
methodology and per-library results so a future implementer can pick
the next slice with the same data in hand.

**Companion artifacts.** Per-library raw `rigor check` output and the
clone working tree are kept outside this repo at
`~/repo/ruby/rigor-survey/_reports/<lib>.txt` (not checked in — the
clones are too large and the diagnostics are reproducible from the
recipe in §6 below).

## 1. Per-library summary

| Library            | Files | Wall | Mem      | Err | Warn | Notes                                                |
| ------------------ | ----- | ---- | -------- | --- | ---- | ---------------------------------------------------- |
| `rgl`              | 28    | 1.0s | 296 MB   | 2   | 0    | Mixin methods resolved as `Object`                   |
| `algorithms`       | 14    | 1.5s | 314 MB   | 53  | 11   | Tree containers: nil-narrowing + numeric inference   |
| `faraday`          | 33    | 1.3s | 320 MB   | 18  | 7    | Class-method narrowing + nil-receiver clusters       |
| `rbnacl`           | 37    | 1.2s | 300 MB   | 0   | 1    | Cleanest result of the corpus                        |
| `protobuf` (ruby)  | 24    | 1.1s | 365 MB   | 16  | 0    | `Numeric#to_i` / `Struct.new` dispatch bugs          |
| `parser`           | 56    | 1.4s | 309 MB   | 11  | 5    | `<< for BigDecimal` (Integer→BigDecimal misinfer)    |
| `rubocop-ast`      | 99    | 1.2s | 326 MB   | 4   | 3    | Pattern-DSL helpers seen as `Object`                 |
| `concurrent-ruby`  | 178   | 1.4s | 320 MB   | 12  | 7    | `Promises::Future#fulfill` lost on `nil` narrowing   |
| `kramdown`         | 55    | 1.5s | 327 MB   | 42  | 4    | `el.type` / `el.options` chains on `nil` (10+10+7+6) |
| `mail`             | 111   | 2.5s | 437 MB   | 9   | 20   | `literal predicate is always falsey` ×11 (noise)     |
| `net-ssh`          | 97    | 1.3s | 339 MB   | 28  | 22   | `condition is always falsey` ×10; unused-local       |
| **Totals**         | 732   | —    | —        | 195 | 80   |                                                      |

All runs completed in under 2.5s per library. Memory stayed under 440 MB even
for the largest target (mail, 111 files).

## 2. Stability finding (non-reproducible)

On the very first invocation against `algorithms`, **every file** produced:

> `error: internal analyzer error: NoMethodError: undefined method 'try_static_refinement' for module Rigor::Inference::MethodDispatcher`

A subsequent `--clear-cache` run produced 53 normal diagnostics with no
internal errors. The bug therefore depends on transient warm-cache state from
a prior `rigor check` run in this session. Worth tracking down because:

1. Users will hit it on the first analyzer invocation after a refactor.
2. The message itself is a programming-error (typo / missing definition) — a
   `MethodDispatcher.try_static_refinement` lookup is reachable from some
   code path; either the method is undefined, or it should be defined.

**Action**: grep the codebase for callers of `try_static_refinement`. The
trigger conditions are: cache miss + plugin-driven dispatcher entry. The
[`InternalSpec inference engine doc`](docs/internal-spec/inference-engine.md)
contract should also enumerate this.

## 3. Recurring false-positive / improvement clusters

These appear across multiple libraries — the rank is by total occurrence,
which is roughly proportional to "how much noise users would see in their
own codebases."

### 3a. Numeric-literal misinference as `BigDecimal` *(highest priority)*

| Lib          | Message                                          | Count |
| ------------ | ------------------------------------------------ | ----- |
| `algorithms` | `undefined method 'upto' for BigDecimal`         | 1     |
| `parser`     | `undefined method '<<' for BigDecimal`           | 3     |
| `kramdown`   | `undefined method 'times' for BigDecimal`        | 1     |
| `protobuf`   | `undefined method 'to_i/to_f' for Numeric`       | 12    |

These are not user-written `BigDecimal` arithmetic. Reading the call sites
(e.g., `algorithms/lib/algorithms/sort.rb:70` is `(arr.length - 1).upto(...)`),
the receiver is an `Integer` arithmetic result. The inference seems to widen
`Integer` to `Numeric` then narrow incorrectly to `BigDecimal` (the most
restrictive `Numeric` subtype with no `upto`/`<<` definition).

Likely root cause: `Integer - Integer` returns `Numeric` in some path and the
union projection picks the wrong arm. Verify in `ExpressionTyper` — recent
commit `e44cfee` already refines `__FILE__`/`__LINE__`; arithmetic on
literals deserves the same precision.

### 3b. Mixin-provided methods resolved as `Object` / `Class`

| Lib           | Example                                             |
| ------------- | --------------------------------------------------- |
| `rgl`         | `cycles_with_vertex`, `remove_vertex` on `Object`   |
| `faraday`     | `options_for`, `member_set` on `Class`              |
| `faraday`     | `merge!`, `update`, `find_proxy` on `Object`/`URI`  |
| `rubocop-ast` | `compile_terms`, `union_bind` on `Object`/`Binding` |

Pattern: a module is `include`d (or `extend`ed at the class level) and its
methods are not added to the receiver's method table during dispatch. In
`rgl`, the affected methods come from a mixin pattern where `Mutable#each_vertex`
expects callers to provide both `cycles_with_vertex` and `remove_vertex`. The
ScopeIndexer should be checked against include / extend / prepend resolution.

This is also the symptom users would most often misread as "Rigor doesn't
understand mixins." Worth a focused fix + handbook callout.

### 3c. Nil-narrowing not converging through pattern guards

| Lib              | Cluster                                                       | Count |
| ---------------- | ------------------------------------------------------------- | ----- |
| `kramdown`       | `el.type`/`el.options`/`el.children`/`el.value` on `nil`      | ≥33   |
| `algorithms`     | `node.key`/`.left`/`.right`/`.value` on `nil`                 | ≥45   |
| `net-ssh`        | `call`/`close`/`shutdown` on `nil`                            | ≥12   |
| `concurrent`     | `fulfill`, `executor`, `resolved?` on `nil`                   | ≥5    |

These dominate the absolute error count but many are likely true positives —
tree algorithms genuinely deref `node.left` after only a shallow check. The
problem is they all *look the same* in the output. Two improvements:

1. Group nil-receiver diagnostics under a single roll-up so a user looking
   at `algorithms/lib/containers/splay_tree_map.rb` sees "20 nil-receiver
   errors on `node`" rather than 20 separate lines.
2. Honor the common idiom: `return unless node` / `node or return` /
   `node && node.left` should narrow inside the consequent.

Spot-checking `splay_tree_map.rb:156` (cited in §3c above) shows a deeply
nested method where the guard is many lines above the use — this is the
edge of what flow narrowing can sustain without explicit annotations.

### 3d. `condition is always falsey/truthy` noise

| Lib            | Count |
| -------------- | ----- |
| `net-ssh`      | 10    |
| `faraday`      | 6     |
| `parser`       | 5     |
| `concurrent`   | 5     |
| `kramdown`     | 2     |
| `rubocop-ast`  | 2     |

Many of these are downstream of §3a/§3c — once the receiver type is wrong,
the surrounding `if`/`unless` folds to a constant. Fixing 3a/3c will reduce
this category mechanically. The remaining true positives (dead branches)
are valuable but easy to drown in the false positives.

### 3e. `Mail::Message` `literal predicate is always falsey` ×11

All in `mail/lib/mail/message.rb`. Spot-checking shows these are predicates
like `if @raw_source.blank?` where Rigor has inferred a non-blank shape for
`@raw_source`. The pattern is identical 11 times — probably a single
constructor-side over-narrowing that ripples through every getter.

### 3f. `Struct.new` / `Class.new` dispatch

* `protobuf`: `wrong number of arguments to 'new' on Struct (given 0, expected 1..Infinity)`
* `concurrent-ruby`: `wrong number of arguments to 'new' on Class (given 1/2, expected 0)`

These are likely the `Struct.new(:a, :b)` and `Class.new(SuperClass) { ... }`
forms. Both have well-defined signatures in RBS but Rigor falls back to
`Object#new`. Worth a single dispatcher patch (Struct + Class meta-methods).

### 3g. Instance-variable type-divergence noise

Across `algorithms`, `mail`, `net-ssh`, `parser`, `rbnacl`, `concurrent-ruby`,
`rubocop-ast`, `kramdown` — the pattern:

> `instance variable '@X' on Klass was previously assigned NilClass; this
> write assigns ConcreteType`

This is canonical Ruby: `def initialize; @x = nil; end` then `@x = build!`
later. The diagnostic catches a genuine type shift but, since the pattern is
nearly universal, it produces high-volume low-signal noise. Three options:

1. Suppress when the only prior assignment is `nil` in an `initialize` and
   the type union is exactly `NilClass | ConcreteType`.
2. Promote to a separate diagnostic family with a default `:hint` severity.
3. Keep as-is but document the suppression marker prominently.

## 4. Cross-cutting infrastructure observations

* **All 11 runs print** the same `.rigor.yml:1:1: info: 24 gem(s) in
  Gemfile.lock have no RBS available` — this is the *Rigor repo's* Gemfile,
  not the target's. The check ran from Rigor's cwd. Worth either:
  - Auto-detecting "target outside cwd" and suppressing the cwd-relative
    Gemfile advice, or
  - Emitting target-relative advice instead.
* **Cache-hit observability** — every run reports
  `(source attribution unavailable on cache-hit runs; --no-cache surfaces
  it)`. This is good guidance but appears even when the target was never
  before checked. Consider tightening to "this run had ≥1 cache hits" only.
* **Git-dirty warning** — `warning: Git tree '/Users/megurine/repo/ruby/rigor'
  is dirty` is emitted even when the target path is outside the dirty tree.
  Either silence it for out-of-tree targets, or rebase the check against the
  target's own git root.

## 5. Top-3 actionable improvements (recommended order)

1. **Fix the `Integer`-arithmetic → `BigDecimal` misinference (§3a)** —
   smallest fix, highest noise reduction. Affects ≥4 of 11 libraries.
2. **Resolve mixin/`include` lookups through `ScopeIndexer` (§3b)** —
   medium effort, fixes the most-misunderstood-as-bug category. Reduces
   "Rigor doesn't understand my code" perception.
3. **Track down and either fix or document `try_static_refinement` cold-cache
   crash (§2)** — small fix, high embarrassment cost if a new user hits it.

The §3c nil-narrowing improvements are higher-value but larger scope —
worth their own design pass (likely tied to the
[`control-flow-analysis`](docs/type-specification/control-flow-analysis.md)
spec) rather than rushed into the next release.

## 6. Reproduction

```sh
cd /Users/megurine/repo/ruby/rigor-survey
# clones already in place; to redo:
for d in rgl algorithms faraday rbnacl parser rubocop-ast \
         concurrent-ruby kramdown mail net-ssh; do
  (cd "$d" && git pull --depth=1 -q)
done

# per-library check
cd /Users/megurine/repo/ruby/rigor
nix --extra-experimental-features 'nix-command flakes' develop --command \
  bundle exec exe/rigor check --clear-cache \
    /Users/megurine/repo/ruby/rigor-survey/<name>/lib
```

---

# Round 2: Templating & Serialization Libraries (2026-05-18)

11 additional libraries surveyed (template engines + serialization). Same
methodology as Round 1.

## 7. Per-library summary (Round 2)

| Library         | Files | Wall | Mem      | Err | Warn | Notes                                                       |
| --------------- | ----- | ---- | -------- | --- | ---- | ----------------------------------------------------------- |
| `herb`          | 42    | 1.2s | 388 MB   | 11  | 9    | `Gem::Specification#full_gem_path` missing in RBS           |
| `liquid`        | 64    | 1.0s | 304 MB   | 17  | 7    | `add_filter` on `Class` → mixin-on-Class lookup gap         |
| `pycall`        | 22    | 0.9s | 342 MB   | 2   | 0    | Very clean; `with_index` on `Array[Dynamic[top]]`           |
| `numo-narray`   | 2     | 0.9s | 287 MB   | 8   | 2    | C-ext gem; one .rb file. BigDecimal misinfer recurs         |
| `ox`            | 15    | 0.8s | 311 MB   | 12  | 0    | Comparison operators on `nil`; `Dynamic[top] \| nil`        |
| `oj`            | 11    | 0.8s | 285 MB   | 5   | 0    | `JSON::Ext::Generator::State.from_state` missing in RBS     |
| `jbuilder`      | 14    | 0.9s | 290 MB   | 126 | 2    | **Generator `.rb` ERB templates parsed as Ruby (118/126)**  |
| `slim`          | 27    | 1.0s | 345 MB   | 9   | 8    | Two ivar type-divergence; `read for nil`                    |
| `hamlit`        | 61    | 1.0s | 321 MB   | 18  | 8    | `html_safe for String` (ActiveSupport extn); BigDecimal     |
| `haml`          | 51    | 1.0s | 307 MB   | 15  | 6    | Same as hamlit; `merge_attributes!` mixin-on-Object         |
| `erubi`         | 3     | 0.8s | 285 MB   | 3   | 0    | `Erubi#begin`/`#end` ivar nil access                        |
| **Round 2 sub** | 312   | —    | —        | 226 | 42   |                                                             |
| **Combined**    | 1044  | —    | —        | 421 | 122  |                                                             |

## 8. New findings from Round 2

### 8a. Generator ERB templates with `.rb` extension *(new, high-impact)*

`jbuilder/lib/generators/rails/templates/{api_,}controller.rb` are ERB
templates (`<%= namespaced_path %>`) saved with `.rb` extension because
Rails generators expect it. Rigor parses them as Ruby, producing 118 of
the 126 jbuilder errors (`unexpected '<', '>'`, `'@' without identifiers
is not allowed`). The 8 remaining errors are real findings in `jbuilder.rb`.

This pattern is universal to Rails-style gems shipping generators. Two
mitigations:

1. **Default-exclude** `lib/generators/**/templates/**/*.rb` when no
   `.rigor.yml` is present in the target.
2. **Detect** ERB markers (`<%`/`%>`) in source bytes and surface a single
   "skipped: template file" `:info` diagnostic instead of 118 parse errors.

Option 2 is more principled; option 1 is faster to ship.

### 8b. `String#html_safe` not recognized *(new, Rails ecosystem)*

`hamlit` + `haml`: 6 occurrences of `undefined method 'html_safe' for String`.
This is the ActiveSupport core_ext method. Users have the
[`rigor-activesupport-core-ext`](examples/rigor-activesupport-core-ext)
plugin available but it isn't applied by default. Three options:

1. Document the plugin more loudly in the diagnostic ("hint: enable plugin X")
2. Build-time hint when `gem activesupport` is in `Gemfile.lock`
3. Status quo (user-driven opt-in)

Option 2 is the least intrusive — emit a single `:info` per run when an
unmissed-but-recognized gem signals an available plugin.

### 8c. `from_state` / `full_gem_path` / `markup_context=` — RBS coverage gaps

These are individually small but together account for ~10 false positives
across `oj`, `herb`, `liquid`. Each is a known method missing from
`vendored_gem_sigs/` or core RBS. Suitable for `rigor sig-gen` follow-up
in the affected repos, or supplemental RBS in `vendored_gem_sigs/`.

### 8d. Comparison operators on `nil` *(refinement of §3c)*

`ox/lib/ox/element.rb` shows the pattern crisply:

```
argument type mismatch at `<' on Integer: expected Numeric, got Dynamic[top] | nil
```

This is the inverse of §3c — instead of "method on nil," it's "passing
`Dynamic[top] | nil` where `Numeric` is expected." Same root cause (nil
not narrowed before use); different diagnostic family. Worth noting that
the spec's robustness principle should make argument-position
`Dynamic[top]` consistent across both sides of the dispatch.

## 9. Refined cross-cutting view (combined corpus)

After 22 libraries, the **top three diagnostic families ranked by total
occurrences across the corpus** are:

| Rank | Family                                                | Total | Affects N libs |
| ---- | ----------------------------------------------------- | ----- | -------------- |
| 1    | `undefined method X for nil` / `X is undefined on NilClass` | ~140 | 16 of 22 |
| 2    | `condition is always falsey/truthy`                   | ~55   | 13 of 22 |
| 3    | `Integer → Numeric → BigDecimal` misinference         | ~25   | 7 of 22  |
|      | (`upto`, `<<`, `times`, `to_i`, `to_f` on numerics)   |       |          |

Family 3 is the **clearest single bug** — fixing it would mechanically
reduce Family 2 (since incorrect numeric narrowing leads to dead-branch
diagnoses), and is concentrated in `Integer#+ / Integer#-` overload
resolution.

## 10. Self-directed next step

Picking Family 3 (Integer-arithmetic Numeric misinference) as the first
improvement to land. Affected libraries: `algorithms`, `parser`,
`kramdown`, `protobuf`, `numo-narray`, `hamlit`, `haml`. Concrete first
case to drive a fix from:

> `algorithms/lib/algorithms/sort.rb:70:13`
> `(i+1).upto(container.size-1) do |j|`
> `error: undefined method 'upto' for BigDecimal`

Where `i` is the Integer block parameter of an outer `0.upto(...)`.
Root cause hypothesis: `Integer#+(Integer)` overload selection picks the
`Numeric → Numeric` fallback rather than the `(Integer) → Integer` arm,
and the materialized `Numeric` carrier folds to `BigDecimal` (the most
specific subtype with no `upto`).


---

# Round 3: Fix Landed for Family 3 (BigDecimal misinference) (2026-05-19)

## 11. Root cause

Not a `Numeric → Numeric` widen as §3a hypothesised. The actual chain:

1. Rigor's process does NOT `require "bigdecimal"` (the `bigdecimal` gem
   was demoted from default in Ruby 3.4 and isn't in the Gemfile).
2. `Acceptance#accepts_nominal_from_constant` calls
   `Object.const_get("BigDecimal")` → `NameError` → returns `:maybe`
   because "we can't tell." Same in `class_subtype_result`.
3. The `bigdecimal` stdlib RBS reopens `Integer#+` / `-` / `*` etc. with
   `def +: (BigDecimal) -> BigDecimal | ...` at the **front** of the
   overload list (the `| ...` merges the original Integer overloads after).
4. `OverloadSelector` accepts `yes` OR `maybe` as a match. Pass 1 picks
   the FIRST overload that all-accepts.  With BigDecimal first AND its
   acceptance returning `maybe` for any Integer-valued arg, the BigDecimal
   arm wins → return type `BigDecimal`.
5. Downstream `BigDecimal.upto` / `.<<` / `.times` doesn't exist → false
   positive.

Reproduction reduced to: `5 + n` where `n` is `Dynamic[top]`. Direct
`Environment.default` env (no bigdecimal loaded) returns `Integer`.
`Environment.for_project` (loads `DEFAULT_LIBRARIES = […, bigdecimal, …]`)
returns `BigDecimal`. That asymmetry pinned the bug.

## 12. Fix (two-part, landed master @ HEAD)

**(a)** `lib/rigor/inference/acceptance.rb` — when `resolve_class(target)`
fails but `resolve_class(actual)` succeeds, fall back to
`actual.ancestors.map(&:name).include?(target_name)` to give an
authoritative `:yes` / `:no` answer. The constant's value is always
loadable at runtime (the value exists), so `Constant<1>.value.class`
is `Integer` and `Integer.ancestors` does not include `"BigDecimal"` →
relation is `:no`, not `:maybe`. Same fallback added in
`class_subtype_result` for the `Nominal.accepts(Nominal)` axis. The
fully-unresolved (both user-class) case stays `:maybe`.

**(b)** `lib/rigor/inference/method_dispatcher/receiver_affinity.rb` —
new module + new pre-sort at the head of `OverloadSelector.select` that
stable-partitions overloads so arms whose every positional param class
is `self_type.class_name` itself OR one of its proper RBS ancestors come
first. The pre-sort fires whenever the env can answer `class_ordering`
and the receiver carries a class name; not gated on "args contain
untyped" because a misordered `overloads.first` fallback when nothing
matches is equally wrong.

## 13. Survey delta (22-library corpus)

| Library         | Errors before | Errors after | Δ  |
| --------------- | ------------- | ------------ | -- |
| `protobuf`      | 16            | 1            | −15 |
| `parser`        | 11            | 8            | −3 |
| `hamlit`        | 18            | 16           | −2 |
| `haml`          | 15            | 13           | −2 |
| `algorithms`    | 53            | 52           | −1 |
| `kramdown`      | 42            | 41           | −1 |
| `concurrent-ruby` | 12          | 11           | −1 |
| `numo-narray`   | 8             | 8            | 0\* |
| `mail`/`net-ssh`/`others` | (unchanged) | (unchanged) | 0 |
| **Total**       | 421           | 397          | **−24** |

\* `numo-narray`'s remaining 8 errors are different categories now (one
ex-BigDecimal-times error surfaced an `Integer#times` overload-selection
issue: with no block, RBS's `() -> Enumerator` should win, but the
analyzer is still picking the block-bearing arm). Separate bug; queued.

All BigDecimal/Numeric false positives across the corpus reduced from
**25 mentions across 7 libraries to 0**.

## 14. Verification

- `make verify`: 3789 specs (3783 + 6 new), 0 failures, 2 pending
  (pre-existing Ractor-readiness items).
- `bundle exec rubocop`: 601 files, 0 offenses.
- `bundle exec exe/rigor check lib` (self-check): 3 pre-existing
  `condition is always truthy` warnings in `hkt_body_parser.rb` /
  `hkt_registry.rb`. Confirmed unchanged from baseline via
  `git stash && rigor check` — not introduced by this fix.
- `git diff --check`: clean.

## 15. Remaining categories from the survey (not yet addressed)

In priority order, with the largest residual buckets first:

1. **§3c nil-narrowing through pattern guards** — ~140 occurrences across
   16 of 22 libraries. The dominant category by absolute volume; many
   true positives (tree code dereferences `node.left` after only a shallow
   check), but the deeply-nested cases reveal the flow-narrowing horizon
   for `return unless node` / `node && node.x` idioms. Tied to the
   `control-flow-analysis` spec; deserves a dedicated design slice rather
   than a quick fix.
2. **§3b mixin-provided methods resolved as `Object` / `Class`** — `rgl`,
   `faraday`, `liquid`, `rubocop-ast`, `haml`. Symptom users most often
   misread as "Rigor doesn't understand mixins." ScopeIndexer
   include/extend/prepend resolution audit.
3. **§8a Rails-generator `.rb` ERB templates parsed as Ruby** — jbuilder
   accounts for 118 of 126 errors (94%). Default-exclude
   `lib/generators/**/templates/**/*.rb` OR detect ERB markers in source
   bytes. Single-fix high-impact.
4. **§8b `String#html_safe` not recognized** — hamlit + haml. Promote
   `rigor-activesupport-core-ext` plugin in a `:info` diagnostic when
   `activesupport` is in the target's `Gemfile.lock`.
5. **§3d `condition is always falsey/truthy` noise** — now reduced
   mechanically by ~5 cases via the §11–12 fix (downstream of corrected
   numeric narrowing). Remaining cases are mostly genuine dead branches +
   the §3c-tied residue.
6. **§3g instance-variable type-divergence noise** — design-call (suppress
   `nil | T` pattern from `initialize`, or split into `:hint` family).

The §2 cold-cache `try_static_refinement` internal-error bug was not
reproducible after the first invocation and didn't recur during this
slice. Left as a queued investigation item — worth a grep pass for
callers of `try_static_refinement` and an inference-engine spec callout.
