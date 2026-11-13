# Four ScopeIndexer helpers of the computed-send reading are listed in producers.yml

- **PR:** [#3021](https://github.com/rigortype/rigor/pull/3021)
- **Issue:** [#3006](https://github.com/rigortype/rigor/issues/3006)
- **Class:** gate-row
- **Precedent:** [#3011](https://github.com/rigortype/rigor/pull/3011)
- **Decided:** 2026-11-09

## Background

`spec/rigor/declaration_facts/producers_spec.rb` flags a method that reads a constant built from a mixin name or
appends to a list. The two new helpers that read a computed `send` name trip it: `literal_send_name` reads
`MIXIN_KINDS`, and `collect_local_send_names` reads `LOCAL_SCOPE_BOUNDARIES` and appends the literals it finds.

## Options and trade-offs

- List both as consumers, as #3011 listed `unnamed_singleton_include?`, which reads a call's name and arguments.
- Restructure them to dodge the scanner, which moves code to pass a gate.

## Decision

List both as consumers. Each reads a call's or a local's literal names and writes no table and derives no owner or
side; the side is decided by `taint_computed_mixin_send`, which the scanner does not flag.

Review round 1 adds `taint_computed_mixin_send` and `taint_computed_hook_send`, which the scanner flags for spelling
`:include`. Each taints the side its caller names on the owner the walk passes in, as `taint_unrecorded_mixin` (listed
for #2991) does, and derives no declaration context, so each is listed with that reason.

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

The entry was restored rather than the rows reverted, under
[ADR-123's 2026-11-14 amendment](../docs/adr/123-merge-queue-and-post-hoc-approval.md).
What was read, and by whom: two
of the four rows were read against the code on 2026-11-14 by the session that restored this entry.
`ScopeIndexer#taint_computed_hook_send` takes the owner and the sides from its caller and only
taints; `#taint_computed_mixin_send` takes the owner from its caller and derives the sides itself
(`in_singleton ? [side, :include] : [side]`, the instance side a `class << self` body keeps), which
is what its row's reason says. Both match the shape of the `#taint_unrecorded_mixin` row ratified in
#3230. The other two rows were not read. #3230's review reported reading five of that batch's sixteen
entries' classifications and named none of them, so nothing here rests on it.

## To undo

Delete the four rows when the helpers go.
