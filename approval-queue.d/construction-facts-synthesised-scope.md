# Slice 1 of L3 leaves the each_with_object memo floors, the typed Set literal's floor and rewrite stamping alone

- **PR:** [#0000](https://github.com/rigortype/rigor/pull/0000)
- **Issue:** [#2534](https://github.com/rigortype/rigor/issues/2534)
- **Class:** scope
- **Precedent:** none — sets one
- **Decided:** 2026-11-02

## Background

The #2555 L3 design lists the `each_with_object` memo floor (PR #2415) and `RewriteMutation` results among the
places the `:synthesised` fact should reach, and #2534 names the typed `Set` literal floor (PR #2290) beside the
`SetMutation` floor.

## Options and trade-offs

- Lift the memo floors with the fact. They are not provenance floors: `memo_scan_reach` floors a memo the block hands
  to code no scan sees (`g = h`, `Helper.fill(h, x)`, `h.send(:store, …)`), and `memo_value_floor` floors a memo whose
  read value may be an element the block then mutates (`h[x] << "s"`). Knowing the memo was built by the engine says
  nothing about either, so lifting them would report on the #2415 false-positive shapes.
- Lift the typed `Set[...]` literal's floor. It sits in the type `SetFolding.typed_set` returns, not at a mutation
  seam, so removing it changes every read of such a literal (returns, ivars, sig-gen output), not only a mutated
  local.
- Stamp the result of a `RewriteMutation`. A declared carrier rewritten in place (`s = gets.to_s.split(",");
  s.map!(&:strip)`) is still the object the declaration described and may be aliased elsewhere; promoting it would
  cross the #561 boundary. A literal's own fact already survives the rewrite through `Scope#with_mutated_local`.
- Leave all three (taken).

## Decision

Leave them. #2534's "Done when" needs the Set example to report and the #2415 shapes to stay quiet: the
`SetMutation` floor is lifted for a synthesised Set, so `s = Set[1]; s << 2; s.to_a.first.upcase` reports, while
`s << "a"` reads `Set[Integer | String]` and stays silent under the diagnostic policy's multi-class-union rule, so
#2534 stays open for the coordinator.

## To undo

Nothing depends on the omission; a later slice can add any of the three behind the same fact.
