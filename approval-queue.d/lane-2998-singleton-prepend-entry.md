# A singleton-side prepend is told apart from an extend by an envelope entry, not a new discovery table

- **PR:** [#3009](https://github.com/rigortype/rigor/pull/3009)
- **Issue:** [#2998](https://github.com/rigortype/rigor/issues/2998)
- **Class:** open-choice
- **Precedent:** [#2996](https://github.com/rigortype/rigor/pull/2996)
- **Decided:** 2026-11-09

## Background

`discovered_extends` holds a class's `extend`s and its `class << self; prepend P` edges in one nearest-first list, so
the singleton resolution chain could not tell a prepend, which sits ahead of the class object's own `def self.`
methods, from an `extend`, which sits behind them. Issue #2998 asks for the prepend's position. It does not say where
the kind of each edge is recorded.

## Options and trade-offs

- Add a discovery table, the singleton twin of `discovered_prepends`. That mirrors the instance side, but the table
  has to be threaded through the runner seed, the project pre-pass, the cache bundles and the incremental diff. That
  is about ten touch points for an edge kind few classes use.
- Record a `[ENVELOPE_SINGLETON_PREPEND_KIND, "P"]` entry in the class's envelope bucket, as #2996 records a hook's
  extended modules there. The bucket already flows through every one of those paths, and the kind joins the diffed
  class marks for `--incremental`. The chain reads an `extends` edge as a prepend only where the entry names it, so
  a walk that records one table but not the other leaves the edge an `extend`, which is the pre-#2998 reading.
- Overload `unpositioned_mixins` with a third side key. That table means "order not a fact", and every reader of it
  would have to learn that one key means something else.

## Decision

The envelope entry. It follows #2996's precedent for a per-class fact the singleton chain reads. The same change
reads a direct `singleton_class.prepend P` statement, the `send(:prepend, P)` spelling included, as positioned,
because it runs where it is written as `prepend P` in `class << self` does. `singleton_class.include M` keeps its
unpositioned reading, which the issue did not ask about. A constant receiver's `Const.singleton_class.prepend P`
also files the entry, on every name the constant can denote, but its edge stays unpositioned, so the typing read
declines wherever the chain and master answer differently (review round 1 of #3009).

## To undo

Drop `ScopeIndexer#record_own_singleton_prepend` and `ENVELOPE_SINGLETON_PREPEND_KIND`. Then move the kind into a new
discovery table read by `ResolutionChain::Builder#own_singleton_prepends`.
