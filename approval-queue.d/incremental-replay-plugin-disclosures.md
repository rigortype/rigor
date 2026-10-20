# Replay run-scoped plugin rows per file, and credit each registering file with the plugin's reads

- **PR:** [#2268](https://github.com/rigortype/rigor/pull/2268)
- **Issue:** [#2020](https://github.com/rigortype/rigor/issues/2020)
- **Class:** open-choice
- **Precedent:** [#1553](https://github.com/rigortype/rigor/issues/1553)
- **Decided:** 2026-10-21

## Background

An `--incremental` recheck that analysed no file dropped every `disclose_once` / `emit_once` row a plugin registered from its per-file hook. The issue asked for the rows to be replayed, and the brief required a replayed row to go stale once its input is fixed. The issue did not say how replayed rows are kept or what invalidates them. Every in-tree discloser memoises its input, so a plugin read is credited to the first file that triggers it, and a read in `#prepare` is credited to no file.

## Options and trade-offs

- Replay one run-level set from the snapshot whenever the closure is empty, and trust the fresh set otherwise. This is simple, but it loses a row a single file registers whenever another file is edited, and nothing makes the replay go stale when the input changes outside every file's reads.
- Re-run each plugin's hook on a recheck. There is no run-scoped hook to call: the rows come from `diagnostics_for_file`, which needs a file, a scope and a tree.
- Attribute every registration (repeats included) to the file being analysed, replay the records of served files, and credit each registering file with the registering plugin's whole boundary, `#prepare`'s reads included (taken).

## Decision

The third option. It keeps a row tied to the files whose analysis produced it, the way `plugin_reads` (#1553) keeps reads, and the boundary credit means a change to any input the plugin read re-analyses every registering file. No replayed row outlives its input. The cost is over-invalidation: while a plugin keeps a row registered, an edit to any file it read (a view template, another locale file) re-analyses every file that registered the row. On a project with no registered rows nothing extra is credited.

## To undo

Drop the boundary credit in `Analysis::RunDisclosureCredit.credit` to credit only what each file read. A replay would then stay stale after its input is fixed whenever the read was memoised or made in `#prepare`; the spec's fix examples fail. Reverting the whole change returns to dropping the rows and needs a SCHEMA bump.
