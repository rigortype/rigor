---
name: rigor-ruby-version-bump
description: |
  Bump the development Ruby version across every project marker that records it — flake.nix (including the Nix fake-hash derivation trick), .ruby-version, the Gemfile `ruby` directive, Gemfile.lock's RUBY VERSION, and the AGENTS.md target-Ruby line. Use when the user asks to "update Ruby to x.y.z", "bump the Ruby version", or after a new Ruby release lands. Covers which files change for a patch vs minor vs major bump, and which files deliberately stay untouched (flake.lock, the gemspec range, the ci.yml minor series).
---

# Bump the Ruby Version

Use this skill when the project's Ruby version needs to move (e.g. `4.0.4` → `4.0.5`). The version is recorded in **several independent places** — the Flake builds one Ruby, but `.ruby-version`, the `Gemfile`, `Gemfile.lock`, and CI read their own markers. Miss one and the build, CI, and contributor shells silently disagree.

Land the whole change as **one commit** so the markers never diverge in history.

## Step 0 — Classify the bump

The scope depends on which digit moves:

- **Patch** (`4.0.4` → `4.0.5`): Steps 1–5 only. The gemspec range and `ci.yml` minor series already admit the new patch — leave them.
- **Minor** (`4.0` → `4.1`): Steps 1–5 **plus** Step 6 — bump the `ci.yml` matrix entry and re-evaluate the gemspec `required_ruby_version` ceiling. The `references/ruby` submodule tracks branch `ruby_4_0` (see AGENTS.md) — a minor bump may need that branch repointed.
- **Major**: treat as a project decision, not a mechanical bump — confirm intent before proceeding.

## Step 1 — `flake.nix` (the source of truth for local builds)

Edit the `mkRuby` call:

```nix
ruby = (pkgs.mkRuby {
  version = pkgs.mkRubyVersion "4" "0" "5" "";   # ← new version digits
  hash = "sha256-...";                            # ← must be re-derived
  cargoHash = "sha256-...";                       # ← re-verify (see below)
}).override { docSupport = false; };
```

`hash` is the sha256 of the Ruby source tarball; it changes every release and **cannot be guessed**. Derive it with the Nix fake-hash technique:

1. Set `hash` to an all-zero placeholder:
   ```nix
   hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
   ```
2. Run the shell so Nix fetches and complains:
   ```sh
   nix --extra-experimental-features 'nix-command flakes' develop --command true
   ```
3. Nix prints a `hash mismatch` with a `got:` line — copy that value into `hash`:
   ```
   error: hash mismatch in fixed-output derivation '...ruby-4.0.5.tar.gz.drv':
            specified: sha256-AAAA...
               got:    sha256-fWFJB5pj+K4dMmyfplxgGbotwxVerns5FZgXkRyIlY4=
   ```

**`cargoHash`** (the vendored Rust deps for YJIT) is checked *after* `hash` resolves. Across patch releases it is usually unchanged — but **verify, never assume**: temporarily set it to the all-zero placeholder too and run the shell again. If Nix reports the same value it already had, restore it; if it differs, take the `got:` value.

Confirm the build:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command ruby -v
# => ruby 4.0.5 (...) +PRISM [...]
```

## Step 2 — `.ruby-version`

A single-line file. Set it to the full `x.y.z` version. Read by rbenv / chruby / asdf and by `ruby/setup-ruby` in CI.

```
4.0.5
```

## Step 3 — `Gemfile` — the `ruby` directive

Near the top:

```ruby
ruby "4.0.5"
```

Bundler checks this against the *running* Ruby; a mismatch aborts every `bundle` command.

## Step 4 — `Gemfile.lock` — `RUBY VERSION`

Do **not** hand-edit. Regenerate it by running Bundler under the new Ruby (which Step 1 now provides):

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command bundle install
```

Confirm the diff is **only** the `RUBY VERSION` block — nothing else:

```sh
git diff Gemfile.lock
# RUBY VERSION
# -  ruby 4.0.4
# +  ruby 4.0.5
```

If gem versions also moved, a dependency update crept in — reset and investigate before continuing.

## Step 5 — `AGENTS.md` — the target-Ruby line

Under "Development Environment":

```
- Target Ruby is `4.0.5`. The gemspec requires Ruby `>= 4.0.0`, `< 4.1`.
```

Then `grep -rn` the old version across `docs/` and update **live** docs (`docs/CURRENT_WORK.md`). Leave **dated records** — `docs/adr/*`, `docs/notes/*`, and existing `CHANGELOG.md` entries — untouched: they record a point-in-time fact, not the current target.

## Step 6 — Minor/major bumps only — conditional files

- **`.github/workflows/ci.yml`** — the `ruby:` matrix uses a minor series (`"4.0"`); `ruby/setup-ruby` resolves it to the latest patch automatically, so a *patch* bump needs no change. A *minor* bump updates the entry (`"4.0"` → `"4.1"`).
- **`rigortype.gemspec`** — `required_ruby_version` is a **range** (`[">= 4.0.0", "< 4.1"]`). A patch bump stays inside it. A minor bump re-evaluates the ceiling; only touch it when deliberately changing the *supported* range, which is a separate decision from the *development* Ruby.

## Files that deliberately stay untouched

- **`flake.lock`** — pins only the `nixpkgs` *input* revision. `mkRuby` takes the version and hash inline, so a Ruby bump never touches the lock. (Refreshing nixpkgs is a separate `nix flake update` decision.)
- **`docs/adr/*`, `docs/notes/*`** — dated design records; their version mentions are history.

## Step 7 — Verify

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command make verify
```

`make verify` chains test + lint + the `rigor check lib` self-check. It must stay clean on the new Ruby.

## Step 8 — Commit

One commit covering every marker. Subject (plain imperative, no prefix):

```
Bump development Ruby to 4.0.5
```

Body — note what changed and why the untouched files were left alone, e.g.:

```
flake.lock is unchanged (it pins only the nixpkgs input); the
gemspec required_ruby_version range and the ci.yml "4.0" minor
series already admit the new patch.
```

## Quick checklist

- `flake.nix` — `mkRubyVersion` digits + re-derived `hash`; `cargoHash` verified (not assumed).
- `nix develop --command ruby -v` reports the new version.
- `.ruby-version` — full `x.y.z`.
- `Gemfile` — `ruby` directive.
- `Gemfile.lock` — `RUBY VERSION` regenerated via `bundle install`; diff is that block only.
- `AGENTS.md` target-Ruby line; live `docs/` updated, dated records left alone.
- Minor/major only: `ci.yml` matrix + gemspec range re-evaluated.
- `flake.lock` NOT modified.
- `make verify` clean on the new Ruby.
- Single commit, `Bump development Ruby to x.y.z`.
