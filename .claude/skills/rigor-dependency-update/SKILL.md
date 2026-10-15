---
name: rigor-dependency-update
description: >-
  Update Rigor's bundled gems and/or Nix Flake development environment while preserving version
  constraints. Use for dependency, `Gemfile.lock`, `flake.lock`, or nixpkgs updates; not for Ruby-version
  bumps or `references/` submodule updates.
metadata:
  internal: true
---

# Update dependencies (two layers)

The project's dependencies live in **two independent layers**, and the
first job is to keep them separate — a single "update the deps" request
usually means both, but they are different kinds of change and belong in
**different commits** so history stays legible.

1. **Bundled gems** — `Gemfile.lock`. The **runtime-affecting** layer:
   the analyzer's own dependencies (`prism`, `rbs`,
   `language_server-protocol`) plus dev tooling (`rubocop`, `rspec`,
   `binpacker`, …). Managed with `bundle update`. Every bump here also has
   to be mirrored into the Nix package's own lock (see "The Nix package
   lock").
2. **Nix Flake dev environment** — `flake.lock`. The **development**
   layer: the pinned `nixpkgs-unstable` revision that provisions the dev
   shell (make, git base, bundix, the Ruby build inputs). Managed with
   `nix flake update`.

Do both by default, but each layer is a self-contained commit, so doing
one alone is fine. Work on a branch and open **one PR** carrying both
commits (the public-dev workflow — grouped changes go through a PR, not a
direct push to `master`).

Use `bundle` / `nix` commands; never hand-edit a lockfile.

## Layer 1 — bundled gems (`bundle update`)

See what is available first, then update within the existing gemspec
constraints:

```sh
nix develop --command bundle outdated
nix develop --command bundle update
```

`bundle update` re-resolves every gem to the latest version the
**gemspec's existing ranges** allow. This is a lockfile refresh only —
`git diff Gemfile.lock` should show version bumps and nothing structural.

Two judgment calls the resolver makes for you, worth confirming:

- **A held-back major is not a blocker to chase.** If `bundle outdated`
  lists a new major (e.g. `diff-lcs 2.0`) but `bundle update` keeps the
  old one, a transitive constraint is capping it (rspec pins `diff-lcs <
  2.0`). That is correct — leave it. Pulling a major that the gemspec
  ranges forbid would require a **gemspec range change**, which is a
  deliberate decision outside this skill (edit the gemspec via
  `bundle add`, verify the new major, land it on its own).

Commit subject: `Update bundled gems to their latest in-range versions`.
Body: list the bumps, note no range change, note any major deliberately
held by a transitive cap.

## The Nix package lock (`nix/`)

