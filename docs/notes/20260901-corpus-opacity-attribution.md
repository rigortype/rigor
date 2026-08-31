# Corpus-wide opacity attribution — where types do not attach, on 25 targets (2026-09-01)

Status: measurement note. Master `2d0ffe6f` (post-v0.3.6). Sequel to
[`20260831-self-check-type-coverage-audit.md`](20260831-self-check-type-coverage-audit.md), which
closed the precision search on this repository's own `lib` (parameters, ADR-67, gated) and left two
corpus-shaped questions open: what the named-receiver-but-Dynamic-dispatch calls on real
applications actually are, and what `unsupported_syntax` — 29.7% / 44.0% of unprotected-site causes
on redmine / mastodon — actually names.

## Method

Eight analysis agents over 25 disjoint targets: this repository's `lib`, redmine, mastodon, and 22
gems/corpora spanning template engines (liquid, kramdown, haml, slim, hamlit, erubi, herb),
network/serialization (faraday, net-ssh, mail, jbuilder, tdiary-core), native-extension gems (oj,
ox, numo-narray, pycall, rbnacl, protobuf), infrastructure (concurrent-ruby, rubocop-ast, parser,
rgl, algorithms), an own-RBS gem (textbringer) and three plain-Ruby exercise corpora. Per target:
`rigor coverage`, `coverage --protection --format json` (cause histogram), and a shared attribution
probe recording, for every opaque expression, its node class, a local read's parameter bucket, a
call's receiver tier, and the (precise receiver, method) pairs whose dispatch still answers
Dynamic. Every category-D (engine gap) claim below was verified with a same-file control repro, and
each mechanism's repro is preserved with the 25 per-target case reports on branch
**`opacity-sweep-harness-20260901`** (`tool/opacity-sweep-20260901/`). The probe was
consistency-checked against the CLI (byte-identical expression count and ratio on kramdown).

