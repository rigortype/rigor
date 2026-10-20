# Let editor --tmp-file runs pay the project discovery a plain rigor check FILE pays

- **PR:** [#2188](https://github.com/rigortype/rigor/pull/2188)
- **Issue:** [#2165](https://github.com/rigortype/rigor/issues/2165)
- **Class:** open-choice
- **Precedent:** [#1583](https://github.com/rigortype/rigor/issues/1583)
- **Decided:** 2026-10-20

## Background

`rigor check --tmp-file T --instead-of F F` discovered only the buffer's file, so it reported false positives on code whose classes live in other files (#2165). Widening its discovery to the configured paths, as a plain `rigor check F` already does, fixes that. The cost is that each invocation walks the project. On Rigor's own `lib` (599 files), the review measured 0.57s before and 2.55s after with `--no-cache`, and about the same with the cache, which does not reuse seed bundles in buffer mode.

## Options and trade-offs

- **Widen like a plain run (taken).** The answer matches `rigor check F`, and the cost matches it too.
- **Keep the buffer-only discovery.** Fast, but it reports on correct code whenever a superclass, a callee or an arity lives in another file.
- **Seed the run from cached discovery bundles** (`Protection::DiscoverySeed.tables_for_buffer`, as the LSP publish does under ADR-124). This could recover most of the cost. It is a separate change to the buffer-mode runner and its cache, left for later.

## Decision

Widen. The case follows #1583, which made `analyze_only` subset runs widen discovery like a full run for the same reason: a run over a file argument must see the project that file is checked against. A slower but correct editor answer outranks a fast one that reports on correct code (ADR-5).

## To undo

Restore the `@buffer.nil?` condition in `Runner#widen_discovery_to_project?` and drop `Runner#buffer_spelled`. The false positives of #2165 return.
