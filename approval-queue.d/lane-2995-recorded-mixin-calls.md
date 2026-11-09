# An include written in a method body through `send` is recorded, unpositioned, as a bare `include` there is

- **PR:** [#3004](https://github.com/rigortype/rigor/pull/3004)
- **Issue:** [#2995](https://github.com/rigortype/rigor/issues/2995)
- **Class:** open-choice
- **Precedent:** [ADR-119](../docs/adr/119-discovery-fact-certainty.md)
- **Decided:** 2026-11-09

## Background

The change records `self.include M` and a receiverless `send(:include, M)` in the include tables. The issue left
one case open: `def self.setup = send(:include, M1)` includes `M1` only when `setup` runs. It asked whether that
case stays open (every name accepted, the #2993 workaround) or is recorded, and required that `m1` must not
report if `setup` may be called.

## Options and trade-offs

- Keep it open. Nothing reports on the class, so a call to a method neither the class nor `M1` provides is lost,
  and the method-body case reads differently from a bare `include M1` in the same body.
- Record it as the walk already records a bare `include M1` in a method body: in the include set, listed in
  `unpositioned_mixins` (ADR-119 WD7) so order readers decline. `m1` stays quiet whether or not `setup` runs, and
  `m2` reports. If `setup` never runs, `m1` is accepted where Ruby raises: the same over-approximation the bare
  form already takes.

## Decision

Record it. The bare form in a method body is recorded this way already, and ADR-119 is the reading of an edge
whose position is not a fact. Both spellings run the same `Module#include`, so reading them differently would
only make one of them wrong.

## To undo

Make `ScopeIndexer#instance_mixin_recorded?` return false for a `send` spelling that is not a direct statement.
The call then falls back to a `"*"` taint, which reports `m1` unless the #2993 `listed_mixins` path is restored.
