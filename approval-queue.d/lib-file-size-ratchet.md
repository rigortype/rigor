# Budget every lib/ file of 1,000+ lines in multiples of 100, not at its exact line count

- **PR:** [#3281](https://github.com/rigortype/rigor/pull/3281)
- **Issue:** [#1192](https://github.com/rigortype/rigor/issues/1192)
- **Class:** scope
- **Precedent:** none — sets one
- **Decided:** 2026-11-17

## Background

Issue #1192 asked for a line budget for every `lib/` file of 1,000+ lines. Its "Done when" states that
each budget equals the file's line count at the commit that lands the gate. This PR does not do that. It
records each budget as a multiple of 100 and lets the gate accept any multiple from the file's count up to
199 lines above it. The gate is `spec/docs/lib_file_budgets_spec.rb`, with rows in
`spec/docs/lib_file_budgets.yml`. The gate's shape follows ADR-97's index budgets, but ADR-97 budgets an
index count, not a line count, so nothing earlier sets the granularity.

The reason is churn. About 15 PRs a day merge to `master`, and 44% of `lib/`-touching PRs touch one of the
three largest budgeted files. With exact counts, two in-flight PRs that each add a line to the same file
edit the same row and conflict there, even when neither takes the file past anything.

## Options and trade-offs

- **Exact count (the issue's Done-when).** The budget is the file's `wc -l`. It is the most literal reading.
  It costs a conflict on the budget row for nearly every in-flight pair of PRs that touch one of the three
  largest files, and every edit to those files also edits the gate.
- **Bucket of 100, slack below 200 (chosen).** The row is a multiple of 100 that is at least the file's
  count and less than 200 above it. A row moves only when a file crosses a boundary, so most concurrent edits
  leave it alone. The cost: growth inside the current bucket is not gated. Right after a row is set to the
  smallest bucket, a file can grow by up to 99 lines with no message. After a shrink, a row can sit up to 199
  lines above its file until someone lowers it.
- **Bucket of 100, slack below 100.** The gate would accept only the smallest bucket that holds the file. A
  split then always moves its row into the bucket it lands in, so the whole gain of a split is held. The cost
  is a row edit whenever a shrink crosses a bucket boundary, which brings back some of the conflicts the
  bucket was meant to remove, and the growth inside a bucket stays ungated just the same.
- **No upper-slack rule.** The gate checks only that a file stays under its budget and that a file of 1,000+
  lines has a row. A split would then lower its row only when someone remembers to, and a file could sit far
  above its budget for years. This keeps the rows still but drops the split pressure the issue asked for
  ("a split lowers the budget of the file it came out of").

## Decision

Bucket of 100 with slack below 200, as the chosen option above. A bucket keeps a row still until a file crosses
a boundary, and the slack of 200 keeps a split from being forced to move its row on every shrink. A slack of 100 is the
alternative above; it holds the whole gain of a split at the cost of row edits on shrinks, and it is recorded here
for the maintainer to weigh at ratification. The class is `scope`. The
README's `scope` class names splitting, deferring or closing part of an issue; this entry narrows one Done-when
item instead of deferring it, so `scope` is the nearest fit rather than an exact one. No precedent fits the
granularity, so this entry sets one for bucketed line budgets.

## To undo

Change the gate to exact counts: each row becomes the file's `wc -l`, the multiple-of-100 check and the slack
check go, and the growth check stays. Regenerate the rows in `spec/docs/lib_file_budgets.yml` from `wc -l`, and
rewrite the examples in `spec/docs/lib_file_budgets_spec.rb` that pin the bucket messages. The ADR-116 WD0 bullet
describes the bucket and would need the same edit. To move to a slack of 100 instead, change `SLACK` in the gate
and the rule text in its header and in the ADR-116 WD0 bullet; the rows stay valid.
