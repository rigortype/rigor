# `sig/` against inline: the consistency rule's false-positive gate (#1075)

Status: measurement note for [#1075](https://github.com/rigortype/rigor/issues/1075), the gate
[ADR-112](../adr/112-extrbs-comment-channel.md) WD5 sets before `rbs.contradicting-signature` ships as an
error: *"Before shipping, the rule runs on herb, mastodon, redmine and Rigor itself. A false positive fixes
the rule and does not lower the severity."* No design commitments beyond what the PR shipped. Taken on the
branch `sig-inline-consistency-1075` against its base `698604d1`, Ruby 4.0.5, rbs 4.2.0.

## Method

Two runnable engine copies in the scratchpad, per the engine-arm recipe: `arm_base` carries
`git archive 698604d1 lib`, `arm_new` the branch's `lib`; `diff -rq` of the two `lib` trees showed only
the files the branch touches. Each target is a private `rsync -a` copy of the survey checkout (`.git`,
`node_modules`, `.rigor`, `tmp` and `log` excluded), and Rigor's own tree is a copy of the branch's `lib`,
`sig` and `.rigor.dist.yml`, so both arms read identical inputs. One target at a time:

```sh
cd <copy> && BUNDLE_GEMFILE=<worktree>/Gemfile bundle exec ruby -I<arm>/lib <arm>/exe/rigor \
  check --no-cache --no-baseline --format json --workers=2 [lib]
```

The diagnostic sets were differenced as `(path, line, rule, severity, message)` tuples. A third copy,
`arm_instr`, appends every `MemberConsistency::Record` to a file when `RIGOR_MC_DUMP` is set (four lines
at the top of `Environment.record_member_consistency`) and ran each target once at `--workers=0`, so
the census below counts what the rule decided rather than only what it reported.

## Result

| Target | Inline-annotated `.rb` | `sig/` | Diagnostics base → new | Contradictions | Undecided | Merged (equal / `sig/` / inline) |
| --- | ---: | :---: | --- | ---: | ---: | --- |
| herb (`lib`) | 130 | yes | 2,519 → 37 | 0 | 0 | 2,482 (1,944 / 538 / 0) |
| mastodon (`app`, `lib`) | 0 | no | 2,549 → 2,549, identical | 0 | 0 | — |
| redmine (`app`, `lib`) | 0 | no | 1,716 → 1,716, identical | 0 | 0 | — |
| Rigor (`lib`) | 0 | yes | 1 → 1, identical | 0 | 0 | — |

**Zero `rbs.contradicting-signature` rows on all four targets, and no other rule moved.** herb's whole
delta is 2,482 `source-rbs-annotation-not-honoured` `:info` rows that ADR-32 WD13 used to print, one per
member herb declares in both places; every one of them is now a consistent pair and silent. Every
remaining diagnostic in herb, 37 of them, is byte-identical between the arms. The 9
`source-rbs-annotation-not-honoured` rows still in herb are unrelated WD12 causes: `#:` lines that
do not parse (`#: type serialized_node = {`, `#: … as String`).

herb's `sig/` is rbs-inline's own output for the same annotations, so equality is the expected
outcome for most pairs. All 538 pairs where `sig/` is the more precise side are rbs-inline's skeletons
for unannotated `def`s in an annotated file, each carrying `%a{rigor:v1:inferred-signature}` (ADR-93
WD6): no author wrote that inline side, so `sig/` keeps binding exactly as before, without a row. ADR-93's `sig/ -> untyped` beside an inline `-> void` reads
as equal, because RBS defines `untyped`, `void` and `top` as the same top type.

## Cost

Allocations on herb, in-process (`GC.stat(:total_allocated_objects)` around `Rigor::CLI#run`,
`--workers=0`), arms alternated, each figure repeated identically across two reps:

| herb | base | new |
| --- | ---: | ---: |
| cold (`--no-cache`) | 13,290,406 | 13,383,596 (+0.7%) |
| warm (run cache hit) | 444,944 | 408,937 (−8.1%) |

A warm hit still derives the run-level rows, so it runs the rule once; the 2,482 `:info` messages it
no longer formats outweigh the comparisons. A cold run derives the rule twice, once for the build and
once for the rows, and parses the inline sources one extra time. A project without inline RBS never
reaches the rule: the loader returns before parsing anything, and the comparison's dependencies are
loaded only when a comparison runs.

## What the gate does not exercise

Only herb reaches the rule. mastodon and redmine ship neither a `sig/` nor an inline annotation, so
their zero delta says only that the new code path costs them nothing; the same holds for the other 22
survey targets, of which five ship a `sig/` (haml, kramdown, mangrove, rgl, textbringer) and none an
inline annotation. Rigor's own tree has no member declared in both places today: the 17 overlapping
files #824 measured in September have since been reconciled, and the nine `lib/` files that mention
`# @rbs` or `#:` do so in prose. No target produced a contradiction, so the positive half of the rule
rests on the fixtures in `spec/rigor/environment/rbs_loader_spec.rb` and
`spec/integration/plugins/rbs_inline_plugin_spec.rb`, which fail on the base engine.

Two limits come from the definition rather than the corpus, and both err toward silence. A
contradiction needs a proof that no value is both, read from the RBS class hierarchy the analysis
uses: distinct literals, a literal outside an RBS class, or two classes RBS declares neither of which
is an RBS ancestor of the other. A module, an interface, a class RBS does not declare, a relative name
the project defines, and a position a call may leave empty never prove it; such a pair reads as
undecided (`:info`). And which side binds is decided from the two declarations alone, so a subclass
relation (`Integer` against `Numeric`) is undecided too.

## Review round 1 (PR #1428)

The first version read "both `accepts` answers are `no`" as disjointness, and zipped overloads by
position. The review found shapes that turn correct pairs into errors: reordered overloads,
`Comparable` against `Enumerable[untyped]`, `String` against `Enumerable[untyped]`, `bool` against
`TrueClass`, a relative `Data` inside `module App` read as core `::Data`, a keyword against a
positional `Hash` or a `*rest`, and a block's parameter count. It also found two silent losses when
the inline side bound: a `sig/` member's `rigor:v1:predicate-if-true` (narrowing fell from `String`
to `Dynamic[top]`) and its `private` visibility. The disjointness proof, the overload pairing, the
name check, the keyword and block rules and the binding conditions were rewritten as the spec now
states them, each with a spec that fails on the first version. herb was re-run on the revised engine
(one target, `--workers=2`, plus the census): the numbers above are unchanged — 2,519 → 37
diagnostics, 2,482 records (1,944 equal, 538 `sig/` more precise), no contradiction.

Once `rigor sig-gen` writes inline-declared members into `sig/` by default (#1076), every such pair
is equal by construction. The rule's contradiction row is then what a stale generated signature
looks like.

## Review round 2 (PR #1428)

The round-1 proof read class relations from Ruby constants loaded in the analyzer process. rbs
declares `Tempfile < File`, while the `tempfile` library defines `Tempfile < Delegator`, so `sig/ ->
File` or `-> Object` against an inline `-> Tempfile` was undecided from the plain CLI and a
contradiction under `-rtempfile` — and the language server requires `tempfile`. The proof now reads
the RBS hierarchy of the built environment (`MemberConsistency::RbsProof`), and the decision of which
side binds reads no hierarchy at all, so the answer is the same whatever the process has loaded; the
probe project gives the same rows with and without `-rtempfile -rstringio`. The same round made a
relative name the project's Ruby source defines unprovable (a Ruby-only `App::Set < Array` no longer
lets `Set` read as core `::Set`), and made an optional, rest, optional-keyword or optional-block
position unable to contradict. herb re-run on the final engine (one target, `--workers=2`, plus the
census): unchanged — 2,519 → 37 diagnostics, 2,482 records (1,944 equal, 538 `sig/` more precise), no
contradiction.
