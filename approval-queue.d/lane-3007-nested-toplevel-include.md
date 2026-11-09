# A top-level include in a top-level def body or a self-keeping iterator's block is recorded; one in another block is not

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
- `[1].each do include M end` at the top level: record every block, no block, or only blocks the walk can show keep
  `main` as `self`. In general the walk cannot tell a block that keeps `self` from one that rebinds it
  (`describe do include M end`, `class_exec`). Recording every block's `include` would mix each example group's
  helpers into `Object` for the whole project.

## Decision

Record a top-level `def` / `def self.` body's include (WD7 precedent). Inside a block, record the include only when
the block is a core iterator's that keeps `self` (`each`, `each_with_index`, `each_with_object`, `map`, `times`,
`upto`, `downto`, `tap`, `then`, `loop`) on an Array, Range or Integer literal receiver, or a receiverless `loop`,
`tap` or `then`. Every other block stays unrecorded (#1697 precedent): `describe do … end`, `Class.new { … }` and
any iterator on a receiver the walk cannot type. The `TOPLEVEL_INCLUDE_KEY` edges feed only diagnostic silences, not
typing, so recording more costs lost reports and never adds one. Review round 1 of the PR asked for the iterator
case.

## To undo

Drop the `Prism::DefNode` arm of `ScopeIndexer::MainSelfCalls.visit` to stop recording the def body; make
`self_keeping_block?` return false to stop recording the iterator blocks.
