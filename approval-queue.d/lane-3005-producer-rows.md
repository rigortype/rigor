# Two new producers.yml rows for the concern reader, and the grandfathered pin lowered by one

- **PR:** [#3014](https://github.com/rigortype/rigor/pull/3014)
- **Issue:** [#3005](https://github.com/rigortype/rigor/issues/3005)
- **Class:** gate-row
- **Precedent:** [#3003](https://github.com/rigortype/rigor/pull/3003)
- **Decided:** 2026-11-09

## Background

The declaration-producers tripwire (`spec/rigor/declaration_facts/producers.yml`, ADR-119 WD6) flags two methods
#3005 adds:

- `ScopeIndexer#record_hook_block_singleton_defs`, which files a concern block's `def self.x` on
  `Owner::<included>`;
- `SyntheticMethodScanner#concern_extend_arguments`, split out of `concern_module_body?` to read the `self.extend` and
  `send(:extend, …)` spellings.

Once that check moved out, `concern_module_body?` is no longer a producer, and its grandfathered row went with it.
The `record_concern_class_methods` row gained a clause saying its hook blocks are read in every body.

## Options and trade-offs

- Add the rows with reasons, delete the stale grandfathered row, and set `grandfathered_pin` to the count and
  digest the spec reports (366). The spec's message names this as the review point for a removed grandfathered
  entry.
- Keep the extend check inline in `concern_module_body?` so that its row stays. The code would take that shape
  only to satisfy the gate.

## Decision

The first option. #3003 (rows for the hook recorders) and `c579f8015` (the pin lowered when a grandfathered entry
went) are the precedents.

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

The entry was restored rather than the rows reverted, under [ADR-123's 2026-11-14 amendment](../docs/adr/123-merge-queue-and-post-hoc-approval.md). What was read, and by whom: both
rows were read against the code on 2026-11-14 by the session that restored this entry —
`ScopeIndexer#record_hook_block_singleton_defs`, which files declarations and is recorded as a
producer with its reason, and `SyntheticMethodScanner#concern_extend_arguments`, which reads one
statement's shape and returns module names or nil. The grandfathered row that went with them was
`concern_module_body?`, and the pin moved 367 → 366 in `c5c93faaa`, which is the tightening
direction. #3230's review reported reading five of that batch's sixteen entries' classifications and
named none of them, so nothing here rests on it.

## To undo

Delete the two rows and restore the `concern_module_body?` row and the 367 pin, together with the code.
