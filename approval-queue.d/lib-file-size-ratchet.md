# Budget every lib/ file of 1,000+ lines in multiples of 100, not at its exact line count

- **PR:** [#3281](https://github.com/rigortype/rigor/pull/3281)
- **Issue:** [#1192](https://github.com/rigortype/rigor/issues/1192)
- **Class:** open-choice
- **Precedent:** [ADR-97](../docs/adr/97-adr-index-budgets.md)
- **Decided:** 2026-11-17

## Background

Issue #1192 asked for a line budget for every `lib/` file of 1,000+ lines, and its "Done when" said each
budget equals the file's line count at the commit that lands the gate. ADR-116 WD0 makes that gate the
control on file growth before the ADR-116 splits shrink the files. The gate is `spec/docs/lib_file_budgets_spec.rb`,
in the shape of ADR-97's index budgets, with rows in `spec/docs/lib_file_budgets.yml`.

An exact count works on paper, but the files it budgets change daily. About 15 PRs a day merge to `master`,
and 44% of `lib/`-touching PRs touch one of the three largest budgeted files. With exact counts, two
in-flight PRs that each add a line to the same file edit the same row, and one of them conflicts with the
other even when neither takes the file past anything. The issue's wording left the granularity open in
practice, so the choice of granularity was a decision nobody had made.

## Options and trade-offs

- **Exact count (the issue's wording).** The budget is the file's `wc -l`. It is the most literal reading.
  It costs a conflict on the budget row for nearly every in-flight pair of PRs that touch one of the three
  largest files, and it makes every edit to those files also an edit to the gate.
- **Bucket of 100 with a 200-line slack (chosen).** The budget is the smallest multiple of 100 at or
  above the count, and the gate fails when the budget is 200 or more above the file, so a split must lower
  it. A row moves only when a file crosses a boundary, so most concurrent edits leave it alone. The cost is
  that growth inside the bucket is not reviewed: a file can grow by up to 99 lines with no gate message.
- **No upper-slack rule.** The gate checks only that a file stays under its budget and that a file over
  1,000 lines has a row. A split would then lower its row only when someone remembers to, and a file could
  sit 1,000 lines above its budget for years. This keeps the rows still but drops the split pressure that
  the issue asked for ("a split lowers the budget of the file it came out of").

## Decision

The bucket of 100 with a 200-line slack, with the upper-slack rule kept. The issue asked for growth to be
a decision, and a bucket keeps that decision at the boundary without making every edit a conflict. The
precedent is ADR-97's budget gate, which is also a checked-in number per file, a failure that names the
fix, and examples that prove the failure. The precedent fits the gate's shape and not its granularity:
ADR-97 budgets an index count, not a line count, so this entry sets the precedent for bucketed budgets.

## To undo

Change the gate to exact counts: each row's budget becomes the file's `wc -l`, the "not a multiple of 100"
check and the 200-line slack check go, and the growth check stays. The rows in `spec/docs/lib_file_budgets.yml`
are regenerated from `wc -l`, which is a one-line change per file, and the examples in
`spec/docs/lib_file_budgets_spec.rb` that pin the bucket messages are rewritten to match. Nothing else depends
on the bucket: the ADR-116 WD0 bullet describes it in one place, and it would need the same edit.
