# Top-level `def` cref — sizing the peel before retracting it (#716)

Status: measurement note. Sizes the population [#716](https://github.com/rigortype/rigor/issues/716) asks for before its fix is written; no design commitments beyond the reading recorded under "Decision".

- Date: 2026-09-05
- Tree: `master` at `78567987`, Ruby 4.0.5 through the Flake
- Question owner: [#716](https://github.com/rigortype/rigor/issues/716) § "What to check before fixing", item 1

## The defect, restated

A top-level `def` called from inside a namespace resolves its constants under the **caller's** namespace. Ruby's `Module.nesting` in a top-level `def` body is `[]`, so `def helper = Post.new` names `::Post` wherever it is called from; Rigor answers `Admin::Post` when the call is made from inside `module Admin`.

[#709](https://github.com/rigortype/rigor/pull/709) records each `def`'s nesting at declaration time and correctly records **nothing** for a top-level `def` — `Inference::ScopeIndexer#walk_def_nestings` says so in as many words. `Reflection.lexical_nesting_chain` then reads "not recorded" and falls back to peeling the scope's enclosing class path, which at that point is the caller's. The fallback is doing exactly what it was written to do; the bug is that a nil chain on a top-level `def` is not "no answer recorded" but Ruby's answer, and Ruby's answer is `[]`.

Reproduced on master, cold, with no RBS in play:

```
f716.rb:13:11: info: dump_type: Admin::Post [dump.type]
```

MRI answers `Post` for the same file.

## Why it had to be sized first

Retracting the peel is the FP-first direction on the reads that move, but the peel is also what makes a top-level helper's constant reads resolve at all. The trade is only real if the peel is currently load-bearing, so this measures two disjoint populations rather than assuming either.

- **movable** — a top-level `def` reads a constant whose bare name exists BOTH at the project's top level and under some project namespace. Only here can the caller-namespace peel answer something other than the top level.
- **nested-only** — the same read where the name exists ONLY under a namespace. Ruby raises `NameError` at these; the peel is the sole source of any answer, so they are exactly what an unconditional retraction would cost.

Both are **static upper bounds**: the probe does not check that the top-level `def` is actually called from inside the namespace that would be peeled, and it counts a name as project-declared from the source tree alone, so a constant that really resolves through a gem or through RBS inflates *nested-only*. Treat the columns as a ceiling on the movable population, not as a site count.

## Harness

Prism, no Rigor in the loop, so the numbers are independent of the analyzer whose behaviour is in question. Kept inline rather than as a branch: it is short enough to re-run from this note.

```ruby
require "prism"
# Stage 1: `def` nodes with no enclosing class/module keyword and no receiver.
# Stage 2: of those, the ones whose body reads a constant.
# Stage 3: split each read by where its bare name is declared in the project --
#          top level AND nested  => "movable" (the peel can answer differently)
#          nested only           => "nested-only" (Ruby NameErrors; the peel is the only answer)
#
# `declared` is built by walking every ClassNode / ModuleNode and qualifying its
# constant_path against the enclosing prefix, re-anchoring a rooted `class ::Foo`
# at the top level. `toplevel_defs` is built by descending the tree and refusing to
# recurse past a ClassNode / ModuleNode / SingletonClassNode.
```

Full script: `movable_toplevel_def.rb`, reconstructible from the three stages above in about 70 lines; the only subtlety is that a `Prism::ConstantPathNode` contributes its FIRST segment (`A` of `A::B`), because that is the segment lexical resolution answers.

## Results

| target | files | top-level defs | with const reads | movable (ceiling) | nested-only (ceiling) |
| --- | ---: | ---: | ---: | ---: | ---: |
| rigor `lib/` | 444 | 0 | 0 | 0 | 0 |
| mail | 196 | 20 | 14 | 0 | 0 |
| liquid | 150 | 0 | 0 | 0 | 0 |
| parser | 87 | 1 | 1 | 0 | 0 |
| haml | 98 | 16 | 10 | 0 | 0 |
| faraday | 71 | 21 | 4 | 0 | 0 |
| concurrent-ruby | 345 | 65 | 26 | 0 | 5 |
| mastodon | 3,260 | 615 | 357 | 66 | 3 |
| dependabot-core | 1,650 | 256 | 149 | 2 | 33 |
| gitlab | 51,350 | 9,220 | 2,508 | 1,797 | 486 |

Two things the table says that the totals hide.

**Rigor's own `lib/` has zero top-level defs.** The self-check can never observe this defect, which is why it survived #709 and why no gate points at it. That is the same shape as the `sig-gen --write` findings from 2026-09-04: our own tree is too disciplined to reach the bug.

**Mastodon's 66 name Rails migrations as the nesting owner** — `FixAccountsUniqueIndex`, `RemoveFauxRemoteAccountDuplicates`, `AddSilencedAtSuspendedAtToAccounts` and friends, migration classes that declare a local shadow model (`class Account < ApplicationRecord`) inside the migration body. `Account` (20 reads), `User` (10), `Status` (7) and `IpBlock` (4) head that distribution.

> **Correction (2026-09-05, from [#764](https://github.com/rigortype/rigor/pull/764)).** This section originally called those 66 "the canonical shape of the defect rather than an artifact". That was wrong, and the ceiling caveat above is exactly what it failed to apply to itself. The 66 pair a name collision with a *nesting owner*; they say nothing about where the reading `def` sits or who calls it. Bucketing the same reads by the file that declares them puts **all 66 in `spec/`** — 31 in `spec/lib`, then `spec/services`, `spec/workers`, `spec/requests`, `spec/helpers`, `spec/controllers`, `spec/models`, `spec/system` — and **none in `app/` or `lib/`**. They are RSpec top-level helpers whose callers are `RSpec.describe` blocks, which push no cref, so the peel never reaches the migration's shadow class. For a site to move, mastodon would need a top-level helper called from inside a `class` / `module` body that declares its own copy of a name the helper reads; it has none, which is why #764's corpus diff is zero. Read the table as what it says it is — a ceiling on name collisions — and resolve reachability separately.

## Decision — and what it costs

The measurement rules out the version of the trade the issue was worried about. On seven of ten targets the peel reaches nothing at all, and where it does reach something (mastodon) the peel's answer is the WRONG one — the shadow model, not the app model — so retracting is a correctness gain there, not a precision loss.

But *nested-only* is not zero at scale (gitlab 486, dependabot-core 33), and those reads resolve today only because of the peel. So the retraction should not be unconditional. The ordering that costs nothing:

1. A `def` whose nesting is recorded EMPTY (top level, definitively) resolves its constants at the top level — Ruby's answer — instead of through the caller's chain. This also has to suppress the caller-derived ancestor rung (step 2 of `Reflection.resolve_constant_type`), which is just as wrong for a top-level `def`: Ruby's cref there is `Object`.
2. When the top level does not answer, fall back to the peel exactly as today.

Rung 2 is unsound against Ruby — those are the `NameError` sites — but it keeps every read that resolves today resolving, so the change cannot regress precision anywhere, and the sites it covers are ones Rigor reports nothing about either way. Making them fire is a separate question with its own FP budget, and it should not ride on this fix.

The distinction the fix turns on is **"recorded empty" versus "not recorded"**, which the tables can already express: `discovered_def_nestings` is keyed by node identity and populated only by an actual declaration walk, so a node present with `[]` means "walked, and top-level", while absent still means "no walk" and keeps the peel. `walk_def_nestings` records nothing today for a top-level `def` and is the one place that has to change its mind.

## Follow-ups this note does not take

- The corpus arm belongs to the fix, not to the sizing: a `rigor check` diff on mastodon is the instrument that turns the 66-read ceiling into a site count.
- [#656](https://github.com/rigortype/rigor/issues/656) (a constant path's first segment never resolved through ancestors) is the other live member of this family and is untouched here.
