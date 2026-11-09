# A class that mixes in a module no table names opens its class object's existence read, not only its typing read

- **PR:** [#3011](https://github.com/rigortype/rigor/pull/3011)
- **Issue:** [#2994](https://github.com/rigortype/rigor/issues/2994)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-11-09

## Background

Issue #2994 (second comment) asks that a class whose instance side carries the `"?"` marker (`include(*MODS)`, #2993)
give its class object the `:include_hook` open mark from #2996, so that `K.bar` declines instead of answering the
superclass's `bar`: the `included` hook of a module in the splat runs with `K` as `base` and may extend it. #2996 defined
that mark to list `"*"` and `"?"`, which makes `ResolutionChain#wildcard_mixin?` true on the singleton chain, and
`call.undefined-method`'s class-object read (`RbsReceiverSurface.extends_answer?`) opens on it. #2993 had a row pinning
the opposite: `Sup.m1` on a class with `include(*MODS)` reports. The brief asked both for the mark and for every #2993
row to stay green, and the two cannot both hold with #2996's mark.

## Options and trade-offs

- Give the class object #2996's mark as it is. Its existence read opens, so `Sup.m1` no longer reports. A splatted
  module whose hook extends the class with `m1` is no longer a false positive; a splat of hookless modules loses a
  true report.
- Give it a mark of the same kind that lists nothing, or `"?"` alone. Only the typing read (`hook_open_nodes`) would
  decline, and the #2993 row stays green. The existence read would still report a name a hook may add, which is the
  false positive the mark exists to prevent, and the mark would break the documented rule that every `"?"` mark is a
  `"*"` one.
- Look into the splat's modules for hooks. The splat is not resolved to its modules, so this needs constant-value
  tracking the issue does not ask for.

## Decision

The first. False positives outrank lost reports (AGENTS.md), and the class object is then read the same way #2996
reads a hook it cannot place. The #2993 row is rewritten to stay quiet, and a new row keeps the report for a hookless
literal include. The mark is also given when a module the class includes lists `"?"` on its own instance side. The second case also covers that module's own
`include(*MODS)`, whose hooks run with the module as `base`, not the class. That over-approximation only declines.

## To undo

In `ResolutionChain::Builder#singleton_mixins`, drop `|| unnamed_instance_mixin?(name)`, or narrow
`#unnamed_instance_mixin?`. Restore the #2993 row's `eq(["undefined method `m1' for singleton(Sup)"])` and the
"class object does not open" sentence in `docs/type-specification/diagnostic-policy.md`.
