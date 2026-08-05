# `&&` / `||` value-polarity gate: FP-risk evaluation (2026-08-05)

Status: evaluation for [issue #152](https://github.com/rigortype/rigor/issues/152). Non-normative.
**Verdict: do not widen `constant_value_polarity` to a full probe.** Nothing shipped in `lib/`.

The issue queued "extend `ExpressionTyper#constant_value_polarity` beyond `Constant`" as a real
behaviour change needing its own FP evaluation. This note is that evaluation: what the gate does
today, what a full probe would newly decide, whether a second `&&`/`||` typer would have to move in
step, and what a corpus diff measures. The corpus diff came back at **zero new diagnostics**, and
the verdict is still *do not ship* — the reasoning for that gap is the substance of the note.

## 1. What the gate does today, and what changes

`constant_value_polarity` (`lib/rigor/inference/expression_typer.rb`) answers `:truthy` / `:falsey`
only for a `Type::Constant`, and `type_of_and_or` uses the answer to return one operand's type
instead of the union of both. A "full probe" is one line — delegate to the judgment
`Narrowing.predicate_certainty` that every *other* certainty site already reads:

```ruby
def constant_value_polarity(type)
  Narrowing.predicate_certainty(type)   # was: Constant-only
end
```

### The delta is much narrower than it looks

Of the four (node kind × polarity) combinations, **two are algebraically inert** — the short-circuit
and the union fallback already produce the same type, because `union(Bot, right) == right`:

| node | polarity | short-circuit result | union fallback | effect |
| --- | --- | --- | --- | --- |
| `a && b` | `:truthy` | `type_of(b)` | `union(narrow_falsey(a)=Bot, b)` | **none** |
| `a \|\| b` | `:falsey` | `type_of(b)` | `union(narrow_truthy(a)=Bot, b)` | **none** |
| `a && b` | `:falsey` | `type_of(a)` | `union(a, b)` | drops `b` |
| `a \|\| b` | `:truthy` | `type_of(a)` | `union(a, b)` | drops `b` |

So widening the gate has exactly one observable consequence: for a left operand judged provably
truthy, `a || b` **discards the author's fallback `b`**; symmetrically `a && b` discards `b` for a
provably falsey `a`. There is no third effect, and no branch is "narrowed" in any other sense.

### Taxonomy of newly-decidable shapes

Measured by driving `Narrowing.narrow_truthy` / `narrow_falsey` / `predicate_certainty` directly
over each carrier (probe script, not reasoning from the source):

| type shape | today | full probe | sound, or a guess? |
| --- | --- | --- | --- |
| `Constant[nil]`, `Constant[false]` | `:falsey` | `:falsey` | unchanged |
| `Constant[c]` (truthy `c`, incl. `0`, `""`) | `:truthy` | `:truthy` | unchanged |
| `Nominal[NilClass]`, `Nominal[FalseClass]` | — | **`:falsey`** | **sound** |
| `Nominal[String]`, `[Integer]`, `[Array[..]]`, any non-falsey class | — | **`:truthy`** | **a guess** — see §2 |
| `Nominal[Object]`, `Nominal[BasicObject]`, `Nominal[Kernel]` | — | **`:truthy`** | **unsound** — `nil.is_a?(Object)` is `true`; `falsey_nominal?` matches on the exact class name only, so a supertype that genuinely admits `nil` is judged truthy |
| `Singleton[C]`, `Tuple[..]`, `HashShape{..}` | — | **`:truthy`** | sound by inhabitance |
| `Union` with no falsey member (`String \| Integer`, `1 \| 2`) | — | **`:truthy`** | **a guess** — inherits each member's status |
| `Union[String, nil]`, `Union[true, false]` | — | — | correctly declines |
| `Top`, `Dynamic[T]`, any union containing them | — | — | correctly declines |
| `Bot` | — | — | correctly declines (dead code is not a certainty claim) |

The sound additions (`NilClass` / `FalseClass` / shape carriers) are the ones that **cannot pay**:
they only reach the `a && b` `:falsey` row, and the corpus produced **zero** falsey firings (§3).
Everything with a measurable effect sits in the "a guess" rows.

## 2. Why "provably truthy `Nominal`" is a guess here, specifically

This is not a general claim about nominal types. It is a claim about *Rigor's* nominals, and the
type spec already states it. [`docs/internal-spec/inference-engine.md`](../internal-spec/inference-engine.md)
records that `RbsDispatch` deliberately does **not** honour core RBS's `%a{implicitly-returns-nil}`:
`Hash#[]` reads as `V`, `Array#[]` as `Elem`, nil-free, because pessimising them costs 25 measured
false positives on Rigor's own `lib` (`Hash.new(0)` / `default_proc` receivers). The same document
draws the consequence explicitly:

> A value union from a non-static-key `[]` is consequently **optimistic, not proof** […]
> `flow.always-truthy-condition` and the `&&`/`||` `constant_value_polarity` gate it shares MUST NOT
> conclude truthiness from such a union. Today the gate is Constant-only, so it cannot; **any
> widening of it (issue #152) MUST preserve this exclusion**, or `MAP[key] || key` would judge the
> left operand provably truthy and discard the author's fallback.

That is a normative MUST, and it is aimed at this issue by number. The full probe cannot honour it:
the offending value carries no provenance distinguishing "nil-free because the class genuinely
excludes nil" from "nil-free because we chose optimism at the dispatch tier". They are the same
`Nominal` / `Union`. The exclusion is therefore **not expressible** as a filter inside a full
probe — it would need a provenance tag, which [ADR-78](../adr/78-reflexive-overfold-always-truthy.md)
already considered and rejected for this exact judgment ("provenance explains a `Dynamic`, it does
not justify a constant").

ADR-78 WD1 states the criterion the widening would break: provable truthiness may rest only on a
value that genuinely holds at runtime, never on a fold whose soundness is conditional on a narrower
form than the actual expression. An optimistic nil-free read is precisely that shape.

**The corpus confirmed this is not theoretical.** Of the 13 distinct sites where the widened gate
changes a result (§3), the `MAP[key] || key` shape the spec names verbatim appears in four projects,
including Rigor's own `lib`:

- `lib/rigor/inference/parameter_inference_collector.rb:355` — `(index[receiver] || scope).type_of(receiver)`
- `lib/rigor/analysis/dependency_source_inference/gem_resolver.rb:52` — `Gem.loaded_specs[name] || begin … end`
- kramdown `lib/kramdown/utils/html.rb:70` — `ESCAPE_MAP[m] || m`
- textbringer `lib/textbringer/input_methods/hangul_input_method.rb:68` — `COMPATIBILITY_JAMO_TO_FINAL[jamo] || jamo`
- redmine `app/helpers/application_helper.rb:258` — `ATTACHMENT_CONTAINER_LINK[…] || RECORD_LINK[…]`

In every one the author wrote the fallback *because the lookup can miss*. The widening deletes
exactly the branch the author added as the guard.

## 3. The second `&&`/`||` typer — and what it does to the measurement

**Yes, a second polarity path exists**, and it is the more important finding.

- `ExpressionTyper#type_of_and_or` — value side, carries the `constant_value_polarity` gate.
- `StatementEvaluator#eval_and_or` — scope side, **has no polarity gate at all**. It always returns
  `union(skipped_type, right_type)`, where `skipped_type` is `narrow_falsey(left)` / `narrow_truthy(left)`.
  Its only elision is the unrelated ADR-24 WD6 terminating-branch case (`a or raise`).

On master the two agree, because the union fallback and the Constant short-circuit coincide for the
two inert rows and `Constant` left types make the other two rows agree too. **The widening makes
them diverge**, and that is directly observable:

```ruby
COUNTS = { a: 1, b: 2 }.freeze
label = COUNTS[key] || "none"    # write node
label                            # bound local
```

| | write node (`ExpressionTyper`) | bound local (`StatementEvaluator`) |
| --- | --- | --- |
| master | `"none" \| 1 \| 2` | `"none" \| 1 \| 2` |
| widened | **`1 \| 2`** | `"none" \| 1 \| 2` |

This reproduces the recorded "two parallel `||`/`&&` typers" bug class: the same logic implemented
twice and drifting. Widening one side without the other manufactures a fresh instance of it, in
which `rigor type-of` / LSP hover would report a type the analysis itself does not use.

**This is also why the corpus diff is weak evidence.** Because the scope side re-derives the binding,
the widened value-side answer is largely *shadowed* for the surfaces that produce diagnostics:

- local bindings — shadowed (table above);
- inferred method return types — shadowed (a tail-position `CODES[key] || "none"` infers
  `"none" | 1 | 2` both before and after).

So "zero new diagnostics" substantially measures the shadowing, not the safety of the judgment. Any
future work that unifies the two typers onto one owner — which is the correct end state, and what the
Phase 3 re-review recommends — would remove the shadow and expose the full FP surface at once.

## 4. Corpus measurement

Method: `rigor check --format json --workers 0 --no-baseline --no-cache`, cwd = target,
`BUNDLE_GEMFILE` pointed at Rigor's, inside the Flake. Diagnostics compared as
`(path, line, column, rule, message, severity)` multisets.

Two harness traps had to be cleared first, and both silently produced a clean-looking zero:

- **`.rigor-baseline.yml`** — redmine/mastodon/textbringer each carry one; the first run silenced
  793 diagnostics in redmine alone. `--no-baseline` is mandatory for this kind of diff.
- **the run-diagnostics cache** — its key (`Analysis::RunCacheKey#descriptor`) mixes in
  `Rigor::VERSION`, the descriptor schema and the path set, but **nothing derived from the engine's
  own source**. An unbumped edit to `lib/` is invisible to it, so the AFTER run replays the BEFORE
  run's diagnostics verbatim. `--no-cache` (or `--clear-cache`) is mandatory. This is worth knowing
  for every future before/after engine measurement.

| target | paths | before | after | new | gone |
| --- | --- | ---: | ---: | ---: | ---: |
| rigor `lib` | `lib` | 1 | 1 | 0 | 0 |
| rigor plugins + examples | `plugins/*/lib examples/*/lib` | 1 | 1 | 0 | 0 |
| erubi | `lib` | 3 | 3 | 0 | 0 |
| faraday | `lib` | 7 | 7 | 0 | 0 |
| net-ssh | `lib` | 24 | 24 | 0 | 0 |
| kramdown | `lib` | 68 | 68 | 0 | 0 |
| liquid | `lib` | 5 | 5 | 0 | 0 |
| mail | `lib` | 26 | 26 | 0 | 0 |
| textbringer | `lib` | 188 | 188 | 0 | 0 |
| redmine | `app lib` | 797 | 797 | 0 | 0 |
| mastodon | `app lib` | 2351 | 2351 | 0 | 0 |
| **total** | | **3471** | **3471** | **0** | **0** |

The change is live, not dead code: an instrumented build counted **70 firings** where the widened
gate answers and the Constant-only gate declines — all `:truthy`, none `:falsey`. **59 of them land
on the two effective rows** (i.e. actually discard an operand); the other 11 are `&&`-with-truthy and
are algebraically inert. The 59 reduce to 13 distinct source sites, every one of which drops a
fallback the author wrote:

```
kramdown      ESCAPE_MAP[m] || m
textbringer   COMPATIBILITY_JAMO_TO_FINAL[jamo] || jamo
textbringer   find_first_path(patterns) or raise EditorError, "Test target not found"   (×2 sites)
redmine       clear_password || ""
redmine       ATTACHMENT_CONTAINER_LINK[…] || RECORD_LINK[…]
redmine       m[2] or 1
rigor-lib     index[receiver] || scope
rigor-lib     Gem.loaded_specs[name] || begin … end
rigor-lib     node.lefts || []   /   node.rights || []
rigor-plugins params.parameters.requireds || []
rigor-plugins dq || sq
```

`find_first_path(patterns) or raise …` is the sharpest illustration: the widening judges the left
operand provably truthy at the precise site where the author's `or raise` documents that it is not.

## 5. Verdict

**Do not ship.** The landing rule for this evaluation was "zero new diagnostics anywhere", and that
bar is met — but it is a necessary condition, not a sufficient one, and three findings override it:

1. **It contradicts a binding normative MUST.** `docs/internal-spec/inference-engine.md` requires any
   widening of this gate to preserve the optimistic-nil-free-read exclusion, naming issue #152 and
   the `MAP[key] || key` counter-example. A full probe cannot preserve it — the excluded shape and
   the admitted shape are the same carrier with no distinguishing provenance. Landing would mean
   *amending the spec*, which is an ADR-level decision about whether Rigor's nil-free reads are proof
   or optimism. That decision cannot be made inside an FP evaluation, and it reopens ADR-78 WD1 and
   the 25-FP `implicitly-returns-nil` measurement that set the current policy.
2. **The zero is partly an artifact of the second typer.** `StatementEvaluator#eval_and_or` re-derives
   bindings and return types without a polarity gate, shadowing the widened answer on exactly the
   surfaces that emit diagnostics. The measurement cannot see most of the risk it was meant to price,
   and unifying the two typers later would expose it all at once.
3. **The effect is anti-precision, not pro-precision.** The issue's premise is that widening
   "improves `&&`/`||` narrowing precision". The algebra in §1 shows the only observable effect is
   *discarding the author's fallback operand*. Where the left operand is genuinely non-nil that is a
   real gain (`node.lefts || []`); where it is optimistically non-nil it deletes the guard. Rigor
   cannot tell the two apart, and under "false positives outrank worst-case static reading" the tie
   goes to keeping the union.

The sound-by-construction subset (`Nominal[NilClass]` / `[FalseClass]` / shape carriers) is safe but
worthless: it only reaches the `a && b` `:falsey` row, which fired **zero** times across 3471
diagnostics and 11 projects. Shipping it would add a behaviour change with no measured benefit.

### Recommended disposition

- Close #152 as **evaluated, declined**, citing this note. Not "deferred pending demand" — the
  evaluation it was waiting for has been done, and the answer is no on type-model grounds that do not
  depend on demand.
- The Constant-only gate should be documented as **deliberate**, not as an unfinished convergence.
  It is the one certainty site whose conservatism is load-bearing.

### Two findings worth their own issues

- **The `if` / `unless` value path already makes the bet this issue was told not to make.**
  `constant_predicate_polarity` delegates to `Narrowing.predicate_certainty` with no Constant
  restriction, so on master `x = Time.now; if x then 1 else "s" end` already types `1` — the else
  branch is elided on a nil-free `Nominal`. `Nominal[Object]` / `[BasicObject]` reach that path too,
  where the judgment is outright unsound (`nil.is_a?(Object)`). So the asymmetry #152 wanted to
  remove is real, but the FP-averse resolution points the *other* way — toward constraining the
  `if` path — and ADR-78's precedent is to fix such things at the source rather than at the consumer.
  Worth an issue; out of scope here, since narrowing that path is a behaviour change of its own.
- **The run-diagnostics cache key ignores the engine's own source.** Any before/after engine
  measurement that forgets `--no-cache` silently reports "no change". Worth either a documented
  warning for contributors or a source-digest slot in the key.

## Reproduction

The experimental patch is three lines; it was measured and reverted, and nothing from it is in the
tree. To reproduce:

```ruby
# lib/rigor/inference/expression_typer.rb
def constant_value_polarity(type)
  Narrowing.predicate_certainty(type)
end
```

then diff `rigor check --format json --workers 0 --no-baseline --no-cache` over the §4 targets.
