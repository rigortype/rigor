# A silent arity verdict files the mark edge only for chain levels that are the project's on a mark alone

- **PR:** [#2136](https://github.com/rigortype/rigor/pull/2136)
- **Issue:** [#1833](https://github.com/rigortype/rigor/issues/1833)
- **Class:** open-choice
- **Precedent:** none — sets one
- **Decided:** 2026-10-19

## Background

#1833 asked that every reader of a class mark record the `mark:<last segment>` key, so that a file
adding or dropping only a mark re-checks its consumers under `--incremental`. #2089 did this for
the readers that go through `Scope#parameter_envelopes_of`. What remained was the `:arity`
resolver in `Scope::ResolutionChain` and `SourceArity#project_class?`, which read the envelope
table directly through `DiscoveryIndex.declares_surface?`. A marks-only file such as
`module N; Foo.send(:define_method, :zz) { }; end` makes the resolver pick the mark-only `N::Foo`
over the declared `Foo`, the chain truncates, and `SourceArity` stays silent. That silent verdict
recorded no edge to the mark, so removing the mark file left a warm run silent where a cold run
reports `call.wrong-arity`. Following the issue literally turned out to over-invalidate, so the
issue's design needed a reading it did not give.

## Options and trade-offs

- **Route both `declares_surface?` reads through `parameter_envelopes_of`** (the issue's wording).
  Their reads happen inside `SourceArity`'s `DependencyRecorder.withhold` window and are dropped on
  a silent verdict, so this alone fixes nothing; with a replay it re-checks correctly-fitting calls
  on unrelated mark edits. CI failed `unrecordable_mixin_incremental_spec.rb:128,178` and
  `external_hook_incremental_spec.rb:118`.
- **Replay every withheld `mark:` read on a silent verdict.** Fixes the case, but a module
  declaration records the module mark, so `module Admin; module Comparable; end; end` fires
  `mark:Comparable` and re-checks every call whose walk read `Comparable`. CI failed
  `unsettled_chain_incremental_spec.rb:77`.
- **On a silent verdict, file `mark:<last segment>` only for each class or mixin of the walked
  levels (up to the owner) that is not a known user class and whose bucket alone
  `declares_surface?`.** Only such a level depends on its mark, and no `def` appearing or vanishing
  can overturn it. Keeps every precision spec; the cost is that the two direct reads stay direct,
  so the binding spec names `settle_by_definitions` as where the dependency is kept.

## Decision

The third option. It fixes every namespace-candidate shape the delta review probed (53 shapes, both
directions, `--workers 0` and `2`: dynamic, removed-name, `undef_method`, two-deep nesting, mixin
levels through include, extend, prepend and transitive include, singleton side) with no
over-invalidation beyond master. The one residual re-check is a namespaced `module Admin; module
Foo; end; end` while a mark-only `N::Foo` really is on the chain, which is the last-segment
granularity every `mark:` key already has. No earlier decision covers where a withheld read's
dependency is kept, so this sets a precedent.

## To undo

Revert the `@levels` loop in `SourceArity#settle_by_definitions` and its sentence in
`docs/internal-spec/inference-engine.md`; the two `class_mark_incremental_spec.rb` namespace-candidate
examples then fail in the "goes" direction. Nothing else depends on it.
