# A hook extend the chain cannot place opens the includer's singleton side instead of adding an edge

- **PR:** pending
- **Issue:** [#1592](https://github.com/rigortype/rigor/issues/1592)
- **Class:** open-choice
- **Precedent:** [ADR-119](https://github.com/rigortype/rigor/blob/master/docs/adr/119-discovery-fact-certainty.md)
- **Decided:** 2026-11-09

## Background

A hook can extend its includer with a module that the hook does not name by a constant
(`base.extend(const_get(:X))`), or under a condition (`base.extend(X) if c`), or through `base.send(:extend, X)` or
`base.singleton_class.include(X)`. A concern's `included do … end` block can do the same. The issue asked for such a
read to fall back or decline rather than answer the superclass's method. On master, the singleton side's fallback is
the class objects' own answer, which is exactly the superclass's.

## Options and trade-offs

- List `"*"` on the hook module's `:extend` side, as the indexer already does for a hook's mixin call. The includer's
  chain does not draw on that side, so nothing would change.
- Give the includer's singleton chain a non-order mark (`:include_hook`, listing `"*"` and `"?"`). A candidate-set
  read then declines, the existence reads open, and the typing read withholds any answer past the class's own entry.
- Treat a conditional `base.extend(X)` as a plain edge. A correct program that relies on the condition being false
  would then type from `X`.

## Decision

The second option. The module records a `[ENVELOPE_HOOK_EXTEND_OPEN_KIND, hook]` entry for such an extend, beside the
named entry when the argument is a constant, so `call.undefined-method`'s macro reader keeps the #2975 reading. A
class-object `def` in the includer's own body still answers, since the hook's module sits after it. ADR-119's rule is
that an unknown fact makes a read decline, not answer.

## To undo

Drop `record_hook_extend_open` and its callers in `lib/rigor/inference/scope_indexer.rb`, the `:include_hook` mark in
`Builder#singleton_mixins`, and the `hook_open_nodes` check in `ExpressionTyper#dynamic_singleton_definer_ahead?`.
