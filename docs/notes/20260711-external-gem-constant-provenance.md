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

1. Resolve its installed source root. **The primary resolver is the target project's own bundle**
   (`<bundle>/ruby/*/gems/<name>-<version>/`, the pure-filesystem layout `BundleSigDiscovery`
   already walks — no `Bundler` API, no gem code). This is load-bearing: rigor runs under *its own*
   bundle (`BUNDLE_GEMFILE=<rigor>/Gemfile`), so `Gem::Specification.find_by_name` sees rigor's
   gems, not the target's — it would resolve only the handful of gems both bundles share and miss
   every project-specific gem, the very ones a Rails app's holes root at. `Gem::Specification`
   remains a last-resort **fallback** for a project with no discoverable bundle (see the coverage
   note below).
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

## Coverage depends on how the target installed its gems

The label lands only where rigor can *read* the gem's entry file, and that varies by install layout:

- **A `vendor/bundle` / `BUNDLE_PATH` project** (the Docker / CI norm) — the primary resolver reads
  the target's actual gems, so **every** RBS-less gem is covered. This is the case the fix is built
  for.
- **A global-gems project** (`mise` / `rbenv` / system, no `vendor/bundle`) — the bundle resolver
  finds nothing (rigor cannot see the target's `GEM_PATH`, which is under a different Ruby), so
  coverage falls to the `Gem::Specification` fallback: **only gems rigor itself bundles**, and only
  when read soundly (the top-level namespace constant of a gem — `I18n`, `Rack`, `ActiveSupport` —
  is stable across versions, so reading rigor's copy for the *name* is correct even under a
  version skew). Both survey corpora (Mastodon, GitLab) are this case, which is why their measured
  yield is the shared-gem subset — correct, but a floor, not the ceiling a `vendor/bundle` run
  reaches.

Closing the global-gems gap needs rigor to learn the target's `GEM_PATH` — the *same* limitation
`BundleSigDiscovery` already has for finding gem-shipped `sig/` dirs (a mise-global target's sigs
aren't discovered either). It is a shared follow-up, out of scope here; the fail-open design means
the missing coverage is a missing label, never a wrong one.

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

**Results (both survey corpora are global-gems installs → the shared-gem floor above):**

- Mastodon `app/models`, identical denominator: 47 sites `unsupported_syntax` →
  `external_gem_without_rbs`; every other bucket byte-stable. Every sampled site adjudicated
  **correct** — all root at `I18n` (`I18n.t` validation messages, `I18n.locale`,
  `I18n.available_locales`).
- GitLab `lib`, identical denominator: 124 sites `unsupported_syntax` → `external_gem_without_rbs`,
  every other bucket byte-stable. All resolved via shared gems (`i18n`, `rack`, `activesupport`) —
  the `add_a_type_here` group examples are group-dominant (WD7's lossy-aggregation caveat), so the
  authoritative signal is the `cause_site_counts` tally, and the mechanism guarantees every one
  roots at a gem-constant read (`external_gem` originates *only* at `unresolved_constant_fallback`;
  a project-owned or unresolved-non-gem constant keeps the generic cause).

The i18n gem's RBS exists in `gem_rbs_collection`, so the `add_rbs` routing is genuinely actionable
on the sites this labels. A `vendor/bundle` run of either corpus would label the full external-gem
population (`grape`, `banzai`, `globalid`, …), not just the rigor-shared subset — that is the
coverage the fix unlocks and the global-gems limitation withholds here.
