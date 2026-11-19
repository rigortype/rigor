# #3345 is answered as the call-typing ladder: the per-node typers get no seam, and two rung moves are dropped

- **PR:** [#3360](https://github.com/rigortype/rigor/pull/3360)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** scope
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-19

## Background

#3345 is titled "Redesign ExpressionTyper's per-node typers around one dispatch ladder (ADR-116 WD12)". Its title
and its design question point at different code. The per-node typers are the `type_of_*` methods that `type_of`
reaches through the `PRISM_DISPATCH` table. Three modules of them (`LeafNodes`, `Constants`, `ControlFlow`) were
moved out in #3319 and moved back, and the issue says they "need a different seam, not a move". The design question
is WD12's: declare the dispatch tier order in one place, including the tiers that run from
`ExpressionTyper#call_result_type_for`. That is the code that types a call, not the per-node typers.

ADR-116 asks a design slice to amend the ADR with its interface before code moves. Writing that amendment meant
deciding which of the two #3345 delivers and what happens to the other. A design consult measured both on `master`
`bc791f6d9`, and an independent critique checked it. The same amendment lists the slices that move a rung's body out
of the typer, and each candidate was judged by the test #3319's review applied: a module must hide more than its
interface exposes.

The amendment reverses nothing Accepted in ADR-116. It adds the interface the ADR's own rule asks for.

## Options and trade-offs

For the scope:

- **A seam for the per-node typers as well.** The table's values would change from method names to module functions.
  That removes the one-line delegators #3319's review objected to and keeps every entry. The rows are the interface,
  and each row hides one short body: `LeafNodes` was 29 entries for 30 methods. Any second hop per node is paid on
  `type_of`, which ran 3,682,018 times in one check of `lib/rigor/inference`. Nothing drifts today that a declaration would fix.
  `PRISM_DISPATCH` is 136 rows naming 60 handlers in one place, and 2 of the 113 merges that touched the file in two
  months changed a row. `Constants` and `ControlFlow` went back because of the callbacks they needed, and a different
  table shape does not remove those.
- **The call-typing ladder only.** The order a call is typed in is written out three times in the typer, and the
  copies have drifted (#3358). One table and a spec that holds the code to it end that, and the rungs behind single
  entries can then leave the file. The cost is that the title's promise is not met. The 52 methods of the three
  modules #3319 moved back stay in the class with no seam planned, and the per-node typers' part of the file took 16
  of the 113 merges.
- **Wait for #3344.** The issue says to reuse #3344's answer on how the evaluator's state divides into values, if
  that comes first. Waiting leaves the copied order drifting, in a file 8 lines under its budget, for a design with
  no date.

For the rung moves, the design listed seven slices. Two fit badly:

- `DynamicReceiver` with `NonNilRetry` (slice S3): 3 methods and 28 code lines, and the move makes
  `call_dispatch_type_for` public.
- `Unresolved` (slice S9): 6 methods and 71 code lines, and the move makes `fallback_for` public.

Moving them makes those rows modules like the rest. Leaving them means their three rows name a typer method, so "a
rung is one file and one row" has named exceptions. The counts are from a syntactic call graph, not from doing the
move.

## Decision

#3345 is answered as the call-typing ladder: the typer's rungs and the dispatcher's tier order. The per-node typers
get no seam. `PRISM_DISPATCH` stays as it is, and the three modules #3319 moved back stay in the class. Slices S3 and
S9 are dropped: those three rungs stay in the typer, and their rows in the table say why.

The precedent is ADR-116's own criteria as accepted on 2026-09-23. C1's test asks whether adding a member takes edits
in two or more files that each list the kind. For a per-node typer it does not, because the table is the one list. C3
says what leaves a file is a module with an interface, not the same class behind an indirection. S3 and S9 each make
a typer method public to hide a few dozen lines, the shape `Constants` had when it went back (two methods made public
to hide 20 lines). The fit is close on the criteria and loose on the instance. #3319 is the only earlier application
of that test to this class, and its entry is still in this queue, so it is not cited as the precedent.

The state rule in the amendment covers `ExpressionTyper` only, so #3344 is not decided here. The amendment is ADR-116
§ "Amendment, 2026-11-19 — WD12's interface (#3345)".

## To undo

Nothing but the ADR text depends on this yet, so before the slices land a revision edits the amendment's "Scope"
paragraph and its "Dropped" paragraph.

A seam for the per-node typers can be added later as its own issue. It would change `PRISM_DISPATCH`'s values and the
delegators, and no WD12 slice depends on its absence.

S3 or S9 can be taken later as an ordinary rung move: the body goes to a module under `call_ladder/`, its row names
the module, and one typer method becomes public. The amendment's "Dropped" paragraph would be changed in the same
pull request.