The Nix package (`packages.default` in `flake.nix`, ADR-27's Nix channel)
resolves its runtime gems from `nix/Gemfile`, independently of
`Gemfile.lock`, into `nix/Gemfile.lock` + `nix/gemset.nix`. Run this after
**every** Layer 1 bump — it is a no-op when nothing the package resolves
moved:

```sh
nix develop --command bash -c 'cd nix && bundle update && bundix'
```

Plain `bundle lock` is **not** enough — it keeps the pinned versions and
only fills gaps. `bundle update` also installs the gems into
`nix/vendor/bundle` (gitignored); `bundix` reads only the lockfile. Fold
the regenerated files into the Layer 1 commit: the two locks move
together, and `spec/docs/nix_lockfile_sync_spec.rb` fails on either alone.

If the two disagree because a dev-only constraint caps a runtime gem in
the root lock, give `nix/Gemfile` the same bound. A held-back major (the
case above) is the same shape: widening the gemspec range also widens
`nix/Gemfile`'s bound, and then needs this regeneration.

## When the bump moves `rbs`

The gemspec admits `rbs >= 3.0, < 5.0`, and `make verify` proves only the
version in `Gemfile.lock`. CI's `rbs-compat` job runs both lines
(`~> 3.10` and `~> 4.0`), but only over `spec/rigor/environment`, so an
inference spec whose answer depends on the RBS line runs on one end
only. Before pushing, run the touched specs under the other end, from
the worktree, with a scratch Gemfile that copies the one the job writes
(`gem "rigortype", path: "<worktree>"`, `gem "rspec", ">= 3.13", "< 4.0"`,
`gem "rbs", "~> 3.10"`). The install fetches from rubygems.org. A spec
that needs `rbs-inline` cannot run on rbs 3.x.

```sh
nix develop --command bash -c 'BUNDLE_GEMFILE=<scratch>/Gemfile \
  BUNDLE_PATH=<worktree>/vendor/bundle BUNDLE_APP_CONFIG=<scratch>/.bundle \
  bundle install && BUNDLE_GEMFILE=<scratch>/Gemfile \
  BUNDLE_PATH=<worktree>/vendor/bundle BUNDLE_APP_CONFIG=<scratch>/.bundle \
  bundle exec rspec <specs> < /dev/null'
```

A spec never hard-codes a value from one side of the range; it reads
the installed version through a helper, as
`spec/support/rbs_core_type_params.rb` does.

Re-audit `lib/rigor/cache/rbs_environment_marshal_patch.rb` on every
`rbs` bump; a green CI run does not cover it:

- Every hook installs behind `unless method_defined?(:_dump)`. An `rbs`
  that ships its own `_dump` while still memoising `@hash` makes the
  patch silently inert, so check the guard, not only the memoisation.
- `grep -rn '@hash'` over the new `rbs`'s `lib/`: a hit outside the
  type-name and namespace sites the patch names is a new carrier.
- Invalid UTF-8 handed to `RBS::Parser` raises a bare `ArgumentError`.
  Every externally fed parse site, including a new one, needs the
  pre-guard `Environment::RbsLoader.invalid_encoding?` provides.

## Layer 2 — Nix Flake dev environment (`nix flake update`)

```sh
nix flake update
```

This bumps the single `nixpkgs` input to the latest `nixpkgs-unstable`
and rewrites **only `flake.lock`**. `flake.nix` is untouched.

**The deliberate in-flake pins stay** — they are hardcoded in `flake.nix`
for a reason and each has its own change path, so a dev-environment
refresh must not move them:

- **Ruby** (`mkRuby`, currently `4.0.5`) — bump via
  `rigor-ruby-version-bump`, not here.
- **git** (the `2.54.0` `overrideAttrs`) — an explicit override; bump
  individually with a fresh source hash if needed.
- **waza** (the pinned release binary + per-platform hashes) — bump
  individually (new version + four `fetchurl` hashes) if a newer waza
  release is wanted.

Commit subject: `Update the Nix Flake dev environment to the latest nixpkgs`.
Body: note the old → new nixpkgs date, that only `flake.lock` moved, and
that the in-flake pins were intentionally left.

## The nixpkgs-bump native-extension rebuild (do this, or verify fails)

A nixpkgs bump rebuilds the Ruby derivation to a **new `/nix/store` path**
even when the Ruby *version* is unchanged (the stdenv/build inputs moved).
The gems already compiled into `vendor/bundle` are linked against the
**old** `libruby`, so the next `bundle exec` dies with, e.g.:

```
json-2.20.0/lib/json/ext/parser.bundle:
  linked to incompatible /nix/store/<old>-ruby-4.0.5/lib/libruby-4.0.5.dylib (LoadError)
```

Rebuild the native extensions against the new Ruby before verifying:

```sh
rm -rf vendor/bundle
nix develop --command bundle install     # recompiles native ext against the new Ruby
```

`vendor/bundle` is **gitignored** — this is a purely local artifact of the
rebuild, so nothing about it is committed, and CI (which installs fresh
each run) never hits this. It only blocks *your* local `make verify`, so
clear it whenever a Flake update leaves `bundle exec` complaining about an
incompatible `libruby`.

## Order of operations

The rebuild dependency makes the order matter when both layers move:

1. Layer 1: `bundle update`; if the Nix package lock moved with it,
   regenerate `nix/` too (same commit); review, commit.
2. Layer 2: `nix flake update`, commit.
3. **After** the Flake update, `rm -rf vendor/bundle && bundle install`
   (rebuild native ext against the freshly-rebuilt Ruby).
4. `make verify` — must run *after* step 3, or the stale extensions fail it.

## Verify

```sh
nix develop --command make verify
nix develop --command git diff --check
```

`make verify` (test + lint + `check` + `check-plugins`) must be green under
the **new** toolchain and **freshly-compiled** gems — it is the proof both
layers are healthy together. Only `Gemfile.lock` and `flake.lock` should be
in `git status` (`vendor/bundle` and `nix/vendor/bundle` stay untracked);
`nix/Gemfile.lock` and `nix/gemset.nix` join them when the package lock
moved.

The spec compares version strings, so it cannot tell a broken package from
a good one — build it once when `nix/` moved:

```sh
nix develop --command nix build .#rigor && ./result/bin/rigor --version
```

CI also builds the package (the `Nix package` job) whenever `nix/**`,
`flake.nix` or `flake.lock` changes.

## Record the perf-gate shift

A `Gemfile.lock` bump can move the release gate's allocation number with no
engine change: the `rbs` gem supplies the core RBS the engine loads, and the
per-PR "Engine allocations" job cannot see it, because both of its arms run on
one bundle. Measure before and after the update, on the base commit and on the
branch, with `nix develop --command make bench-perf` or by dispatching the
release gate on each (`gh workflow run release-gate.yml --ref <branch>`). Put
both allocation numbers and the delta in the PR body: a release cut attributes
its rise from these records (`bench/README.md`, "Over a release cycle"). A
Flake-only update moves the local Ruby but not CI's, so a local pair is enough
for it.

## Push and open the PR

```sh
git push origin HEAD:refs/heads/<branch>
gh pr create --draft --base master --title "Update dependencies: bundled gems + Nix Flake dev environment" \
  --body "<the two commits, per-layer>"
```

The PR's `ci.yml` gate re-runs the full suite on a clean checkout (its own
`bundle install`), which is the authoritative cross-environment check. The PR
is created `--draft` and goes Ready (`gh pr ready <pr>`) only on the user's
explicit instruction to land it, with CI green and no stop instruction standing
(this skill's own landing rule, which `docs/agents/contribution-flow.md` § "Landing a pull
request" defers to — a GitHub
APPROVE cannot exist on a one-developer repository, so it is not the trigger).

