# A path gem's rbs collection entry is skipped when Rigor analyses that gem as project source through `paths:`

- **PR:** [#2573](https://github.com/rigortype/rigor/pull/2573)
- **Issue:** [#2441](https://github.com/rigortype/rigor/issues/2441)
- **Class:** open-choice
- **Precedent:** [#2424](https://github.com/rigortype/rigor/pull/2424)
- **Decided:** 2026-11-01

## Background

`rbs collection install` resolves the project's own `Gemfile.lock` and fetches community RBS for
`PATH`-sourced gems. On rails those are the framework gems under analysis (`actionpack`,
`activesupport`, …), so the collection copy collided with the project's `sig/` and 2398 classes
failed to build. Rigor had to decide which collection entries count as "the project's own code" and
stand down. The first version of the PR skipped any `PATH` gem under the project root. Review found
that this also dropped the collection RBS of a vendored third-party gem (`vendor/gems/foo`) that the
project does not analyse.

## Options and trade-offs

- **PATH gem under the project root.** Simple, but too wide. A vendored third-party path gem loses
  its community RBS, and calls into it go quiet.
- **PATH gem analysed as project source via `paths:`.** The gem's directory is at or under a
  `paths:` entry, or contains one (rails: `paths:` lists `actionpack/lib`, and the gem is
  `actionpack`). This skips exactly the gems whose classes the project's own `sig/` describes. Cost:
  a project-own gem that `paths:` does not cover keeps the collision.
- **Per-member stand-down against project signatures, as #2424 does for plugin members.** Keeps
  every non-colliding collection member. It is wider and costlier: it plans every collection file
  against project declarations on every environment build. The collection's members for the
  project's own classes are not wanted in the first place.

## Decision

The `paths:` predicate. It follows #2424's principle: the project's own declaration wins over a
third-party copy. Because the whole gem is the project's own code, it applies that principle at gem
granularity rather than per member. The same gems are also not classified `:missing`, so they make
no ADR-72 overlay or WD9 missing-gem entry eligible. Revisit when a survey shows a project whose own
path gem sits outside `paths:`.

## To undo

Drop the `ProjectPathGems.names` term from the skip list in `Environment.for_project`, from
`missing_gems_and_overlay_paths` and from `DiagnosticAggregator#rbs_coverage_diagnostics`. The
`paths:` keyword in `ProjectEnvironment.dependency_discovery_options` exists only for this.
