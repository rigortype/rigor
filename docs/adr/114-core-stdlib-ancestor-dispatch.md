# ADR-114 — Inherited dispatch into core and stdlib RBS

Status: **Accepted — slice 1 landed, 2026-09-20.** A Ruby-source class whose discovered SUPERCLASS
chain reaches a class declared by Ruby core or a stdlib library now resolves its inherited instance
calls against that ancestor's RBS. `class SubHash < Hash` answers `has_key?` with `bool`,
`class MyError < StandardError` answers `message` with `String`,
`Kramdown::Utils::StringScanner < ::StringScanner` answers `scan` with `String?`. The include /
prepend side (issue #527 slice 2), any-RBS-known ancestor (slice 3), `super` (slice 5) and the
singleton side (slice 6) are out of scope here and land, or do not, on their own measurements. This
ADR partially supersedes [ADR-43](43-rbs-complete-ancestor-resolution.md)'s rejected alternative A —
the part of it that reads "core / stdlib" — and leaves the rest of that rejection standing.

Grounding: the 2026-09-01 corpus opacity sweep
([`docs/notes/20260901-corpus-opacity-attribution.md`](../notes/20260901-corpus-opacity-attribution.md),
harness on `origin/opacity-sweep-harness-20260901`), which located this family and sized it;
and issue #527's design pass, which re-probed every shape at master `24661077` and found three of the
seven already fixed.

## Context

ADR-43 asked whether a Ruby-source subclass may resolve its inherited calls against an RBS ancestor,
answered "only for an allow-listed ancestor whose RBS is complete", and rejected the blanket form:

> partial gem RBS turns every omitted inherited method into a `call.undefined-method` FP on working
> code

That reasoning is sound for a gem. It was applied to the whole question, and the effect is that
`Oj::EasyHash < Hash` reads `Dynamic[top]` for `has_key?` while a literal `{}.has_key?` folds — 26
sites in one gem, ~125 `class X < <core/stdlib class>` declarations across 18 survey targets, and
call sites in the low thousands. The subclass is a Ruby class the analysis can see whole; the
ancestor is `Hash`. Nothing about that pair is a partial gem RBS.

**What the intervening two years changed, and it is load-bearing.** ADR-43's wall is not reachable
through dispatch at HEAD. `undefined_method_diagnostic` declines at
[`check_rules.rb:730`](../../lib/rigor/analysis/check_rules.rb) on `Reflection.rbs_class_known?`, and
`arity_envelope_for` takes the source-only lane for the same reason — both keyed on the **receiver**,
which for a Ruby-source subclass is never RBS-known. That gate predates ADR-43 (`7b780f5c8`). So the
FP this ADR must argue about is not the one ADR-43 argued about.

## Decision

`RbsDispatch.lookup_method` resolves `method_name` against the first CORE or STDLIB class the
receiver's discovered superclass chain reaches, unless one of the declines below applies.

**The criterion.** A core or stdlib RBS declaration is the method set every negative check rule
*already* trusts for a direct receiver of that class: `{}.bogus` fires today, and it fires on the
strength of `hash.rbs`. Extending that trust one inheritance edge asserts nothing new about the
signature — it asserts that `class SubHash < Hash` means what Ruby says it means. A GEM's RBS is a
different claim, routinely partial, and stays outside; that is ADR-43's rejection, unchanged.

**The mechanism is a lookup change, not a tier.** `dispatch_one` keys `self`, `instance`, the
type-variable map and `SelfSubstitute` on the RECEIVER's class name, so replacing only the definition
`lookup_method` returns gets the correct `self` binding for free — `Hash#clear: () -> self` on a
`SubHash` receiver answers `SubHash`, not `Hash`. A new tier would have had to re-derive all four.

### Working decisions

**WD1 — the walk has one owner.** `ExpressionTyper#rbs_ancestor_answers?` already asked "does an
ancestor this project does not declare declare this name?" as a boolean, for the #633 / ADR-110
implicit-self binding veto. Slice 0 (PR #1127) extracted it to
[`Inference::ExternalAncestorResolution`](../../lib/rigor/inference/external_ancestor_resolution.rb),
which returns `[definition, owner_name]`. Two copies of an MRO cut-off rule is one copy too many, and
the second copy is the one that drifts.

**WD2 — the cut-off is `::Object`, reused rather than restated.** A declaration whose owner is
`Object`, `Kernel` or `BasicObject` does not resolve: those sit at or after a top-level `def`'s own
MRO rung, and #316 / #319 settled that a name they own carries no evidence about a subclass. The
resolver's `declared_before_object?` is that rule, so this slice inherits it rather than writing a
second one. It is also what keeps `Kernel#<=>`'s identity `0?` — issue #661's hazard —
from reaching these receivers at all.

**WD3 — type variables degrade; they are not inferred.** A `Nominal[SubHash]` receiver carries no
type arguments, so `build_type_vars` yields the empty map and `Hash[K, V]`'s free variables become
`Dynamic[top]` per the translator's contract. `SubHash#keys` is `Array[Dynamic[top]]`. That is
exactly what a raw `Hash` receiver already answers, so it is honest rather than a loss — and
inferring `K` / `V` from the subclass's writes is a separate, much larger question that this slice
deliberately does not open.

**WD4 — the declines, and what each protects.**

| Decline | Protects against |
| --- | --- |
| `class_name` is itself RBS-known | the direct lookup already had authority |
| an ADR-26 plugin-declared open receiver | a surface larger than its declarations |
| the walked ancestor, or the class the declaration is written on, is not core / stdlib | `< ActionController::Base` (no RBS at all) and `< Prism::Visitor` (a gem that ships RBS) — slice 3's question |
| an ADR-17 `pre_eval:` patch declares the name on the receiver or on any ancestor of the owner | adopting a declaration for a method the project has replaced |
| the subclass or a nearer SOURCE ancestor declares the name ([ADR-110](110-inherited-declaration-precedence.md)) | answering about a method that never runs |
| the walk exceeds `Scope::ANCESTOR_WALK_LIMIT` | an unbounded or cyclic hierarchy; recorded as a `BudgetTrace` hit, and the ADR-110 probes suppress rather than answer "not declared" from an unfinished walk |

The declines are conjunctive, so their order is free — and it is chosen so the two that walk the
project's tables run LAST, once a core / stdlib declaration is in hand. Every unresolved call on a
Ruby-source receiver reaches this code, and those walks file an ADR-46 ancestry edge; running them
unconditionally turned every cross-class method call into a file-granular ancestry dependency.

**WD5 — `ALLOWED_RBS_COMPLETE_ANCESTORS` is demoted, not deleted.** The constant and its
plugin-manifest twin (`rbs_complete_ancestors:`, ADR-43 WD4) keep their entries and their contract,
and acquire one job: an allow-listed ancestor BYPASSES the declines above. That is what it was always
for — `Rigor::Plugin::Base` is neither core nor stdlib, and the point of naming it was that its RBS
is authoritative anyway. Deleting it would have dropped the plugin contract's teeth; leaving it as a
parallel mechanism would have left two answers to one question.

**WD6 — core / stdlib membership is read off the declaration, not a list.**
`RbsLoader#core_or_stdlib_class?` tests a class's primary declaration's file against the `rbs` gem's
own `core/` and `stdlib/` trees, memoised per loader in one pass over `class_decls` — the same
mechanism, and the same limits, as `#project_declared_classes`. A hand-maintained name list would rot
against every rbs version. Note that `prism` and `rbs` are members of `DEFAULT_LIBRARIES` but are
GEMS whose signatures ship with the gem, so they are correctly outside the set.

## The false-positive boundary, restated

ADR-43's boundary was "resolution makes `call.undefined-method` reachable". That is **not** what this
slice does, and saying it does would misdescribe the risk. Absence-as-evidence is not introduced: the
negative rules gate on the receiver being RBS-known, and these receivers are not. Probed at master
and on the branch, `h.bogus`, `h.has_key?(:a, :b)`, `e.message(1, 2)` and `e.totally_bogus` on such a
subclass are silent both before and after, while the direct-core controls fire in both.

The risk this slice does carry is **wrong-precise propagation**: a type that is now precise becomes
the receiver of the NEXT call, and the negative rules do reach it there. `MyError.new("x").message`
is `String`, so `.bogus_downstream` fires — correctly here, and incorrectly in any case where the
declaration is not what runs. Every decline in WD4 is aimed at that one failure mode, which is why
the ADR-110 shadowing probe and the `pre_eval:` probe are asked of the whole ancestry rather than the
receiver alone.

## Limitations

- **The `rbs_class_known?` finding is a code reading plus probes, not an audit.** The claim that the
  negative rules cannot reach a Ruby-source subclass receiver rests on reading
  `undefined_method_diagnostic` and `arity_envelope_for`, and on the probes above. Every
  `call.*` / `static.*` rule was not enumerated against it. A rule that decides on the DECLARATION's
  owner rather than the receiver would see these calls; if one is found, this section is where the
  correction belongs.
- **Corpus evidence does not discriminate what it cannot reach.** A `check` sweep over targets that
  ship no `sig/` measures the gem-RBS declines vacuously. The gem-shipping-RBS decline
  (`< Prism::Visitor`) and the `pre_eval:` decline are pinned by fixture, not by corpus.
- **The cached-environment sentinel switches the feature off, not on.** Buffer names survive the
  ADR-54 environment cache (#725), but an old blob's `<cached>` sentinel lands every class outside
  the core / stdlib set. The failure direction is a silent return to `Dynamic[top]`, never a wider
  resolution — which is the direction [ADR-5](5-robustness-principle.md) wants, but it does mean a
  stale cache can make this slice look like it did not land.

## Rejected / deferred alternatives

- **(rejected) A new dispatch tier ahead of `RbsDispatch`.** Would have had to re-derive `self`
  binding, the `instance` projection, the type-variable map and `SelfSubstitute`, all of which
  `dispatch_one` already keys on the receiver's class name. A lookup change gets them for free.
- **(rejected) Widening `ALLOWED_RBS_COMPLETE_ANCESTORS` with core class names.** Membership there
  means "this RBS is complete, so a call it omits is a mistake" — a claim about the negative rules.
  Core RBS is not complete in that sense (`Hash` answers to whatever a program defines on it), and
  the claim this slice needs is weaker.
- **(deferred, slice 2) `include` / `prepend` into an RBS module.** `include Enumerable` →
  `#sort`, `include Comparable` → `#clamp`. The same walk reaches it — `Scope#external_ancestor_name_candidates`
  gathers both edges — so it is one keyword away, and is held back only so its measurement is its
  own. The implementation passes `mixins: false` for exactly this reason.
- **(deferred, slice 3) Any RBS-known ancestor.** The gem case ADR-43 rejected. It needs an argument
  about partial gem RBS that this ADR does not make, and a measurement this ADR does not have.
- **(deferred, slices 5 and 6) `super` resolution and the singleton side.** `resolve` takes `kind`
  and keys the memo on it, so the singleton arm lands without re-keying the cache; it declines today,
  which is what the engine answers there now.

## Relationship to other ADRs

- **[ADR-43](43-rbs-complete-ancestor-resolution.md)** — partially superseded. Its rejected
  alternative A is narrowed to the gem case; its allow-list survives as the bypass (WD5).
- **[ADR-110](110-inherited-declaration-precedence.md)** — supplies the shadowing rule that decides
  when a project `def` outranks an inherited declaration; this slice consumes it unchanged.
- **[ADR-24](24-self-method-call-resolution.md)** — supplies the `discovered_superclasses` edge.
- **[ADR-26](26-activerecord-relation-typing.md)** — the inverse knob; an open receiver declines here.
- **[ADR-17](17-monkey-patch-pre-evaluation.md)** — the `pre_eval:` patch table this slice probes.
- **[ADR-5](5-robustness-principle.md)** — the false-positive discipline the boundary section is written against.