## Stays untouched (out of scope here)

- **The gemspec version ranges** — a constraint change (admitting a new
  major) is a deliberate decision, done via `bundle add` and verified on
  its own, not folded into a lockfile refresh.
- **The Ruby version** — `rigor-ruby-version-bump`.
- **`references/` submodules** — `rigor-add-reference`.
- **The in-flake `git` / `waza` pins** — explicit overrides, bumped
  individually with fresh hashes.

## Quick checklist

- Branch cut; one PR carrying one commit per layer.
- `bundle update` (not a hand-edit); `git diff Gemfile.lock` is
  version-only; no gemspec range change; held-back majors left alone.
- Every Layer 1 bump: `nix/Gemfile.lock` + `nix/gemset.nix` regenerated
  with `cd nix && bundle update && bundix` (not plain `bundle lock`), in
  the Layer 1 commit.
- An `rbs` bump: touched specs run under the other end of the range;
  the marshal patch re-audited.
- `nix flake update`; only `flake.lock` moved; Ruby / git / waza in-flake
  pins untouched.
- `rm -rf vendor/bundle && bundle install` **after** the Flake update.
- `make verify` green under the new toolchain; `git diff --check` clean;
  `nix build .#rigor` still builds when `nix/` moved.
- Perf-gate allocations before and after the update are in the PR body.
- Two commits: `Update bundled gems to their latest in-range versions` and
  `Update the Nix Flake dev environment to the latest nixpkgs`.
