# `if` / `unless` truthiness elision — corpus census of what the verdict rests on (2026-08-05)

Status: measurement for [issue #286](https://github.com/rigortype/rigor/issues/286), taken against
`master` at b72665dd (Rigor 0.2.x line). Non-normative; nothing shipped in `lib/`.

**Verdict on the change #286 proposes: do not land it — it is a provable no-op.** The unsound
nominal family it targets (`Object` / `BasicObject` / `Kernel`) fires **0 times** in 41,836 `if` /
`unless` predicates across eleven projects. **But the census found a different family making the same
bet, 125 times, and it produces a reproducible false positive on `master`** — the optimistic nil-free
carrier that `docs/internal-spec/inference-engine.md` names by hand for the `&&` / `||` gate. That is
the finding worth a decision.

## 1. The decision site

One judgment, `Rigor::Inference::Narrowing.predicate_certainty`
(`lib/rigor/inference/narrowing.rb:124`), read by two consumers:

- `StatementEvaluator#live_branch_for_if` / `#live_branch_for_unless`
  (`lib/rigor/inference/statement_evaluator.rb:545` / `:552`) — the scope side. Skips the dead branch
  entirely: it contributes neither a type nor a post-scope, and its body is never evaluated.
- `ExpressionTyper#elide_or_union` (`lib/rigor/inference/expression_typer.rb:621`) — the value side
  (expression-position ternary, and any `if` / `unless` reached through `type_of`).

`predicate_certainty` answers `:truthy` when `narrow_falsey(type)` is `Bot`, and the only nominal that
can produce a non-`Bot` falsey fragment is one whose `class_name` is literally `NilClass` or
`FalseClass` (`Narrowing.falsey_nominal?`, `narrowing.rb:634`).

Reproducing the issue's example on `master`, unchanged:

```
$ rigor type-of repro.rb:3:1        # x = Time.now; y = if x then 1 else "s" end; y
type:    1
```

## 2. Taxonomy — what reaches a verdict

Driven directly over each carrier (probe script, not read off the source), with the conformance column
checked against the Ruby runtime rather than assumed:

| shape | verdict | sound? |
| --- | --- | --- |
| `Constant[nil]`, `Constant[false]` | `:falsey` | sound — a genuine value |
| `Constant[c]`, truthy `c` (incl. `0`, `""`) | `:truthy` | sound — a genuine value |
| `Nominal[NilClass]`, `Nominal[FalseClass]` | `:falsey` | sound |
| `Nominal[C]`, `C` a class `nil` / `false` cannot be (`String`, `Time`, `Integer`, …) | `:truthy` | sound **iff the nominal is honest** — see §5 |
| **`Nominal[Object]`, `Nominal[BasicObject]`, `Nominal[Kernel]`** | **`:truthy`** | **unsound** — `nil.is_a?(Object)` / `false.is_a?(Kernel)` are both true |
| `Nominal[Comparable]`, `Nominal[Enumerable]` | `:truthy` | **sound** — see the correction in §6 |
| `Singleton[C]`, `Tuple[…]`, `HashShape{…}` | `:truthy` | sound by inhabitance |
| `Union` with no falsey member | `:truthy` | inherits each member's status — see §5 |
| `Union` containing `Constant[nil]` / `[false]` | — | correctly declines |
| `Top`, `Dynamic[T]`, `Bot` | — | correctly declines |
| `Refined`, `Difference`, `IntegerRange` | — | correctly declines (both fragments returned unchanged) |

The unsound family is exactly the ancestors of `NilClass` / `FalseClass`: `Object`, `Kernel`,
`BasicObject`. It is not "supertypes" in general — `nil.is_a?(Comparable)` is `false`. A project that
does `class Object; include Foo; end` extends the family by `Foo`; that residue is not measured here.

`RbsTypeTranslator` keeps three plausible entry points out of the family: RBS `untyped` and
`interface` both become `Dynamic`, and `top` / `void` become `Top`. All three decline.

## 3. Method

`rigor check --format json --workers 0 --no-baseline --no-cache --no-ci-detect`, cwd = target,
`BUNDLE_GEMFILE` pointed at Rigor's, inside the Flake. An instrumented build recorded, at both
consumers, the predicate's type, the verdict, whether a *written* arm (as opposed to the implicit
`nil` else) was dropped, and `file:line`.

