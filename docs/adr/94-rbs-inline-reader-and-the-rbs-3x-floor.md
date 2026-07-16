# ADR-94 — The inline-RBS reader: `RBS::InlineParser` and the rbs 3.x floor

Status: **Accepted, 2026-07-16.** rbs 4.0 absorbed the inline implementation, which dissolves
the premise [ADR-32](32-rbs-inline-comment-ingestion.md) chose its plugin boundary on.
Migrating there is the right direction and is **deferred**: it costs the rbs 3.x floor, and
dropping that floor is not planned for v0.3.0 or the versions near it. The
`rigor-rbs-inline` plugin stays the reader. One measured blocker, the `UntypedFunction`
crash (WD2), is a live bug independent of the migration and lands on its own.

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

**WD2 — the `UntypedFunction` crash is a separate bug and lands independently.** A `(?)`
method type in a hand-written `.rbs` crashes `rigor check` today:
`NoMethodError: undefined method 'required_positionals' for an instance of
RBS::Types::UntypedFunction`. `Inference::MethodDispatcher::RbsDispatch` guards the form for
blocks; the arity path in `Analysis::CheckRules` does not. This is reachable without any
migration (a user writes `(?)`, or rbs 4.x core RBS adopts it), and it is a prerequisite of
the migration rather than part of it.

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
