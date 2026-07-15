# ADR-90 — Target-library resolution from the analyzed project's bundle

Status: **Accepted, 2026-07-16.** Implemented: the ADR-39 isolation layer
(`lib/rigor/plugin/isolation.rb`) falls back to requiring a target library
from the analyzed project's bundler install tree when Rigor's own gem
environment does not carry it (WD1); the isolation worker's rescue
clauses are `::`-qualified so a failed require declines cleanly instead of
killing the worker (WD2, the EOFError regression); and `rigor plugins`
probes `Plugin::Inflector.available?` when an inflection-consuming plugin
is loaded, warning on silent degradation (WD3). Verified end-to-end
against a standalone `gem install rigortype` run on a Rails app both with
and without an installed project bundle.

Grounding: the 2026-07-16 standalone-install scenario run (a fresh
`GEM_HOME`, no Bundler context, `rigor check` on a Rails app), where
`rigor-activerecord` and `rigor-rails-routes` both degraded with
`Inflector::Unavailable: process isolation worker failed (EOFError)` on
every run while `rigor plugins` reported all plugins `[OK]`.

## Context

ADR-39 lets a plugin invoke its trusted target library's pure methods —
`Plugin::Inflector` calls the real `ActiveSupport::Inflector` and carries
**no approximation** (absence is silence, never a guess). The gemspec
comment placed the production activesupport dependency "on each plugin's
own gemspec", but per ADR-27 the bundled plugins ship **inside the
rigortype gem** and have no gemspec of their own; rigortype carries
activesupport only as a *development* dependency. So in **every standalone
install** (`gem install rigortype` into its own environment — ADR-27's
primary distribution) ActiveSupport is absent and all inflection-dependent
Rails checking silently degrades. Maintainer environments mask this
because the repo's dev bundle includes activesupport — the scenario run
was the first time the tool was exercised the way a real user installs it.

Two aggravating defects surfaced with it:

- **The degradation was not even clean.** `Rigor::Plugin::LoadError` (the
  plugin-loading error, a StandardError defined in
  `lib/rigor/plugin/load_error.rb`) lexically shadows the global
  `LoadError` inside `Rigor::Plugin::Isolation`, so the worker loop's bare
  `rescue StandardError, LoadError` matched the wrong class; the real
  `::LoadError` (a ScriptError) escaped, killed the forked worker, and the
  parent saw only `worker failed (EOFError)`. A minimal `Isolation.call`
  repro outside `rigor check` returned the clean `[:error, …]` path —
  because it never loaded `rigor/plugin/load_error`, i.e. never armed the
  shadow.
- **The degradation was invisible.** `rigor plugins` reported `[OK]` for
  plugins whose inflection-dependent checks would produce no diagnostics.

## Decision

**Criterion: a target library is resolved with fidelity to what is
actually on disk, and its absence is a clean, visible decline — never a
guess, never a crash.** Concretely:

1. Resolution order is Rigor's own gem environment first, then the
   **analyzed project's bundler install tree**. A Rails project always
   carries its locked activesupport on disk, and the project's own copy is
   the *higher-fidelity* source of inflection rules (the ADR-79 principle
   applied to target libraries — check with what the project actually
   runs). ActiveSupport does **not** become a runtime dependency of
   rigortype: that would force Rails machinery on every non-Rails user
   (against the ADR-0 zero-runtime-dep ethos) and would check a Rails app
   with a potentially *different* ActiveSupport version than it runs.
2. When neither source resolves, every layer declines cleanly — the
   isolation worker replies `[:error, …]`, `Inflector` raises
   `Unavailable`, the plugin's rescue boundary degrades to no diagnostics
   — and the degradation is *reported* where the user configures plugins.

## Working decisions

