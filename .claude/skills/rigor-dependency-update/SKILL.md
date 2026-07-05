---
name: rigor-dependency-update
description: |
  Refresh the project's dependencies across its two independent layers in one pass — the bundled gems (`Gemfile.lock`, the runtime-affecting layer, via `bundle update`) and the Nix Flake dev environment (`flake.lock`'s `nixpkgs` pin, via `nix flake update`). Use when the user asks to "update dependencies", "bump the gems", "update the flake / nixpkgs", "refresh the dev environment", or "use the latest released dev tooling". Lands each layer as its own commit on one branch + PR, stays within the gemspec version constraints (never a range change, never a hand-edited lockfile), and handles the native-extension rebuild a nixpkgs bump forces. NOT for a Ruby version bump (use rigor-ruby-version-bump) or a references/ submodule bump (use rigor-add-reference).
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
   `binpacker`, …). Managed with `bundle update`.
2. **Nix Flake dev environment** — `flake.lock`. The **development**
   layer: the pinned `nixpkgs-unstable` revision that provisions the dev
   shell (make, git base, bundix, the Ruby build inputs). Managed with
   `nix flake update`.

Do both by default, but each layer is a self-contained commit, so doing
one alone is fine. Work on a branch and open **one PR** carrying both
commits (the public-dev workflow — grouped changes go through a PR, not a
direct push to `master`).

Use `bundle` / `nix` commands, never hand-edit a lockfile (per the repo's
Bundler rule).

## Layer 1 — bundled gems (`bundle update`)

See what is available first, then update within the existing gemspec
constraints:

```sh
nix ... develop --command bundle outdated
nix ... develop --command bundle update
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
- **Leave scheduled-removal gems in place.** `parallel_tests` is retained
  only until v0.3.0 (binpacker replaced it); do not update or drop it here.

Commit subject: `Update bundled gems to their latest in-range versions`.
Body: list the bumps, note no range change, note any major deliberately
held by a transitive cap.

## Layer 2 — Nix Flake dev environment (`nix flake update`)

```sh
nix --extra-experimental-features 'nix-command flakes' flake update
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
nix ... develop --command bundle install     # recompiles native ext against the new Ruby
```

`vendor/bundle` is **gitignored** — this is a purely local artifact of the
rebuild, so nothing about it is committed, and CI (which installs fresh
each run) never hits this. It only blocks *your* local `make verify`, so
clear it whenever a Flake update leaves `bundle exec` complaining about an
incompatible `libruby`.

## Order of operations

The rebuild dependency makes the order matter when both layers move:

1. Layer 1: `bundle update`, review, commit.
2. Layer 2: `nix flake update`, commit.
3. **After** the Flake update, `rm -rf vendor/bundle && bundle install`
   (rebuild native ext against the freshly-rebuilt Ruby).
4. `make verify` — must run *after* step 3, or the stale extensions fail it.

## Verify

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command make verify
nix --extra-experimental-features 'nix-command flakes' develop --command git diff --check
```

`make verify` (test + lint + `check` + `check-plugins`) must be green under
the **new** toolchain and **freshly-compiled** gems — it is the proof both
layers are healthy together. Only `Gemfile.lock` and `flake.lock` should be
in `git status` (`vendor/bundle` stays untracked).

## Push and open the PR

```sh
git push -u origin <branch>
gh pr create --base master --title "Update dependencies: bundled gems + Nix Flake dev environment" \
  --body "<the two commits, per-layer>"
```

The PR's `ci.yml` gate re-runs the full suite on a clean checkout (its own
`bundle install`), which is the authoritative cross-environment check.

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
  version-only; no gemspec range change; held-back majors and
  scheduled-removal gems left alone.
- `nix flake update`; only `flake.lock` moved; Ruby / git / waza in-flake
  pins untouched.
- `rm -rf vendor/bundle && bundle install` **after** the Flake update.
- `make verify` green under the new toolchain; `git diff --check` clean.
- Two commits: `Update bundled gems to their latest in-range versions` and
  `Update the Nix Flake dev environment to the latest nixpkgs`.
