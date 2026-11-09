# A concern is a dependency only where its include follows the outer concern's own extend, and a reopening's include is not provable

- **PR:** [#2999](https://github.com/rigortype/rigor/pull/2999)
- **Issue:** [#2992](https://github.com/rigortype/rigor/issues/2992)
- **Class:** open-choice
- **Precedent:** [#2989](https://github.com/rigortype/rigor/pull/2989)
- **Decided:** 2026-11-09

## Background

Issue #2992 asks `call.undefined-method` to follow concern dependencies. ActiveSupport defers a concern only when it is
included into a module that has already run `extend ActiveSupport::Concern`. The final includer of the outer concern
then includes the dependency on its own edge. The dependency's `ClassMethods` and blocks reach that includer, and none
of them run in the outer concern. An `include` that runs before the outer concern's `extend` is an ordinary one. Its
hooks run in the outer concern, and the final includer gets none of the dependency's `ClassMethods`. Reading every
included concern as a dependency answered a class-side call wrongly on the ordinary layout (the review's `K.v` repro).
The discovery tables keep `include` order but not its position against the `extend`, nor the load order of two files.

## Options and trade-offs

- Treat a dependency's `ClassMethods` as unpositioned. This does not help: the unpositioned fork changes the order,
  not whether the module is there, so both worlds still answer from it.
- Record the position. Each constant of a receiverless `include` / `prepend` that is a direct statement of a module body
  after that body's own `extend ActiveSupport::Concern` gets a `[:concern_dependency, written]` entry. Only those are
  dependencies. This is exact for one body, but a reopening without the `extend` has no load order the walk can see.
- Also decline the reopening case: such an `include` is a dependency when its file loads after the `extend` and an
  ordinary one when it loads first.

## Decision

The second and third together. A concern names a dependency only through its `:concern_dependency` entries, and those
are read on the final includer's edge for both the singleton chain and the instance-side block read. The readers then
decline where the reopening's load order decides the answer:
- On the singleton side, a concern declared in two files that includes a concern no entry names marks its includer
  open (`:include_hook`), and the class-side read types `Dynamic`.
- On the instance side, a dependency's block is left out of the outer concern's own edge only when the outer concern is
  declared in one file. Otherwise both edges are read, and either silences.
This follows #2989's union-for-withholding reading of a concern's blocks, and the hook-open decline of #2996.

## To undo

Remove `ScopeIndexer#record_concern_dependencies` and `DiscoveryIndex::ENVELOPE_CONCERN_DEPENDENCY_KIND`, and have
`ResolutionChain.concern_dependencies` read the concern's include list again. That brings back the false positive the
review found. Dropping `Builder#uncertain_dependencies?` and the single-file test in
`CheckRules#deferred_dependencies` turns the reopening rows from declining into answering.
