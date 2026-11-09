# A class-side definer at or behind a class object with an unnamed singleton prepend is withheld

- **PR:** [#3026](https://github.com/rigortype/rigor/pull/3026)
- **Issue:** [#3020](https://github.com/rigortype/rigor/issues/3020)
- **Class:** open-choice
- **Precedent:** [#3009](https://github.com/rigortype/rigor/pull/3009)
- **Decided:** 2026-11-09

## Background

`class << self; prepend(*MODS); end` and `singleton_class.prepend(*MODS)` put a module no table names ahead of the
class object's own `def self.` methods. #3011 lists the edge as the unnamed `"?"` marker on the singleton side, but that
marker is shared with `extend(*MODS)` and `class << self; include(*MODS)`, which sit behind the class object, so the
#2998 typing read could not tell the prepend apart and answered the own def. The brief asked to treat the unnamed
prepend as a `:prepend_order` region, and to add the prepend/extend distinction narrowly or decline.

## Options and trade-offs

- Reuse the `:prepend_order` mark. Its read withholds only definers inside the class object's prepend region, and the
  unnamed module has no entry there, so the own def would still answer. It would need a second meaning.
- Decline on every unnamed singleton mixin once the class has its own def. Simple, but it loses the own def past an
  unnamed `extend` or `include`, where Ruby answers it.
- File a `[ENVELOPE_SINGLETON_PREPEND_KIND, "?"]` entry for the prepend alone, give the class an `:unnamed_prepend`
  mark, and withhold any definer at or behind that class object's level: its own def and anything it inherits. A
  subclass's own `def self.` ahead of that level still answers.

## Decision

The third option. It separates prepend from extend and include at the walk that already sees the call kind, it
declines (the safe direction) only where the unnamed module could answer first, and a reopening that adds the prepend
diffs as the same singleton-prepend class mark #3009 already fires incremental edges on.

Fix round 1 extends the read to an unnamed `extend(*MODS)` or `class << self; include(*MODS)`: their module sits right
behind the class object's own singleton and ahead of its superclass's, so a definer behind the class object's own entry
is withheld and the own `def self.` still answers. It reads the `:extend` order mark listing `"?"` that #3011 already
gives such classes, and both checks now live in `ExpressionTyper#unnamed_singleton_mixin_split?`.

## To undo

Drop the `"?"` entry in `ScopeIndexer#record_own_singleton_prepend`, the `:unnamed_prepend` mark in
`ResolutionChain::Builder#own_singleton_prepends`, and `ExpressionTyper#unnamed_singleton_mixin_split?` (with `ResolutionChain#unnamed_extend_nodes`).
