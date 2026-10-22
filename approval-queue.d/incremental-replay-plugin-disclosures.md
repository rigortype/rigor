# Replay run-scoped plugin rows per file, and refresh a stale key through one registering file

- **PR:** [#2268](https://github.com/rigortype/rigor/pull/2268)
- **Issue:** [#2020](https://github.com/rigortype/rigor/issues/2020)
- **Class:** open-choice
- **Precedent:** [#1553](https://github.com/rigortype/rigor/issues/1553)
- **Decided:** 2026-10-22

## Background

An `--incremental` recheck that analysed no file dropped every `disclose_once` / `emit_once` row a plugin registered from its per-file hook. The issue asked for the rows to be replayed, and the brief required a replayed row to go stale once its input is fixed. The issue did not say how replayed rows are kept or what invalidates them. Every in-tree discloser memoises its input, so a plugin read is credited to the first file that triggers it, and a read in `#prepare` is credited to no file.

## Options and trade-offs

- Replay one run-level set from the snapshot whenever the closure is empty, and trust the fresh set otherwise. This loses a row that a single file registers whenever another file is edited. It also has no way to go stale when the input changes outside every file's reads.
- Re-run each plugin's hook on a recheck. There is no run-scoped hook to call: the rows come from `diagnostics_for_file`, which needs a file, a scope and a tree.
- Attribute every registration, repeats included, to the file being analysed, replay the records of served files, and credit every registering file with the registering plugin's whole boundary. This was round 1. It costs too much: rigor-rails-i18n registers its view batch from every file, so one view edit re-analysed 400 of 400 files in an app with one i18n view row, against 1 of 400 on master.
- Attribute registrations per file as above, but keep the plugin's boundary rows per `[plugin id, key]` (taken). A key with a stale row re-analyses one live registering file (the first by path), and the key's replays are withheld for that run. Afterwards every other holder takes the record that file registered, or drops the key when it registered none.

## Decision

The last option. A row stays tied to the files whose analysis produced it, the way `plugin_reads` (#1553) ties reads, and an edit to an input costs one file per stale key instead of every registrant. The spec's view-edit example re-analyses one of three files where round 1 re-analysed all three.

The guarantee is bounded in two ways, both of which `docs/internal-spec/cache.md` § `plugin_disclosures` states:

- It covers only inputs read through the plugin's boundary. State a plugin carries across files (`@seen ||= …`) or an input it reads around the boundary (`ENV`, a direct `File.read`) can leave a replayed row that never clears. Both are ADR-2 contract misuse.
- It relies on a key being file-independent, which `disclose_once` asks of it. The unsound shape is a key whose registration depends both on an input the plugin read and on the registering file's own text, held by several files. When the input changes so that the one re-analysed holder stops registering the key while another holder still would, the key is dropped from that other holder until it is itself re-analysed. That is a missing row (say less), never a stale one. No in-tree plugin has this shape.

## To undo

To trade cost for that shape, make `RunDisclosureLedger#refreshers` return every live holder of a stale key instead of the first. To return to dropping the rows, revert the PR. That needs a SCHEMA bump.
