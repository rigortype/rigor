# Each Table declares an entry protocol, and a writer logs before it stores or passes the value it replaced

- **PR:** [#2873](https://github.com/rigortype/rigor/pull/2873)
- **Issue:** [#2709](https://github.com/rigortype/rigor/issues/2709)
- **Class:** open-choice
- **Precedent:** [#2841](https://github.com/rigortype/rigor/pull/2841)
- **Decided:** 2026-11-06

## Background

ADR-129 stage 3 validates a stored entry's read slice and replays its write slice (WD3), and G1 compares the live
tables with their pre-computation state plus the replayed writes (WD5). The journal records `(op, slot, key, value)`,
but stage 2 gave `TypingState` no way to read or write one entry of an arbitrary Table: the stores differ (an identity
Hash, an `ObjectSpace::WeakKeyMap`, a recorder's accumulator, the return memo's two-level bucket, the dependency
recorder's split sets). G1 also needs the value a write replaced, and most writers logged after storing, when that
value is gone. ADR-129 says what is validated and replayed, not how a Table exposes its entries.

## Options and trade-offs

- **An entry protocol per Table** (`TypingState.table(…, entries:)`): a module answering `entry(store, key)`,
  `put(store, key, value)` and `container(state, slot)`, declared where the Table is, with a default for a store
  answering `fetch` and `[]=`. The knowledge of each store's shape stays with its owner; `State` stays generic.
- **Route every Table write through `State`** (`state.table_write(slot, store, key, value)`): one write path, but every
  production write then pays a protocol dispatch, and the set-only recorders' `add?` idiom has to be split apart.
- **Snapshot whole stores** before a compared computation: no protocol, but a copy of a file's advisory tables per
  would-be hit, which stage 0's harness avoided by hooking the writers.

For the replaced value: writers that can log before they store do so (the advisory `record_*`, the inject and loop
records, the return memo's store), and the set-only adds (dependency filings, self-call misses, a new effects
record), which log after `add?` decides, pass the replaced value as the log's `prior` (`ABSENT` by construction). A
priors window reads the entry only while it is open, so a production run pays one ivar check per logged write.

## Decision

The entry protocol, with log-before-store or an explicit `prior`. Stores in an index are compared by identity and
keys by `eql?`, which is identity for the Prism nodes most tables key on. `ReturnMemoEntries.container` and the
dependency protocol's `container` raise instead of inventing a store: a `type_of` memo entry lives inside one file's
analysis, so a replay into a missing return-memo bucket or into no recorder store would mean an entry outlived its run.

## To undo

Drop `entries:` and the protocol modules, route Table writes through `State` or snapshot stores instead, and restore
the log-after-store order at the four `Scope` writers, the inject and loop records and the return memo's store.
