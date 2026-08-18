# `effect.discarded-pure-result` (#390) fires 14 times on the corpus, and all 14 are wrong

Status: measurement note, no design commitments. The harness is the branch
[`measure/discarded-pure-result`](https://github.com/rigortype/rigor/tree/measure/discarded-pure-result)
(commit `c6d72702`, deliberately unmerged); re-run it by checking that branch out.

Issue #390 proposes `effect.discarded-pure-result`: a call statement whose result is unused, whose
callee's proven summary is exhaustive and inside the read-shaped set (`global.read`, `nondet.*`,
`io.fs.read`), and whose callee is total — Ruby's non-bang footgun (`str.strip`, `arr.sort`,
`hash.merge(x: 1)`, `list.map { … }` used as `each`). It ships `:off` pending a corpus false-positive
gate. `docs/CURRENT_WORK.md` asked for the firings to be counted **before** the rule is written. They
are counted here, and the answer is **14 firings across three projects, every one a false positive,
and no instance anywhere in the corpus of the footgun the rule is named for**.

Two independent findings, either of which is disqualifying on its own:

1. **The acceptance fixture cannot pass under either gate the issue names** (§ 1). This is a desk
   check against the catalogue files and needed no corpus run.
2. **The rule's reachable domain is 43 sites in 7,151, and the 14 that clear the gate are all
   iteration-for-side-effect** (§ 2, § 3).

## 1. The totality gate does not exist in usable form

#390 gates the raise-as-validation idiom (`hash.fetch(:k)`, `Integer(x)`, `JSON.parse(x)` discarded on
purpose) on "the catalogue's `raises` facet / the constant-folding totality criterion". Neither works,
and they fail in opposite directions.

| named acceptance case | wanted | `raises` facet | `FOLDABLE_PURITIES` |
| --- | --- | --- | --- |
| `s.strip` | fires | `raises: false` ✅ | `leaf` ✅ |
| `xs.map { \|x\| x * 2 }` | fires | `raises: false` ✅ | `block_dependent` ❌ |
| `arr.sort` | fires | `raises: false` ✅ | `mutates_self` ❌ |
| `h.fetch(:k)` | silent | `raises: false` ❌ | `block_dependent` ✅ |
| `Integer(x)` | silent | not catalogued | not catalogued |

**Under the `raises` facet the named negative fires; under the folding criterion two of the three named
positives do not.** No composition of the two passes the fixture, because on this evidence the two
gates disagree with the intent in opposite directions.

Each cell has a mechanical cause worth recording separately:

- `Hash#fetch` reads `raises: false` because the extractor's `RAISE_RE`
  ([`tool/extract_builtin_catalog.rb:835`](../../tool/extract_builtin_catalog.rb)) matches `rb_raise\w*`
  and four curated helpers, while `rb_hash_fetch_m` raises through **`rb_key_err_raise`**
  (`references/ruby/hash.c:2156`). `\brb_raise` cannot match inside `rb_key_err_raise`, so the token is
  invisible. The same hole swallows `rb_exc_raise` (103 call sites), `rb_sys_fail` (184),
  `rb_name_err_raise` (30 — note the curated list has the near-miss sibling `rb_name_error`),
  `rb_syserr_fail`, `rb_eof_error`, `rb_enc_raise` and `rb_memerror`.
- `Array#sort` reads `mutates_self` because `rb_ary_sort` is
  `ary = rb_ary_dup(ary); rb_ary_sort_bang(ary);` — the extractor's "first argument is a formal
  parameter" mutator heuristic fires on a formal parameter that was **rebound to the dup one line
  earlier**. This one is a fixable extractor bug rather than an inherent limit.
- `Kernel#Integer` has neither facet: `Kernel` is not among the 21 topic files under
  `data/builtins/ruby_core/`.

Scale of the `raises` recall hole, measured over the 1,255 catalogued methods with a locatable C body:

| | all rows | foldable-purity rows |
| --- | --- | --- |
| `raises: false` yet a **direct** raise helper in the body | 35 | 31 |
| `raises: false` yet an argument-coercion / arity / frozen guard | 102 | 46 |

In fairness to the facet, this hole is mostly harmless *for this rule*: 30 of the 31 foldable direct
raisers are `IO` / `File` / `ARGF` / `Date` methods that the effect gate already excludes, and the
guard misses are `rb_num2*` TypeErrors on bad arguments, not the validation idiom. The disqualifying
cell is the single one the issue names — `Hash#fetch`.

## 2. The funnel: 7,151 discarded-position sites, 14 firings

The probe emits one row per call in discarded-statement position, carrying what the effect scan itself
decided there — the labels the call contributed, the taints it raised, and the typer's `CallRecord`.
Rows join offline against the builtin catalogue's `purity` / `raises` facets. Subjects and method match
the [B2.2 note](20260818-b22-ivar-reset-headroom.md): redmine `a12198ea0`, mastodon `163f96cee`, `rigor
lib` is this repo on the probe branch at `c6d72702`; scratch configs carry `effects: {}`, `parallel: {workers: 0}`, a scratch
`cache.path` and no baseline.

