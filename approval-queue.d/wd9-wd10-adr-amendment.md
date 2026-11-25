# #3346 is answered as `DeclarationWalk::Rules` plus collector moves that stop at a measured line, and the fold and the codec wait for WD2

- **PR:** [#3386](https://github.com/rigortype/rigor/pull/3386)
- **Issue:** [#3346](https://github.com/rigortype/rigor/issues/3346)
- **Class:** scope
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-25

## Background

#3346 asks for two of ADR-116's slices on `lib/rigor/inference/scope_indexer.rb` (13,704 lines): WD9,
the declaration-context rules move to the walk's side, and WD10, the file splits by responsibility
into the per-node scope index and a discovery namespace. ADR-116 asks a design slice to amend the ADR
with its interface before code moves. Writing that amendment meant deciding four things the issue
left open: what exactly leaves for WD9, whether that module passes the deletion test #3319's review
applied, how much of WD10 runs before WD2 (#1194), and where the collector moves stop.

A design consult measured the file, and an independent critique rebuilt the call graph and applied
the main slice to a scratch tree (byte-identical `rigor check` on the integration fixtures, the
ratchet's `Dynamic` call count unchanged). The amendment reverses nothing Accepted in ADR-116.

## Options and trade-offs

For WD9:

- **Every function of the context-rule family, 51 `def`s and 36 public entries.** It includes 7
  helpers that the walk never reaches, each with one to four walker callers, so it adds 7 public
  entries for 50 lines.
- **The closure of the walk's six calls back into `ScopeIndexer`, 44 `def`s and 29 public
  entries.** It is the smallest unit that breaks the cycle. By ratio it fails the deletion test
  (about two thirds of the module is interface), so it is admitted on WD9's reason and on WD1's
  `ReceiverPredicates` precedent, with a pin that its public list never grows.

For WD10's order:

- **Move the fold and the seed-bundle codec first.** Neither calls a context rule, and they are
  about 1,100 lines. But they are the code WD2 names, and WD2 replaces their hand-written slot lists
  by declarations, so the interface a move fixes is one WD2 rewrites.
- **Keep ADR-116's order (WD9, WD2, WD10) for them,** and move ahead only the two units WD2 does not
  touch (the declaration signature, the program-globals seed).

For the end of the collector moves:

- **Commit to every cluster** (about 7,000 lines more), including a shared module of call-shape
  recognisers the larger clusters need. That module is 20 entries for 22 `def`s, the shape `LeafNodes`
  went back for.
- **Commit to the clusters that meet the #3318 cut-off today** (none or one call into what stays,
  and the shared-walk tables at five, which their slice must bring under the cut-off or leave), then
  re-measure and decide the rest one at a time.

## Decision

The 44-`def` closure becomes `DeclarationWalk::Rules`; the fold and the codec wait for WD2; the
collector moves stop after the class-variable census and the shared-walk tables, and the rest is
decided after a re-measurement. The precedent is ADR-116's own: WD5's amendment rule, the deletion
test #3319's review applied (its `LeafNodes`, `Constants` and `ControlFlow` rejections), the
step-3 order "WD9, then WD2, then WD10", and the WD12 amendment (#3360), which likewise dropped the
slices that recreate a rejected shape.

`Rules` is admitted against the letter of the deletion test. That is the part a maintainer may read
differently: the alternative is to leave the cycle in place, which WD9 exists to remove.

## To undo

Delete the amendment section and its four rows in the rejected table, and this entry. No code has
moved under it at the time this lands; each later slice cites the amendment, and undoing it after
those land means moving their code back or re-deciding the slice list.
