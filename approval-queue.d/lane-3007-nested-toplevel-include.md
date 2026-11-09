# A top-level include in a top-level def body is recorded; one in a top-level block is not

- **PR:** [#3013](https://github.com/rigortype/rigor/pull/3013)
- **Issue:** [#3007](https://github.com/rigortype/rigor/issues/3007)
- **Class:** open-choice
- **Precedent:** [ADR-119](../docs/adr/119-discovery-fact-certainty.md)
- **Decided:** 2026-11-09

## Background

#3007 records a top-level `include M` (bare, `self.` or `send`) that control flow wraps (`if`, `begin`, `case`,
…) under `TOPLEVEL_INCLUDE_KEY`, unpositioned. The brief left the `def` and block cases to precedent.

## Options and trade-offs

- `def setup; include M; end` at the top level: record it, unpositioned, as WD7 records an `include` in a class's
  method body (and as #3004 records `def self.setup = send(:include, M)`), or leave it unrecorded. Recording it
  silences `m` everywhere even if `setup` never runs, or runs with another `self`: the same over-approximation the
  class-body form takes.
- `[1].each do include M end` at the top level: record it, or keep #1697's rule. The walk cannot tell a block that
  keeps `main` as `self` from one that rebinds it (`describe do include M end`, `class_exec`), and recording every
  block's `include` would mix each example group's helpers into `Object` for the whole project.

## Decision

Record a top-level `def` / `def self.` body's include (WD7 precedent); keep a top-level block's include
unrecorded (#1697 precedent). The block case keeps a false positive where the block runs with `main` as `self`;
the PR lists it as a known limit.

## To undo

Drop the `Prism::DefNode` arm of `ScopeIndexer::MainSelfCalls.visit` to stop recording the def body; descend into
a call's block there to record the block case.
