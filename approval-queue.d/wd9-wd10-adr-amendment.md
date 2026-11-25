# #3346 is answered as `DeclarationWalk::Rules` plus collector moves inside `ScopeIndexer` that stop at a measured line; WD10 stays after WD2

- **PR:** [#3386](https://github.com/rigortype/rigor/pull/3386)
- **Issue:** [#3346](https://github.com/rigortype/rigor/issues/3346)
- **Class:** scope
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-25

## Background

#3346 asks for two of ADR-116's slices on `lib/rigor/inference/scope_indexer.rb` (13,704 lines): WD9,
the declaration-context rules move to the walk's side, and WD10, the file splits by responsibility
into the per-node scope index and a discovery namespace. ADR-116's WD5 amendment rule asks a design
slice to amend the ADR with its interface before code moves, and the coordinator brief on #3346,
written at the maintainer's request, asks for that amendment and an entry here as its own pull
request. Writing it meant deciding what the issue left open: what exactly leaves for WD9, whether
that module passes the deletion test #3319's review applied, what moves before WD2 (#1194), and
where the moves stop.

A design consult measured the file, an independent critique rebuilt the call graph and applied the
main slice to a scratch tree (byte-identical `rigor check` on the integration fixtures, the ratchet's
`Dynamic` call count unchanged), and the pull request's review recounted the closure.

**On the order.** ADR-116's "Order and procedure" step 3 is "WD9, then WD2, then WD10", and WD10
"follows WD2 and WD9". The amendment keeps that order for WD10 itself: the discovery namespace, the
fold and the codec wait for WD2. What it runs before WD2 are moves of whole collector clusters to
files under `scope_indexer/`, inside `ScopeIndexer`'s namespace. WD9's Accepted text names those as
what WD9 unblocks ("what lets the per-table clusters leave"), and #3311's `NodePropagation` is the
same shape, landed under the ADR. Two units (the declaration signature, the program-globals seed)
move ahead of WD9; they call no context rule and meet the rule "Landing point" applies, which that
section did not measure them against. The amendment adds a "Qualified" note there saying so.

## Options and trade-offs

For WD9:

- **Every function of the context-rule family, 51 `def`s and 36 public entries.** It includes 7
  helpers that the walk never reaches, each with one to four walker callers, so it adds 7 public
  entries for 50 lines.
- **The closure of the walk's six calls back into `ScopeIndexer`, 44 `def`s and 29 public
  entries.** It is the smallest unit that breaks the cycle. By ratio it fails the deletion test
  (about two thirds of the module is interface), so it is admitted on WD9's reason and on WD1's
  `ReceiverPredicates`, with a pin that its public list never grows.

For what runs before WD2:

- **Move the fold and the seed-bundle codec first.** Neither calls a context rule, and they are
  about 1,100 lines. But they are the code WD2 names, and WD2 replaces their hand-written slot lists
  by declarations, so the interface a move fixes is one WD2 rewrites.
- **Move only collector clusters, inside `ScopeIndexer`,** and leave the fold, the codec and the
  namespace change to WD2 and WD10.

For the end of the moves:

- **Commit to every cluster** (about 7,000 lines more), including a shared module of call-shape
  recognisers the larger clusters need. That module is 20 entries for 22 `def`s, the shape
  `LeafNodes` went back for.
- **Commit to the clusters that meet the #3318 cut-off now** (none or one call into what stays,
  and the shared-walk tables at five, which their slice must bring under the cut-off or leave), then
  re-measure and name every cluster left with its reason.

## Decision

The 44-`def` closure becomes `DeclarationWalk::Rules`; collector clusters move whole inside
`ScopeIndexer`'s namespace and stop after the class-variable census and the shared-walk tables,
followed by a re-measurement table; the fold, the codec and the discovery namespace stay WD2's and
WD10's. The precedent is ADR-116's own text: WD5's amendment rule, WD9's "what lets the per-table
clusters leave", step 3's order, the deletion test #3319 applied (its `LeafNodes`, `Constants` and
`ControlFlow` rejections), and #3311's `NodePropagation`.

Two parts a maintainer may read differently. `Rules` is admitted against the letter of the deletion
test; the alternative is to leave the cycle WD9 exists to remove. And collector moves run before
WD2; the alternative is to hold them until WD2 lands, which leaves #3346 at WD9 alone.

## To undo

Delete the amendment section, the "Qualified 2026-11-25" note under "Landing point", the sentence
naming the amendment in the Status header, the four rows it adds to the rejected table, and this
entry. No code has moved under it when this lands; each later slice cites the amendment, and undoing
it after those land means moving their code back or re-deciding the slice list.
