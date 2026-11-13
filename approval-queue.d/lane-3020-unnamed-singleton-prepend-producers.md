# ResolutionChain#unnamed_extend_nodes is listed in producers.yml as a consumer

- **PR:** [#3026](https://github.com/rigortype/rigor/pull/3026)
- **Issue:** [#3020](https://github.com/rigortype/rigor/issues/3020)
- **Class:** gate-row
- **Precedent:** [#3011](https://github.com/rigortype/rigor/pull/3011)
- **Decided:** 2026-11-10

## Background

Fix round 1 withholds a class-side definer behind a class object whose singleton side lists `"?"` (`extend(*MODS)`).
The new reader `Scope::ResolutionChain#unnamed_extend_nodes` picks the chain's `:extend` marks that list `"?"`, and
`spec/rigor/declaration_facts/producers_spec.rb` flags any method that spells a mixin side, so it needs a row.

## Options and trade-offs

- List it as a consumer, as #3011 listed `Builder#lists_unnamed?`, which reads the same marker.
- Fold the read into another listed method or spell the side without the symbol. That moves code to dodge the gate.

## Decision

List it as a consumer. It reads the marks of a built chain and writes no table.

**Unratified, and not by precedent (restored 2026-11-14).** The `Precedent:` field above names a PR
whose own approval-queue entry was still queued when this row landed, and
[`approval-queue.d/README.md`](README.md) says an entry still in the queue is not a precedent. So this
row named no valid precedent at the time, which by
[`contribution-flow.md`](../docs/agents/contribution-flow.md) § "Decisions and the approval queue"
makes it the serious case — ask the maintainer first — rather than a decision to land and record. It
landed anyway.

It was briefly deleted in #3230, which ratified the `gate-row` class in a batch; the maintainer asked
for the four entries in that position to come back, and this is one of them. For #3003 and #3011 the
chain did not close at #3230 either: each of those PRs still had an `open-choice` entry queued after it,
ratified only by the batch that restores this one. The field keeps the PR it cited, because the queue's gate refuses
`none — sets one` on a `gate-row` by design — that value is what makes it serious — so there is no way
to spell "the precedent was not yet ratified" in the field itself. This note is that spelling.

What is being asked is therefore the row on its merits, not the chain: whether this classification is
right, independently of the row it followed.

Held rather than reverted, under ADR-123's 2026-11-14 amendment: the defect is in the record, and
the maintainer decides the row itself here. What was verified, and when: #3230's review read this
row's subject against the code — `ResolutionChain#unnamed_extend_nodes`, a memoised
`@marks.filter_map { … }.freeze` read — and found the consumer classification correct.

## To undo

Delete the row when the method goes.
