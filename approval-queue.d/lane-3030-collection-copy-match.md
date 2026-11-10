# A collection entry gives way to a signature_paths: root that is its real path or its gems/<name>/<version> tree

- **PR:** [#3043](https://github.com/rigortype/rigor/pull/3043)
- **Issue:** [#3030](https://github.com/rigortype/rigor/issues/3030)
- **Class:** open-choice
- **Precedent:** [#2978](https://github.com/rigortype/rigor/issues/2978)
- **Decided:** 2026-11-10

## Background

Issue #3030 (b): in a gem_rbs_collection `_test/` directory, an author who sets `signature_paths: [".."]` loads
the gem from the working tree `gems/<name>/<version>/`, and the `rbs_collection.lock.yaml` written by the
`bin/test` setup loads the same gem again from `.gem_rbs_collection/<name>/<version>/`. Every member is
declared twice, and on actionmailer 8.1 seven classes failed to build. The issue's decision comment says to load
only one copy and to keep the `signature_paths:` one. It left open how to tell that the two are the same gem and
version.

## Options and trade-offs

- **Real path identity alone.** Drop the collection entry when its real path equals a `signature_paths:` root's
  real path. This catches the `local` source of `bin/test`, which symlinks the working tree in. It misses a `git`
  source, which installs a copy, so the author's edits and the copy would both load again.
- **Any `<name>/<version>` suffix.** Drop the entry when a root's real path ends in its `<name>/<version>`. This
  covers the copy too, but it also matches a partial override such as `sig/overrides/foo/1.0`. Dropping the
  whole collection copy there loses every member the override does not declare: `Foo.new.a` then reports an
  undefined method. Review of the first head found this.
- **Real path identity, or the gem_rbs_collection layout (taken).** Drop the entry when its real path is a root's
  real path, or when a root's real path is `.../gems/<name>/<version>` for the entry's name and version. This
  covers the symlink and the copy of an author's working tree, needs no file read, and leaves any other
  `<name>/<version>` root (a partial override) beside the collection copy. The remaining false match is a root
  that sits in some unrelated `gems/<name>/<version>` directory for a locked gem; such a directory almost
  certainly holds that gem's signatures, and it still loads.
- **Content comparison.** Drop the entry when its files are byte-identical to the root's. This misses exactly
  the case that matters, an author's edited working tree, and costs a read of every file.

## Decision

Real path identity, or the gem_rbs_collection layout. It is the least surprising rule. It matches what the
gem_rbs_collection tree means by `gems/<name>/<version>/`, and it never drops a copy for a directory that only
adds to the gem. It also follows #2978's precedent of keying a collection copy by the locked gem's name and
version rather than by its contents. The kept copy is the `signature_paths:` one, read whole, as the issue's
decision comment directs. The coverage classification still counts the dropped entry, so the gem is not reported
`:missing` and no ADR-72 overlay loads for it.

## To undo

Remove `RbsCollectionDiscovery.without_signature_path_copies` and its call in `Environment.for_project`. Both
copies then load again. The `_`-prefixed directory skip, (a) of the issue, does not depend on this decision.
