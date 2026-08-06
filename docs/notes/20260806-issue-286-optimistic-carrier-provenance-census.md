# `if` / `unless` elision — provenance census of the optimistic carrier, and a two-directional A/B (2026-08-06)

Status: measurement for [issue #286](https://github.com/rigortype/rigor/issues/286), taken against `master`
at 9dc901a9 (Rigor 0.3.x line). Non-normative; nothing shipped in `lib/` on `master`. Successor to the
[2026-08-05 shape census](20260805-issue-286-if-unless-truthiness-elision-census.md), which classified
verdicts by carrier *shape*; this one classifies them by *provenance*, which is the axis the decision turns
on.

**Headline: 47 of 2,060 verdicts (2.3%) rest on an optimistically nil-free carrier, 30 of them dropping a
written arm — and declining those 47 is diagnostic-identical across all eleven targets, in both
directions.** The shape-based proxy the previous census had to use is wrong in *both* directions: it
over-counts by 99 (genuine proofs it would have declined) and under-counts by 12 (optimistic `Constant`
carriers it could not see, including the one cluster where the elision deletes the branch that actually
runs).

## 1. What this census adds

The prior note established that the `if` / `unless` elision is a third consumer of
`Narrowing.predicate_certainty` and that `docs/internal-spec/inference-engine.md:251` constrains only the
other two. It could not answer whether a given verdict's nil-freeness was *proof* or *optimism*, because
provenance was not recorded — so it split verdicts by carrier shape and flagged the split as a limitation.

Provenance is now recorded directly. `RBS::Definition::Method::TypeDef#overload_annotations` exposes
`%a{implicitly-returns-nil}` **per overload**, and `OverloadSelector.select` returns one of
`method_definition.method_types` verbatim, so the selected overload resolves by object identity. The
judgment is therefore exact where a shape proxy cannot be: `Array#first` is optimistic while
`Array#first(3)` is not, and `String#[]` / `Enumerable#find` are honest because they already spell the miss
as `?`.

The mark is carried on a side channel modelled on [ADR-75](../adr/75-dynamic-provenance.md) /
[ADR-82](../adr/82-dynamic-provenance-wiring.md): recorded on the call node at
`RbsDispatch.translate_return_type` (next to the existing `record_void_recovery` hook), propagated onto the
binding at assignment, and resolved back from a bare local read. No type carrier was touched, and the new
tables are excluded from `Scope#==` / `#hash` exactly as the four existing origin tables are, so the
instrumentation cannot vary a flow decision.

## 2. Method, and the traps cleared

`rigor check --workers 0 --no-baseline --no-cache --no-ci-detect`, cwd = target, `BUNDLE_GEMFILE` pointed
at Rigor's, inside the Flake. Same eleven targets as the prior census.

Three traps were cleared, all of which have fabricated a convincing zero in this repo before:

- `--no-baseline` (a project baseline silences 793 diagnostics in redmine alone) and `--no-cache`
  (pre-#285 the run-result cache key derived nothing from engine source).
- **A four-quadrant positive control, run first.** The classifier had to say "yes" on all three optimistic
  carrier shapes *and* "no" on the proof-shaped members of the same carrier classes before the corpus was
  allowed to say anything:

  | fixture | carrier | required | observed |
  | --- | --- | --- | --- |
  | `MAP[key]` (two value types) | `Union` | optimistic | ✅ |
  | `MONO[key]` (one value type) | **`Constant`** | optimistic | ✅ |
  | `ENV.keys.first` | `Nominal` | optimistic | ✅ |
  | `ENV.keys` | `Nominal` | proof | ✅ |
  | `"abc".upcase` | `Constant` | proof | ✅ |
  | `ENV["HOME"]` | `Union` (`String?`) | declines | ✅ |

  The load-bearing row is the `Nominal` pair: the same carrier class must come out optimistic in one case
  and proof in the other, since the whole decision rests on separating them.
- **Cross-validation against the prior census.** Verdict counts match per target exactly on ten of eleven
  targets (erubi 1, faraday 5, net-ssh 14, kramdown 79, liquid 20, mail 670, textbringer 645, redmine 162,
  mastodon 46, plugins+examples 99). Only Rigor's own `lib` differs — 319 here against 316 — a ~1% drift
  consistent with the prior note's caveat that the census counts *evaluations*, not source sites, and
  method-return inference re-enters bodies a variable number of times.

Two fixture artifacts are worth recording, because both initially read as engine mysteries:

- `Time.now` types as `Dynamic` under `rigor check` (the `time` stdlib RBS is not loaded by default) while
  `rigor type-of` resolves it to `Time`. A control built on `Time` measures nothing.
- `["a", "b"].map { … }` yields a `Tuple`, so `.first` is resolved precisely by `ShapeDispatch` and is
  **correctly** not optimistic — a non-empty tuple genuinely cannot miss. Reaching the annotated overload
  needs a true `Array` nominal (`ENV.keys`).

## 3. Results

47 of 2,060 verdicts (2.3%) rest on optimism; 30 of those drop a written arm.

| carrier | proof | **optimistic** | total |
| --- | ---: | ---: | ---: |
| `Constant` | 1,914 | **12** | 1,926 |
| `Nominal` | 65 | **11** | 76 |
| `Union` | 31 | **24** | 55 |
| `HashShape` | 2 | 0 | 2 |
| `Tuple` | 1 | 0 | 1 |

Per target (verdicts / optimistic / optimistic dropping a written arm): rigor `lib` 319/14/8,
plugins+examples 99/7/6, redmine 162/14/13, textbringer 645/9/2, mail 670/2/0, mastodon 46/1/1, and
erubi / faraday / net-ssh / kramdown / liquid 0 optimistic between them.

### The shape proxy is wrong in both directions

Declining every **non-`Constant`** carrier — the shape-based option the prior note scoped — would touch 134
verdicts. Only 35 of them are actually optimistic. The other **99 are genuine proofs**: `Nominal` carriers
whose class truly excludes `nil` / `false`, plus `Tuple` / `HashShape` carriers sound by inhabitance. And
it would still leave **12 optimistic `Constant` verdicts** making exactly the bet it set out to stop.

Those 12 are not a curiosity. Eight of them are one cluster in redmine
(`lib/redmine/export/pdf/issues_pdf_helper.rb:92-115`):

```ruby
left << nil while left.size < rows          # element type collapses to nil
…
item = left[i]                              # Array#[] -> Constant[nil], optimistic
heights << pdf.get_string_height(35, item ? "#{item.first}:" : "")
```

The verdict is `:falsey`, so the elision drops the **truthy** arm — the branch that runs whenever `left` is
non-empty. This is the mirror image of the `MAP[key]` case and is invisible to a shape gate, because the
carrier is a `Constant`.

The remaining optimistic sites are the lookup-then-guard idiom the prior census described, now confirmed by
provenance rather than by reading: `if link = RECORD_LINK[record.class.name]` (redmine
`application_helper.rb:243`), `HIRAGANA_TABLE[c]` (textbringer `skk_input_method.rb:410`, `:491`), Rigor's
own `handler = HANDLERS[command]` (`cli.rb:91`) and `shape_dispatch.rb:240`/`:247`.

## 4. The two-directional A/B

Declining the elision when — and only when — the predicate carries the optimistic mark, implemented at the
two consumers and deliberately **not** in `falsey_nominal?` / `narrow_falsey` (which `&&=` / `||=` and the
and/or surviving-left edge also read, where widening the falsey fragment would re-admit `nil` into a bound
local and buy `possible nil receiver` firings):

- **Diagnostics: byte-identical on all eleven targets. Zero added, zero removed.**
- **Precision: no regression.** On Rigor's own `lib`, `constant` nodes rise by 3 and `bot (unreachable)`
  falls by 3 — the previously-skipped dead arm now gets typed. On redmine the precision ratio moves
  50.93% → 50.92% (−4 precise nodes out of 43,202).
- **It removes a reproducible false positive on correct code**, unchanged from the prior note's repro:

  ```ruby
  MAP = { a: "x", b: "y" }.freeze
  v = MAP[key]
  n = if v then 1 else "none" end   # master: else arm dropped, n types as 1
  n.upcase                          # master: error: undefined method `upcase' for 1
  ```

A zero diff is not on its own evidence — #152 passed a "zero new diagnostics" gate and shipping it would
still have been wrong, because its damage mode was *deleted fallbacks*, not new firings. The damage mode of
*declining* is lost precision, so precision is what was measured alongside, and it does not regress. The
flag was independently proven live on both a small target (Rigor `lib`: the +3/−3 coverage delta) and a
large one (redmine: the 50.93 → 50.92 delta), so the zero is a measurement rather than an inert build.

## 5. Consequence for the decision

The issue's three options are no longer symmetric.

- **Stop the elision for non-`Constant` carriers** is both over-broad (99 genuine proofs declined for no
  soundness reason) and incomplete (12 optimistic `Constant` verdicts survive, including the redmine
  cluster that deletes a live branch). The measurement retires it.
- **Extend the spec's exclusion to bless the status quo** now has to be argued against a reproducible FP on
  correct code whose fix measures as free.
- **Decline on provenance** targets exactly the 47, is diagnostic-neutral in both directions, and costs
  ≈0.01pp of precision on the largest target.

One correction to the prior note's reading of the precedent: [ADR-78](../adr/78-reflexive-overfold-always-truthy.md)
rejected a provenance tag for *laundering a constant the engine should not have produced* — its words are
that provenance explains a `Dynamic`, it does not justify a constant. The optimistic union is a different
object: it is deliberately produced, is correct for dispatch, and is backed by 25 measured FPs. What is at
stake here is not whether the engine may produce it but whether a **certainty judgment may read it as
proof**. ADR-78 does not foreclose that, and ADR-75's channel is the established shape for it.

## 6. Limitations

- Provenance is carried for the call node and for **local** bindings. Instance variables are not
  propagated, so an `@x = MAP[k]; if @x` site would be undercounted; no predicate in the optimistic set was
  an ivar read, but the corpus was not swept for how many *declined* verdicts are.
- The `implicitly-returns-nil` family is the only optimistic cause modelled. Other places the engine is
  deliberately optimistic (if any) would not be marked.
- 19 of the 47 rows carry no source path (the value-side consumer's scope has a nil `source_path`); they
  duplicate sites the scope-side consumer records with a path, so the ~20 real distinct sites are fewer
  than the 35 raw site keys.
- The instrumentation and the A/B flag live on the branch `optimistic-nil-free-provenance-census-286`,
  which is **not** meant to ship as-is: the census hook and the `RIGOR_286_DECLINE_OPTIMISTIC` env gate are
  measurement scaffolding. The branch is preserved deliberately — the 2026-08-05 census's harness did not
  survive its own commit, and rebuilding it cost most of a session.
