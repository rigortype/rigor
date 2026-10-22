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
- Attribute registrations per file as above, but keep the plugin's boundary rows per `[plugin id, key]` (taken). A key with a stale row re-analyses one live registering file (the first by path, never a removed one), and the key's replays are withheld for that run. When that file registers the key, every other holder takes its record. When it registers nothing (an edit took the notice out of its text, the file no longer parses, the plugin raised), the closure runs a second time with every other live holder added, and the key is dropped only if none of them registers it. Round 2 trusted the chosen file. Review found the rails-i18n view batch vanishing when that file had a syntax error in the same edit as a view.

## Decision

The last option. A row stays tied to the files whose analysis produced it, the way `plugin_reads` (#1553) ties reads, and an edit to an input costs one file per stale key instead of every registrant. The spec's view-edit example re-analyses one of three files where round 1 re-analysed all three.

The guarantee is bounded in two ways, both of which `docs/internal-spec/cache.md` § `plugin_disclosures` states:

- It covers only inputs read through the plugin's boundary. State a plugin carries across files (`@seen ||= …`) or an input it reads around the boundary (`ENV`, a direct `File.read`) can leave a replayed row that never clears. Both are ADR-2 contract misuse.
- One shape stays unsound: a key whose registration or record depends both on an input the plugin read and on the registering file's own text. When the input changes and the chosen file still registers the key, the other holders take its record even where, re-analysed, they would register another record or none, until each is re-analysed itself. `disclose_once` asks a key not to vary between workers, which rules this out for a plugin that keeps the contract, and no in-tree plugin has the shape. A key that depends only on the file's text is settled by the second pass.

## To undo

To trade cost for that shape, make `RunDisclosureLedger#refreshers` return every live holder of a stale key instead of the first; the second pass then never runs. To return to dropping the rows, revert the PR. That needs a SCHEMA bump.
