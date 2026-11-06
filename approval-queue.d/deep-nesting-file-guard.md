# A file nested too deeply to analyse is contained to that file instead of making every walker iterative

- **PR:** [#2927](https://github.com/rigortype/rigor/pull/2927)
- **Issue:** [#2455](https://github.com/rigortype/rigor/issues/2455)
- **Class:** open-choice
- **Precedent:** [ADR-5](../docs/adr/5-robustness-principle.md)
- **Decided:** 2026-11-06

## Background

Several recursive walkers (`ScopeIndexer`, `ExpressionTyper`, the flow tracer) each overflow the VM stack at their own
nesting depth, and `SystemStackError` is not a `StandardError`, so it escaped every per-file rescue and aborted the
whole run with exit 70 and no report for any file.

## Options and trade-offs

Make every walker iterative: removes the limit, but touches dozens of walkers and costs allocations on the hot path.
Raise the VM stack or run on big-stack threads: moves the limit, leaves the abort. Contain the failure per file: keeps
the limit but bounds its blast radius to the one file.

## Decision

Contain it per file. The existing per-file crash row (`internal analyzer error`, `error` severity, which discards
that file's diagnostics) is reused, with a message saying the file is nested too deeply; the discovery pass skips such
a file. The language server is left as it was (an earlier revision contained it per document, but a second deep
re-parse of an on-disk file from discovery then killed the server with a signal; #2932 owns that). The exit status follows the row's severity
(1). A `SystemStackError` raised from C (no backtrace) is not contained, because the process cannot survive a second one;
it keeps the exit-70 abort. Discovery is all or nothing per file, so a deep file contributes nothing in any mode. The
row carries no overflow frame, and reads "nested too deeply" only above an AST depth of 500, else as a Rigor defect.

## To undo

Drop `SystemStackError` from the four rescues (`Runner#analyze_file_body`, `WorkerSession#analyze_body`, the two
`ScopeIndexer` discovery loops). Deep files then abort the run again.
