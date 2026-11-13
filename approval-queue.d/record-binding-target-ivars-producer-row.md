# Record ScopeIndexer#record_binding_target_ivars in producers.yml as a census producer

- **PR:** [#3202](https://github.com/rigortype/rigor/pull/3202)
- **Issue:** [#1217](https://github.com/rigortype/rigor/issues/1217)
- **Class:** gate-row
- **Precedent:** [#3094](https://github.com/rigortype/rigor/pull/3094)
- **Decided:** 2026-11-13

## Background

The class-ivar census saw only write nodes, so an ivar a `rescue =>` reference or a `for` index writes (`rescue => @err`, `for @x in xs`) was missing from the class seed. A sibling method then read only the constructor's `@err = nil` and folded `if @err` always-falsey (#1217). The fix records those writes from `gather_ivar_writes` through a new method, `record_binding_target_ivars`. `spec/rigor/declaration_facts/producers_spec.rb` counts it as a declaration producer, because it writes a census table, so it failed until the method has a row.

## Options and trade-offs

- Inline the loop into the grandfathered `gather_ivar_writes`. No new row, but it grows a grandfathered method, and the gate exists to keep those from growing.
- Add one row with its reason. One entry a later reader checks, and the method's whole job is stated there.
- Move the census onto `DeclarationWalk::Context`. The ivar census has not been ported to `DeclarationWalk` yet, so that is a larger change than #1217 asks for.

## Decision

One row. Its reason says what the row allows: the method records each ivar a rescue reference or `for` index writes into the census of the class its caller passes in, typed by the clause's exception or the `Dynamic[top]` floor, and decides no owner or side of its own. #3094 added a row to the same file for a helper of the same kind.

**Unratified, and not by precedent (restored 2026-11-14).** The `Precedent:` field above names a PR
whose own approval-queue entry was still queued when this row landed, and
[`approval-queue.d/README.md`](README.md) says an entry still in the queue is not a precedent. So this
row named no valid precedent at the time, which by
[`contribution-flow.md`](../docs/agents/contribution-flow.md) § "Decisions and the approval queue"
makes it the serious case — ask the maintainer first — rather than a decision to land and record. It
landed anyway.

It was briefly deleted in #3230, which ratified the `gate-row` class in a batch; the maintainer asked
for the four entries in that position to come back, and this is one of them. #3094's own two entries
were both gone before that — one in #3228, one in #3230 — so for this row the chain did close there. The field keeps the PR it cited, because the queue's gate refuses
`none — sets one` on a `gate-row` by design — that value is what makes it serious — so there is no way
to spell "the precedent was not yet ratified" in the field itself. This note is that spelling.

What is being asked is therefore the row on its merits, not the chain: whether this classification is
right, independently of the row it followed.

Held rather than reverted, under ADR-123's 2026-11-14 amendment: the defect is in the record, and
the maintainer decides the row itself here. What was verified, and when: #3230's review read this
row's subject against the code — `ScopeIndexer#record_binding_target_ivars`, which calls
`accumulate_ivar_type` per name and so writes the census — and found the producer classification and
the row's stated reason correct.

## To undo

Delete the row and inline the method into `gather_ivar_writes`, or move it onto `DeclarationWalk` when the ivar census is ported there.
