# A collection entry gives way to a signature_paths: root whose real path ends in its name and version

- **PR:** [#PR_NUMBER](https://github.com/rigortype/rigor/pull/PR_NUMBER)
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

- **Real path identity.** Drop the collection entry when its real path equals a `signature_paths:` root's real
  path. This catches the `local` source of `bin/test`, which symlinks the working tree in. It misses a `git`
  source, which installs a copy, so the author's edits and the copy would both load again.
- **Layout plus the lock entry (taken).** Drop the collection entry `<root>/<name>/<version>` when a
  `signature_paths:` root's real path ends in that `<name>/<version>`. This covers both the symlink and the
  copy, and needs no file read. A project `sig/` directory, or any root not laid out as `<name>/<version>`,
  never matches. The cost is a false match: a user root that happens to end in `<name>/<version>` of a locked
  gem, such as `vendor/sigs/foo/1.0` for a locked `foo` 1.0, would drop the collection copy of `foo`. That root
  almost certainly is a copy of `foo`'s signatures, and it still loads.
- **Content comparison.** Drop the entry when its files are byte-identical to the root's. This misses exactly
  the case that matters, an author's edited working tree, and costs a read of every file.

## Decision

Layout plus the lock entry. It is the least surprising rule. It matches what the gem_rbs_collection tree means
by `gems/<name>/<version>/`. It also follows #2978's precedent of keying a collection copy by the locked gem's
name and version rather than by its contents. The kept copy is the `signature_paths:` one, read whole, as the
issue's decision comment directs. The coverage classification still counts the dropped entry, so the gem is not
reported `:missing` and no ADR-72 overlay loads for it.

## To undo

Remove `RbsCollectionDiscovery.without_signature_path_copies` and its call in `Environment.for_project`. Both
copies then load again. The `_`-prefixed directory skip, (a) of the issue, does not depend on this decision.