- **WD1 — bundle fallback via `$LOAD_PATH` append of gemspec-declared
  require paths.** `Isolation.require_with_target_bundle` retries a failed
  require after appending every bundle gem's `full_require_paths` (loaded
  from the bundle's RubyGems-generated `specifications/*.gemspec`, newest
  version per name) to `$LOAD_PATH`. The gem's own metadata is what makes
  nonstandard require paths (concurrent-ruby's `lib/concurrent-ruby`)
  resolve; appending (never prepending) keeps Rigor's activated gems
  authoritative; retry-on-failure means a host environment that has the
  gem never consults the bundle. The bundle root rides each worker
  request, so under the default `process` strategy the mutation is
  confined to the forked worker — Rigor's main space is untouched. Under
  `none`/Direct it lands in the main space, which is that strategy's
  documented meaning (trusted + pure library).
- **WD2 — `::`-qualified rescues in the isolation layer.** The worker loop
  rescues `::StandardError, ::ScriptError` and Direct rescues
  `::LoadError, ::NameError`, so a failed require is a clean decline. The
  same shadowing bug was fixed in `rigor-rspec-rails`'s Rack status-table
  loader; `Plugin::Loader`'s bare `rescue LoadError` clauses *intend* the
  shadowed `Rigor::Plugin::LoadError` and are correct as-is (the real
  `::LoadError` is converted at its require site).
- **WD3 — activation-time visibility.** `Plugin::Inflector` gains
  `CONSUMER_PLUGIN_IDS` (the five bundled consumers); when `rigor plugins`
  loads any of them it resolves the bundle root (same
  `BundleSigDiscovery.resolve_bundle_path` the env build uses) and probes
  `Inflector.available?`. Text output warns with a concrete fix
  (`bundle install` the project, or install activesupport into Rigor's
  environment); `--format json` carries a structured
  `inflection: {required_by:, available:}` field (ADR-61: agents branch on
  fields, not message text).
- **WD4 — the bundle root is set before any plugin code runs.**
  Plugin `#prepare` hooks (the rails-routes parse, the activerecord model
  index) already invoke the inflector, and the runner's pre-passes run
  *before* `Environment.for_project` — so `ProjectPrePasses#run` resolves
  and sets `Isolation.target_bundle_root` first, and the
  `Environment.for_project` assignment (which also covers pool workers,
  whose env build precedes their per-worker prepare) keeps it fresh.

## Rejected alternatives

- **Promote activesupport to a runtime dependency** — forces it on
  non-Rails users and pins the checked inflection rules to Rigor's copy
  rather than the project's (fidelity loss; see Decision 1).
- **Vendor / approximate the inflector** — re-rejected; ADR-39's founding
  rationale (an approximation emits wrong facts → false positives).
- **`Gem.paths` augmentation** — the first implementation; rejected
  because a Bundler-locked process silently ignores it (the fallback would
  be dead under `bundle exec`), where the `$LOAD_PATH` append works in
  both worlds.
- **`Bundler.setup` against the analyzed project** — evaluates the
  project's `Gemfile` (arbitrary Ruby), which is executing application
  code (ADR-2 prohibition).
- **Down-grading to a doctor-only report without the fallback** — leaves
  the primary defect (silently dead Rails checking for every standalone
  user) in place; visibility complements the fix, it does not replace it.

## Consequences

- Standalone installs get working inflection-dependent Rails checking
  whenever the analyzed project's bundle is installed (`vendor/bundle`,
  `.bundle/config`, or the user-global bundler path — the
  `BundleSigDiscovery` auto-detect set). A project whose bundle is not
  installed degrades cleanly and visibly.
- The bundle may contain stale gem versions alongside locked ones; the
  fallback picks the newest per name rather than lockfile-pinning.
  Inflection rules are stable across ActiveSupport versions; exact-version
  provisioning stays deferred per ADR-39 ("only if a cross-version
  behavioural difference is observed").
- The fixture-backed isolation spec pins both the clean-decline contract
  (the shadowing regression) and the child-confined fallback (a
  nonstandard `require_paths` fixture gem).

## Relationship to other ADRs

Completes ADR-39's availability story for ADR-27's standalone
distribution; applies ADR-79's fidelity-over-pinning principle to target
libraries; the lock/bundle gating mirrors ADR-72's presence-gated overlay
reasoning; preserves ADR-2 (no application code execution — installed-gem
metadata and gem code only); the JSON probe field follows ADR-61's
structured-not-string rule.