| gate | `rigor lib` | redmine | mastodon | total |
| --- | --- | --- | --- | --- |
| G0 call in discarded-statement position | 1,919 | 2,824 | 2,408 | **7,151** |
| G1 + the site is exhaustive (no taint) | 740 | 708 | 882 | 2,330 |
| G2 + proven labels are read-shaped | 544 | 497 | 768 | 1,809 |
| G3 + receiver is typed and non-`Dynamic` | 511 | 409 | 623 | 1,543 |
| G4 + callee is a catalogued core method | 30 | 6 | 7 | **43** |
| G5   … `raises` facet false (gate A) | 29 | 3 | 7 | 39 |
| G6   … purity foldable (gate B) | 12 | 1 | 1 | 14 |
| G7   … both | 12 | 1 | 1 | **14** |

**G3 → G4 is where the rule dies: 1,543 typed discarded-position sites, 43 of them on a callee the rule
can gate.** This is not an artifact of the measurement. Both totality gates #390 names are catalogue
facets, and the design states the reason — "Rigor tracks no throw set". A *project* method therefore
has no totality evidence of any kind, so it can never clear the gate however well typed it is. The
rule's reachable domain is core-catalogued callees, and that is 2.8 % of the typed sites.

## 3. Every firing is iteration for side effect

All 14, hand-adjudicated:

| callee | n | sites |
| --- | --- | --- |
| `Hash#each_value` | 9 | `plugin_facts.rb:314,316,318,320,323` · `incremental.rb:33,57` · `file_collection.rb:105` · `registry.rb:181` |
| `Hash#each` | 3 | `envelope_check.rb:106` · `scope_indexer.rb:85` · mastodon `multibase.rb:38` |
| `Set#each` | 1 | `scope_indexer.rb:456` |
| `Hash#each_key` | 1 | redmine `user_preference.rb:171` |

**Zero true positives, 14 false positives.** Not one is a non-bang call whose result was meant to be
kept. Five distinct mechanisms produce them, and each is a hole the rule's own gates cannot see:

- **`mutate.local` is tolerated by design, and accumulate-into-a-local is the commonest discarded
  iteration.** `envelope_check.rb:106` is `envelopes.each { |k, e| collect(findings, …) }`, appending to
  a frame-owned local. `Summary::TRIVIAL_BOUND` makes frame-local mutation read as pure, which is right
  for an envelope and exactly wrong here: for the *caller* of `xs.each { acc << x }`, the frame-local
  mutation is the entire point.
- **A block that reassigns an enclosing local raises no label at all.** `scope_indexer.rb:85` is
  `program_globals.each { |name, type| seeded_scope = seeded_scope.with_global(name, type) }`. A local
  write is not an effect in any lane.
- **`&:sym` bypasses containment for mutators.** `file_collection.rb:105` is
  `includes.each_value(&:uniq!)`. `visit_block_argument` returns early on a `SymbolNode`, and there is
  no body to walk, so the site reads ∅ + exhaustive — while the *same work* spelled
  `each_value { |v| v.uniq! }` taints `unknown-ownership` and is correctly excluded. Verified as a
  matched pair on a fixture; the two spellings get opposite verdicts.
- **`freeze` is not modelled as an effect anywhere.** The nine `each_value(&:freeze)` sites are clean in
  both spellings — neither the effects catalogue nor `MutationClassifier` treats freezing as a
  mutation, though it is plainly observable to the caller.
- **A block that exits non-locally has no result to discard.** mastodon's `multibase.rb:38` is
  `MULTICODEC_PREFIXES.each { |tag, prefix| return […] if … }`. The loop *is* the control flow. The
  design never considers this shape.

## 4. The footgun is not in the corpus

The adjudication above is about what the gate admits. The converse question — is the rule gating away
real footguns? — was asked directly, by scanning every census row for a non-bang footgun selector
(`strip`, `sort`, `map`, `merge`, `uniq`, `compact`, `gsub`, `select`, … 33 selectors) in discarded
position. Across all 7,151 rows there are **27 such calls, and exactly 2 survive to a typed,
exhaustive, unlabelled site** — both in `rigor lib`, and both correct code:

- `local_ownership.rb:40` — `collect(body, assignments, escaped)` is the module's own recursive
  collector, not `Array#collect`. It mutates its arguments.
- `local_ownership.rb:41` — `escaped.merge(trailing_reads(body))`. **`Set#merge` is destructive.** The
  design's example list names `hash.merge(x: 1)` as a footgun; the same selector on `Set` is a mutator,
  and so are `Array#concat` and `Set#subtract`. "Non-bang means pure" is not a property of the selector
  name.

`rigor lib` is the best-typed subject in the corpus — 511 of its 1,919 discarded-position sites clear
G3, against redmine's 409 of 2,824 — and it produced zero true positives. A "better types would fix
this" objection does not survive that: the improvement runs the wrong way.

## What this measured that a yield percentage would not

- **The rule's ceiling is a domain question, not a precision one.** 43 gateable sites in 7,151 is the
  whole story, and it comes from the interaction of two facts stated in different documents — the
  totality gate is catalogue-only, and most discarded calls are into project code. Neither reads as a
  problem alone.
- **An effect system tuned for envelopes is mistuned for discards, in a way that is not a bug.**
  `mutate.local` tolerance, `freeze` not being an effect, and `&:sym` not tainting are all correct for
  "what does this method's code do to the world". The discard rule asks a different question — "did
  this statement do anything for its caller" — and inherits answers to the first one. Three of the five
  FP mechanisms are that mismatch.
- **Writing the acceptance fixture out against the real catalogue files is a desk check.** § 1 took
  under an hour and is disqualifying on its own; it is the same lesson #389 taught, and it repeated
  because the criterion was again assumed rather than evaluated.
