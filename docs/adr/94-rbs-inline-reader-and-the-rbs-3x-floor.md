# ADR-94 — The inline-RBS reader: `RBS::InlineParser` and the rbs 3.x floor

Status: **Accepted, 2026-07-16; WD2 corrected and closed 2026-07-17.** rbs 4.0 absorbed the
inline implementation, which dissolves the premise
[ADR-32](32-rbs-inline-comment-ingestion.md) chose its plugin boundary on. Migrating there is
the right direction and is **deferred**: it costs the rbs 3.x floor, and dropping that floor
is not planned for v0.3.0 or the versions near it. The `rigor-rbs-inline` plugin stays the
reader. WD2's `UntypedFunction` defect was real and independent of the migration, as recorded
— but this ADR misidentified its site and its symptom, and re-adjudication found it wider
than a hand-written `.rbs`. It is fixed; see WD2 for what was actually true.

Grounding: [`docs/notes/20260716-dspec-formal-spec-substrate-evaluation.md`](../notes/20260716-dspec-formal-spec-substrate-evaluation.md)
§ "ADR-93 WD1 の実装" and the measurements below.

## Context

soutaro called the `rbs-inline` gem a prototype in
[soutaro/rbs-inline#9](https://github.com/soutaro/rbs-inline/issues/9) (2024-05): "the
implementation will be merged to rbs-gem". It was. rbs 4.0.0 ships `RBS::InlineParser`,
`RBS::Source::Ruby`, and `Environment#add_source` support for it; rbs 3.9.4 and earlier ship
none of it.

ADR-32 WD1 rejected reading inline comments in core because that would make `rbs-inline` a
core runtime dependency, against [ADR-0](0-concept.md)'s zero-dep stance, and chose the
plugin boundary instead. **`rbs` is already a core dependency**, so a reader living in `rbs`
answers WD1's objection. It would also retire [ADR-93](93-default-rbs-inline-ingestion.md)
WD2 (default-wiring a plugin) and WD3 (the standalone residual, which exists only because a
`gem install rigortype` has no `rbs-inline`).

Measured 2026-07-16, rbs 4.0.3 against rbs-inline 0.14.0:

| source | rbs-inline 0.14.0 | `RBS::InlineParser` |
| --- | --- | --- |
| no annotation | `def f: (untyped x) -> untyped` | `(?) -> untyped` |
| a real annotation | honoured | honoured |
| `def f #:nodoc:` | `-> nodoc`, a type nothing declares | `AnnotationSyntaxError`, method stays untyped |
| annotation + `#:nodoc:` in one class | the class fails to build, every annotation lost | the annotation survives |

Both workarounds in PR #113 address defects `RBS::InlineParser` does not have. The skeleton
row is the load-bearing one, and the harm was never the `untyped` **return**: `(untyped x)`
declares an arity and a parameter type, which outranks inference (`"A"` degrades to
`Dynamic[top]`), while `(?)` (`RBS::Types::UntypedFunction`) claims nothing and leaves
inference alone. That distinction is why mail moved 26 → 42 under rbs-inline's opt-out mode
and would not under rbs's.

## Decision

> **A dependency migration that buys correctness a workaround already buys does not justify
> narrowing the supported toolchain range.**

The migration's whole cost is the rbs 3.x floor. Its benefit is deleting two workarounds that
work. [ADR-79](79-rbs-version-range-over-pinned-determinism.md) fixed the range at
`rbs >= 3.0, < 5.0` on the principle that Rigor checks against the toolchain the project
actually resolves; narrowing to 4.x drops every project pinned below it, and PR #22's
`Gemfile.rbs-compat` matrix (`~> 3.10` ∧ `~> 4.0`) exists to keep that width honest. Paying
that to delete ~40 lines of plugin code inverts the trade.

## Working decisions

**WD1 — the `rigor-rbs-inline` plugin stays the reader.** ADR-32 stands as amended by ADR-93
WD1. The annotation-presence gate and the RDoc neutralization stay; both would be deleted at
migration, and neither is load-bearing enough to force one.

**WD2 — the `UntypedFunction` defect is a separate bug and lands independently. Correct as
written; wrong on every particular. Fixed 2026-07-17.** The call this working decision made —
that the defect is independent of the migration, reachable without it, and lands on its own —
held. Re-adjudication (2026-07-17, prompted by the claim not reproducing) confirmed the bug
and corrected three things about it:

- **Not a crash.** `rigor check` never died. The `NoMethodError` was raised and then swallowed
  by one of the dispatcher's broad `rescue StandardError` clauses, so the dispatch degraded to
  `Dynamic[top]` and the method's **declared return type was silently discarded**. A `(?) ->
  String` method typed as untyped. Silent precision loss is the symptom, which is why the
  original probe read as a crash that would not reproduce.
- **Not `Analysis::CheckRules`.** That path was already guarded, and had been since before this
  ADR was written: `arity_eligible?` and `argument_check_eligible?` both bail via
  `respond_to?(:required_keywords)`, each documenting the untyped-function case as the reason.
  The unguarded site was `MethodDispatcher::ReceiverAffinity`'s pre-sort, which reached for
  `required_positionals` while reordering overloads by receiver affinity — upstream of the
  selector, which is why no selector-level guard could have caught it. `OverloadSelector`'s own
  arity path was unguarded too, but latent: the pre-sort raised first.
- **Not confined to hand-written `.rbs`.** This ADR guessed the trigger was a user writing `(?)`
  "or rbs 4.x core RBS adopting it". Core RBS ships it **already**, on `Proc#call`,
  `Method#call`, `Ractor.select` and `IO.for_fd` — so the defect fired on a stock `rigor check`
  against a project with no `sig/` at all. `Proc#call` and `Method#call` return `untyped`
  regardless, which is very likely why the loss stayed invisible for so long.

The fix guards each site with the bail the form implies: no affinity to compare, no arity to
enforce, no declared params to zip — and, load-bearing for false positives, `(?)` must never
win the selector's strict pass over a genuinely typed sibling overload, since a param list of
nothing otherwise satisfies "every param is strict" vacuously.

**WD3 — the decision under review is the floor, not the reader.** Re-open this ADR when the
rbs 3.x floor moves for its own reasons, not to make the migration possible. The reader
follows the floor.

**WD4 — coverage is unmeasured and gates any migration.** The four cases above are a probe,
not a survey. ADR-32's § Context lists the grammar the plugin inherits for free: method types
in three forms, generics, mixin generics (`include Foo #[String]`), `@rbs inherits`,
`@rbs override`, block-introduced types, attributes, instance variables, constants, alias,
`@rbs skip`, `@rbs!` raw RBS, `%a{…}` annotations. `RBS::InlineParser`'s coverage against that
list is unknown. Migrating on an unmeasured subset would trade the workarounds for silent
precision loss, which is the worse deal.

## Rejected / deferred alternatives

- **Migrate now and drop rbs 3.x.** Rejected: the floor is not scheduled to move, and the
  Decision's criterion says a workaround-equivalent benefit does not buy a range narrowing.
- **Vendor or fork `rbs-inline` with the `#:nodoc:` fix.** Rejected: PR #113's neutralization
  already gets the same result inside code we own, with no gem to publish or track.
- **Reimplement the annotation grammar in Rigor.** Rejected, twice over: ADR-32 WD1/WD3's
  grammar-drift argument stands, and the grammar is mid-move from `rbs-inline` into `rbs`, so
  a reimplementation would chase a target that is relocating.
- **Send the annotation-presence gate upstream.** Rejected: `with_annotation` existed in
  rbs-inline for one day (#18, then `83aaf69a`) and upstream's purpose wants the skeletons —
  `rbs-inline --output` generates a `sig/`, where a signature for every def is correct. The
  gate is Rigor's requirement because Rigor is inference-first, not upstream's bug.

## Re-evaluation triggers

- The rbs 3.x floor moves for an unrelated reason (an rbs 4-only feature Rigor needs, or the
  ecosystem's own 3.x support ending). The reader migration then rides along at near-zero
  marginal cost.
- `RBS::InlineParser` grows a capability the `rbs-inline` gem lacks, so the migration starts
  buying precision instead of deleting workarounds.
- The `rbs-inline` gem stops tracking the grammar its successor in `rbs` implements, and the
  plugin's inherited coverage begins to rot.

## Relationship to other ADRs

- **ADR-32** — the plugin boundary this preserves. Its WD1 premise (the reader is a non-core
  gem) no longer holds; the boundary now rests on the rbs 3.x floor instead.
- **ADR-79** — supplies the range this refuses to narrow, and the fidelity principle behind it.
- **ADR-93** — WD2/WD3 would be retired by the migration; both stay live while it is deferred.
- **ADR-0** — the zero-dep stance that made `rbs-inline` a plugin. A reader inside `rbs` would
  satisfy it directly.