Both traps from the #152 evaluation were cleared: `--no-baseline` (a project baseline silences 793
diagnostics in redmine alone) and `--no-cache` (the run-result cache key derives nothing from engine
source — [#285](https://github.com/rigortype/rigor/issues/285) — so it would have replayed
pre-instrumentation results).

A third trap is specific to this measurement, and it is the reason the census can be trusted to say
*zero*: **a positive control**. A fixture typing a local as `Nominal[Object]` in condition position
was run through the same harness and the record came back classified `UNSOUND`, so the classifier can
say "yes" before the corpus is allowed to say "no".

## 4. Corpus counts

41,836 `if` / `unless` predicate observations; **2,057 reach a verdict** (1,404 `:truthy`, 653
`:falsey`).

| category | firings | of which drop a *written* arm | distinct sites |
| --- | ---: | ---: | ---: |
| A1 — single `Constant` (a genuine value) | 1,926 | 595 | 603 |
| A2 — single `Nominal[C]`, `C` not `nil`/`false`-admitting | 73 | 37 | 53 |
| A3 — `Tuple` / `HashShape` / `Singleton` | 6 | 5 | 5 |
| **B — `Nominal[Object` / `BasicObject` / `Kernel]`** | **0** | **0** | **0** |
| C — nil-free value `Union` (≥2 members, all truthy) | 52 | 24 | 29 |

Per target (verdicts; `w` = written arm dropped):

| target | A1 constant | A2 nominal | A3 shape | B unsound-nominal | C nil-free union |
| --- | --- | --- | --- | --- | --- |
| rigor `lib` | 285 (210w) | 24 (22w) | 0 | **0** | 7 (5w) |
| rigor plugins + examples | 83 (80w) | 3 (3w) | 0 | **0** | 13 (12w) |
| erubi | 1 (0w) | 0 | 0 | **0** | 0 |
| faraday | 3 (2w) | 2 (2w) | 0 | **0** | 0 |
| net-ssh | 13 (7w) | 1 (0w) | 0 | **0** | 0 |
| kramdown | 73 (17w) | 2 (0w) | 0 | **0** | 4 (0w) |
| liquid | 20 (18w) | 0 | 0 | **0** | 0 |
| mail | 654 (107w) | 2 (2w) | 0 | **0** | 14 (0w) |
| textbringer | 618 (63w) | 16 (3w) | 2 (2w) | **0** | 9 (2w) |
| redmine (`app lib`) | 137 (74w) | 21 (5w) | 3 (2w) | **0** | 1 (1w) |
| mastodon (`app lib`) | 39 (17w) | 2 (0w) | 1 (1w) | **0** | 4 (4w) |

**`Object` appears anywhere in a condition's type exactly once in the whole corpus** —
`Union[Constant[nil] | Nominal[Object]]` at rigor `lib/rigor/analysis/runner.rb:1094`, which declines
because of the `nil` arm. `Kernel` and `BasicObject`: never.

The structural reason is that Rigor's "we don't know" carrier is `Dynamic`, not `Nominal[Object]`:
30,970 of the 41,836 predicates carry a `Dynamic`, and `Dynamic` declines. #286's premise — "an
unannotated parameter or a permissive RBS return frequently gives `Object`" — does not hold for this
engine.

## 5. What the census found instead

Categories A2 and C are the same bet the spec forbids for `&&` / `||`, in the `if` position.
`docs/internal-spec/inference-engine.md` (line 251) records that `RbsDispatch` deliberately does not
honour core RBS's `%a{implicitly-returns-nil}` — `Hash#[]` reads as `V`, `Array#[]` as `Elem`,
`Array#first` as `E` — because pessimising them costs 25 measured false positives on Rigor's own
`lib`. It then draws the consequence: such a value is **"optimistic, not proof"**, and
`flow.always-truthy-condition` and the `&&` / `||` gate MUST NOT conclude truthiness from it. The `if`
/ `unless` elision is a third consumer of the same judgment, and the passage does not name it.

Every one of the 29 distinct category-C sites, sampled exhaustively, is the dynamic-key-lookup-then-
guard idiom:

```ruby
kana = HIRAGANA_TABLE[c]                                    # textbringer skk_input_method.rb:491
if kana then … else … end                                   #   written else arm dropped

if (supported_locale = SUPPORTED_LOCALES[locale.to_sym])    # mastodon languages_helper.rb:255, :272
elsif (regional_locale = REGIONAL_LOCALE_NAMES[…])          #   elsif + else arms dropped
else locale end

icon_name = ALERT_TYPE_TO_ICON_NAME[alert_type]             # redmine alerts_icons_scrubber.rb:49
return unless icon_name                                     #   guard judged never taken

handler = HANDLERS[command]                                 # rigor lib/rigor/cli.rb:91
return send(handler) if handler                             #   unknown-command guard elided

handler = TUPLE_HANDLERS[method_name]                       # rigor shape_dispatch.rb:240, :247
return nil unless handler                                   #   the shape tier's own defer contract
```

Category A2 carries the same shape wherever the nominal is nil-free by optimism rather than by
class: `face = Face[name]; ctx.highlight(…) if face` (textbringer `mode.rb:106`),
`singleton = env.singleton_for_name(candidate); return singleton if singleton` (rigor
`reflection.rb:129`), `hint = suggestion ? … : ""` where `suggestion` is
`SpellChecker#correct(…).first` (rigor `config_audit.rb:73` — `rigor type-of` reports `String`, and
core RBS spells `Array#first` as `%a{implicitly-returns-nil} () -> E`). A2 is genuinely mixed: some of
its 53 sites are honest class-typed values where the elision is correct. Provenance is what separates
them, and [ADR-78](../adr/78-reflexive-overfold-always-truthy.md) already rejected a provenance tag
for this judgment.

### The false positive, demonstrated on master

```ruby
MAP = { a: "x", b: "y" }.freeze

def label_for(key)
  v = MAP[key]                     # "x" | "y" — nil-free by optimism
  n = if v then 1 else "none" end  # else arm dropped: n types as 1
  n.upcase                         # runtime: "NONE" when the key misses
end
```

```
$ rigor check optimistic.rb
optimistic.rb:7:5: error: undefined method `upcase' for 1
1 error(s) in 1 file(s)
```

The program works. This is the same FP mechanism #152 was declined for introducing on the `&&` / `||`
edge — already shipped on the `if` edge, and reachable without any dishonest annotation.

The corpus does **not** currently surface this. Cross-referencing every `flow.always-*` diagnostic in
the corpus (61) against the census record at the same `file:line`: 53 match a verdict and **all 53
rest on a genuine `Constant`**; the remaining 8 have no `if` / `unless` verdict at that line at all
(the rule also fires on loop and operand positions). Zero rest on a nominal or a nil-free union. The
diagnostic rule is Constant-gated (ADR-78 WD1); the *elision* is not. So the harm today is a silently
narrowed type, not a corpus diagnostic — exactly the position #152 was in.

## 6. A correction

#286's body and the [#152 note](20260805-issue-152-and-or-polarity-gate-fp-evaluation.md) (§1 table)
both list `Nominal[Comparable]` among the unsound shapes. It is not: `nil.is_a?(Comparable)` and
`false.is_a?(Comparable)` are both `false`, so `Comparable` is a genuinely non-falsey bound. The
unsound set is `Object`, `BasicObject`, `Kernel` — nothing else in core.

## 7. Recommendation

1. **Do not land the `falsey_nominal?` tightening as scoped.** Zero firings on this corpus means zero
   measurable benefit and zero measurable risk; it would be an untested guard defending an empty set,
   and #286's acceptance criterion ("zero new diagnostics") would be met vacuously. If it is landed
   anyway on soundness-hygiene grounds, put it in `predicate_certainty`, **not** in `falsey_nominal?`
   or `narrow_falsey`: those are also read by `&&=` / `||=` and by the and/or surviving-left edge
   (`statement_evaluator.rb:382`/`:384`/`:1242`, `expression_typer.rb:661`), where widening the falsey
   fragment would re-admit `nil` into a bound local and cost `possible nil receiver` firings — a
   soundness fix paid for in false positives, which is the wrong trade here.
2. **Reframe the issue around what actually fires.** The open question is not `Object`; it is whether
   the `if` / `unless` elision may rest on an optimistic nil-free carrier at all. Two coherent
   answers, both ADR-shaped rather than diff-shaped:
   - extend the spec's exclusion to name this path, and state deliberately why the bet is acceptable
     here (the honest version of the status quo); or
   - stop the elision for non-`Constant` carriers, which is a much larger behaviour change — 131 of
     the 2,057 verdicts, 66 of them dropping a written arm — and would need its own FP evaluation in
     both directions, because *keeping* a dead arm alive also re-admits types into unions.
3. Either way the spec passage should stop being silent about this consumer; today it constrains two
   of the three readers of one judgment.

## 8. Limitations

- The category-C / A2 split is by **shape**, not provenance, because provenance is not recorded. The
  29 category-C sites were each read in source and all 29 are lookup-then-guard; the 53 A2 sites were
  sampled, not exhausted.
- The census counts *evaluations*, not source sites: the same `if` is evaluated more than once
  (method-return inference re-enters bodies), which is why firings exceed distinct sites. Distinct-site
  counts are the conservative figure.
- A project that includes a module into `Object` (or into `NilClass` / `FalseClass`) extends the
  unsound nominal family beyond the three core names. Rails does this; no such firing appeared in
  mastodon or redmine, but the classifier only knew the three core names.
- `plugins/*/lib examples/*/lib` was run as one target, matching `make check-plugins`.
