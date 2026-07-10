# External-gem provenance: label the constant miss, not the dispatch

Design note, 2026-07-11. The GitLab plan's **P2 item 7**
([`20260708-gitlab-type-coverage-improvement-plan.md`](20260708-gitlab-type-coverage-improvement-plan.md)),
recorded as [ADR-82](../adr/82-dynamic-provenance-wiring.md) **WD9**.

## The finding this closes, and the correction to the plan

ADR-82's G2: `external_gem_without_rbs` fires on **zero** sites across three corpora, while GitLab's
lockfile holds 806 gems with no RBS. `coverage --protection` therefore tells a user that 99.4% of
their holes are `engine_gap` when a large share have the one answer a user can actually act on —
install or write RBS for a gem.

The plan's remedy — *"when a dispatch's receiver class is owned by an RBS-less locked gem
(`RbsCoverageReport` already knows the set), record the external-gem cause"* — is **mechanically
impossible**, and that is the load-bearing correction of this note. For a gem with no RBS, the
receiver never carries the class name: the constant read itself (`Faraday`) fails resolution
(`env.singleton_for_name` misses, `discovered_classes` misses) and widens to `Dynamic[top]` with the
generic `unsupported_syntax` cause at `ExpressionTyper#fallback_for`. By the time a dispatch sees the
receiver, the name is gone. The two dispatch tiers that do record this cause (project-patched /
dependency-source) require ADR-10 / `pre_eval:` opt-ins — which is exactly why the bucket measured
zero.

So the honest recording site is the **constant-resolution miss**. ADR-82 WD6's chain inheritance then
carries the cause through `Faraday.new.get(...)` with no further work.

## Sound ownership: read, never guess

The honesty criterion (ADR-82) forbids the obvious shortcut — camelizing the gem name
(`faraday` → `Faraday`) — and it is right to: the convention breaks exactly where it matters
(`activesupport` → `ActiveSupport`, `rack-attack` → `Rack::Attack`), and a wrong "add RBS for X" hint
wastes the user's time, the failure ADR-75 exists to avoid.

Instead, ownership is established by reading. For each locked gem classified `:missing` by
`RbsCoverageReport`:

1. Resolve its installed source root from RubyGems **metadata** (`Gem::Specification#full_gem_path`
   — no gem code loads; the same posture as ADR-72's "loads RBS data only" and the ADR-10 walker).
2. Parse its conventional entry file (`lib/<name>.rb`, plus the dash → directory variant) with Prism
   and record the **top-level** class / module / constant declarations under their root name. The
   entry-file path is the require-name convention `Bundler.require` itself depends on — a filename
   convention, not a constant-name guess; the constants come from the parse.

The result is a `root constant → gem` index (`"Faraday" → faraday`). At an unresolved constant whose
root name the index holds, record `EXTERNAL_GEM_WITHOUT_RBS`; otherwise keep today's generic cause.

**Everything fails open.** A gem that is not installed, an entry file that is absent or unparseable,
a root constant declared only in a deeper file, a project typo (`Farraday`) — all keep the generic
cause. The failure mode is a missing label, never a wrong one, which is what makes the bounded scan
acceptable: coverage can grow later (full-tree scan behind a per-gem-version cache) without any
soundness question.

### Known imprecision, accepted

A gem that declares a generic top-level constant (`module Util`) can claim ownership of a reference
the project meant for its own `Util` living in an **unanalyzed** path (analyzed project declarations
win earlier, at `discovered_classes`). Three reasons to accept rather than engineer around it: the
label is a side-channel hint and can fire no diagnostic; at runtime the two constants genuinely
collide and which wins is load-order-dependent; and the alternative (refusing any generic-looking
name) is itself a heuristic. Recorded here so it is not re-litigated.

## Cost

The index is built **lazily** on the first unresolved constant — a project whose constants all
resolve never pays — and the scan is bounded to entry files (one or two per gem), so paying it is
sub-second even at 806 gems. Under the fork pool each worker builds its own copy on first need;
at entry-file scale that is acceptable, and the escape hatch (build eagerly pre-fork, or cache per
gem-version) is recorded for when a profile demands it. `make bench-perf` is green (28.64 M
allocations against the 29.17 M ceiling).

## Gate

Precision-additive per the ADR-75 side-channel contract — no type, diagnostic, or severity change:
Redmine `app`+`lib` diagnostics are byte-identical. The functional gate is ADR-82 WD5-style
**re-bucketing measurement**: the cause distribution (`cause_site_counts`) before/after on a real
corpus, plus hand-adjudication of a sample of newly-labeled sites (is the constant really the gem's?).

**Results (Mastodon `app/models`, identical denominator):** 47 sites moved `unsupported_syntax` →
`external_gem_without_rbs`; every other bucket byte-stable (`none` 923, `inferred_return_untyped`
824, `explicit_untyped` 41). Every sampled labeled site adjudicated **correct**: all root at `I18n`
(`I18n.t` validation messages, `I18n.locale`, `I18n.available_locales`) — the i18n gem is locked,
ships no RBS, and its RBS exists in `gem_rbs_collection`, so the `add_rbs` routing is genuinely
actionable. The yield on `app/models` is small by construction (models are ActiveRecord-dominated,
and AR is plugin-typed); the gem-facade population lives in services / lib. GitLab `lib` measurement
recorded in the ADR-82 WD9 entry.