One caveat binds every per-target site count: the probe shares
[#513](https://github.com/rigortype/rigor/issues/513)'s under-seeded lens, so counts overstate
product-level holes wherever the check walk's eleven-table seed resolves a cross-file call the lens
cannot. Same-file-verified mechanisms are unaffected; #513 itself was re-confirmed independently by
four of the eight agents and is this sweep's wave-0 fix.

## Headline numbers

| target | files | exprs | precision | protection |
| --- | --- | --- | --- | --- |
| rigor-lib | 430 | 167,079 | 58.9% | 45.7% |
| redmine | 346 | 128,495 | 47.8% | 35.0% |
| mastodon | 1,325 | 150,145 | 48.9% | 34.0% |
| textbringer (own sig/) | 77 | 32,923 | 66.5% | 52.1% |
| herb (own sig/) | 42 | 22,027 | 60.7% | 48.1% |
| 20 other gems/corpora | 1,398 | ~630k | 37.6–67.6% | 16.4–57.8% |

(mail's 97.8% precision is ragel-table constant inflation; its comparable opaque mass is ~9,300.
Full per-target table: the branch's `reports/*.summary.json`.)

Opacity category totals across all 25 (sites as reported; probe lens, see caveat):

| category | sites | reading |
| --- | --- | --- |
| A — param-sourced (ADR-67, closed) | ~64,000 | dominates everywhere: 18–30% of opacity per target, plus its arithmetic/ivar cascade |
| G — join/mirror metric artifacts | ~27,800 | If/And/Or/Block/EmbeddedStatements mirror an inner opaque expression; not independent holes |
| C — container-of-Dynamic propagation | ~18,400 | `Hash[K, Dynamic]#[]` etc.; origin is almost always A or B one hop up |
| E — framework/plugin territory | ~11,000 | Rails surface concentrated; [#534](https://github.com/rigortype/rigor/issues/534), [#460](https://github.com/rigortype/rigor/issues/460) |
| D — engine dispatch gaps | ~5,900 direct | the fixable lane; each fixed receiver un-Dynamics a chain, so direct counts are floors |
| F — "unsupported syntax" | ~4,300 labeled | **~95–99.9% mislabeled**; genuine syntax is ~100–200 sites corpus-wide |
| B — missing RBS | ~3,300 | target-shaped: decisive for net-ssh (OpenSSL), rubocop-ast (parser gem), numo (own C API) |

## The two questions the audit left open, answered

**The `unsupported_syntax` cause is a misnomer bucket.** Decomposed on every target: mastodon's
9,070 cause-sites trace to 26,505 carrying nodes of which **27** are genuinely unmodeled Prism
constructs (`CallOperatorWriteNode` 20, `CallOrWriteNode` 7); redmine 37 of 19,408; textbringer 5
of 692. Everything else is name resolution — unresolved implicit-self sends (framework DSL,
concern methods), chain-inherited carry, unresolved constants (Zeitwerk implicit namespaces,
undeclared framework/gem constants), and unresolved dispatch on named receivers. Two label bugs
compound it: a call whose receiver HAS a discovered project def loses `inferred_return_untyped`
when body inference declines ([#522](https://github.com/rigortype/rigor/issues/522)), and the
WD9 missing-gem index under-claims through superclasses, unclaimed lock entries, and lockless
targets ([#530](https://github.com/rigortype/rigor/issues/530)).

**The named-receiver-but-Dynamic pairs decompose into a short mechanism list**, each
cross-confirmed on 4–12 targets and same-file-verified:

| mechanism | breadth | issue |
| --- | --- | --- |
| per-signature bail on optional/rest/keyword/block params in user-method return inference | 10 targets; the widest lever | [#524](https://github.com/rigortype/rigor/issues/524) |
| `T \| nil` receiver dispatch declines outright (nil arm vetoes the union) | 12 of 13 target groups | [#519](https://github.com/rigortype/rigor/issues/519) |
| safe navigation typed as a plain call — `s&.to_s` drops nil (a wrong type, not just imprecision) | universal | [#518](https://github.com/rigortype/rigor/issues/518) |
| assignment expressions type as the writer's return, not the RHS | universal | [#520](https://github.com/rigortype/rigor/issues/520) |
| ancestor walk missing: source subclass → RBS class, RBS-module includes, `include Singleton`, concern defs | 7 targets | [#527](https://github.com/rigortype/rigor/issues/527) |
| `extend M` / `extend self` invisible to singleton dispatch | 4 targets | [#526](https://github.com/rigortype/rigor/issues/526) |
| `Struct.new` factories: do-block bodies lose members, `.new`, and self scoping | 6 targets | [#525](https://github.com/rigortype/rigor/issues/525) |
| RBS `Alias` / `Intersection` translate to untyped (prism's `type node` collapses) | every RBS-bearing target | [#529](https://github.com/rigortype/rigor/issues/529) |
| Zeitwerk implicit namespaces unresolvable (`Api`, `REST`) | Rails apps | [#528](https://github.com/rigortype/rigor/issues/528) |
| `Array.new(n, fill)` with non-literal size discards the element type | 3 corpora, ~500 sites | [#531](https://github.com/rigortype/rigor/issues/531) |
| overload selection pins a wrong precise arm on a Dynamic discriminator (`[true] * n` → String) | FP-relevant | [#521](https://github.com/rigortype/rigor/issues/521) |
| `x.attr \|\|= v` family unhandled (typing + widening, the #504 sibling) | the only real syntax gap | [#532](https://github.com/rigortype/rigor/issues/532) |
| eight small verified gaps (heredoc-constant dispatch, `alias_method`, `send(:sym)`, refined-receiver lookup, `Proc#[]`, `::Queue` alias, conditional superclasses, empty-array index mutation) | scattered | [#533](https://github.com/rigortype/rigor/issues/533) |

Measurement-side: the precision classifier counts Data/Struct/BoundMethod carriers as opaque — 810
sites on `lib` alone ([#523](https://github.com/rigortype/rigor/issues/523)) — and the lens
under-seeds ([#513](https://github.com/rigortype/rigor/issues/513)).

## What the archetypes say

The own-RBS archetype (textbringer, herb) confirms the 2026-06-01 finding — coverage ceiling = own
RBS completeness — and is where D becomes decidable: herb's sig declares `Token#value: String` and
the `?` on the receiver alone discards it. The beginner archetype (three corpora) is an order of
magnitude A, and its non-A remainder concentrates in exactly three mechanisms (#531, #519 via
`gets`, `::Queue` alias). The native-extension family keeps receiver identity everywhere and loses
returns/constants, splitting into pure-B (numo — an RBS sidecar converts it wholesale), an FFI
plugin opportunity already filed as [#141](https://github.com/rigortype/rigor/issues/141)
(`attach_function` carries name/arity/types; pays rbnacl, pycall, protobuf at once), and
runtime class generation (plugin-or-nothing). The Rails apps' distinctive mass is E
([#534](https://github.com/rigortype/rigor/issues/534)) plus the mislabeled name-resolution story
above.

## What this note does not claim

Site counts are probe-lens counts (see the #513 caveat) and category assignments for
non-D buckets are the analysis agents' judgment, spot-verified rather than exhaustively adjudicated.
The A/ADR-67 and ADR-58 conclusions are not re-litigated here — this sweep counts them and moves
on. Fix ranking within D deliberately weighs FP-relevance (#521's wrong-precise pin) above raw site
counts, per the false-positives-first value.
