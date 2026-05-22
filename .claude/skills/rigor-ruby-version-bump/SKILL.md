---
name: rigor-ruby-version-bump
description: |
  Bump the development Ruby version across the markers that record it — flake.nix (including the Nix fake-hash derivation trick), .ruby-version, .tool-versions, and the AGENTS.md target-Ruby line. Use when the user asks to "update Ruby to x.y.z", "bump the Ruby version", or after a new Ruby release lands. Explains the development-Ruby vs supported-range split: a patch bump touches only the four development markers and deliberately leaves the Gemfile `ruby` directive, Gemfile.lock's RUBY VERSION, the gemspec range, and the ci.yml matrix alone.
---

# Bump the Ruby Version

Use this skill when the project's Ruby version needs to move (e.g. `4.0.4` → `4.0.5`). The version is recorded in **several independent places**, and the first job is to understand that those places fall into **two categories** — conflating them is the mistake this skill exists to prevent.

Land the whole change as **one commit** so the markers never diverge in history.

## Two kinds of marker — do not conflate them

An earlier version of this skill bumped *every* marker to the exact patch. That was wrong: it coupled the **development Ruby** to the **supported-range markers**, which breaks CI and force-upgrades contributors. Keep the two groups separate.

**Development Ruby** — the exact patch the contributor shell runs. Flake-controlled; bump freely to any released patch.

- `flake.nix` — the `mkRuby` version + re-derived `hash`.
- `.ruby-version` — read by rbenv / chruby / asdf and by `ruby/setup-ruby` in CI.
- `.tool-versions` — read by asdf / mise; a peer of `.ruby-version`.
- `AGENTS.md` — the target-Ruby line.

**Supported-range markers** — express what Ruby the *gem* supports, not the dev patch. A **patch** bump MUST NOT touch these.

- `rigortype.gemspec` — `required_ruby_version` (`[">= 4.0.0", "< 4.1"]`) — the binding contract for end users.
- `Gemfile` — the `ruby` directive — a **range** mirroring the gemspec (`ruby ">= 4.0.0", "< 4.1"`), never an exact patch.
- `Gemfile.lock` — the `RUBY VERSION` block — held at the supported **floor** (`ruby 4.0.0`), not the dev patch.
- `.github/workflows/ci.yml` — the `ruby:` matrix — a minor series (`"4.0"`); `ruby/setup-ruby` resolves the patch.

**Why the `Gemfile` directive must be a range, not an exact patch.** Bundler treats `ruby "x.y.z"` as an *exact* match and aborts every `bundle` command when the running Ruby differs by even a patch. CI's `setup-ruby` installs whatever patch it currently ships (often a step behind the newest release), so an exact pin newer than that breaks CI; contributors not yet on the exact patch are likewise force-upgraded. A range — `ruby ">= 4.0.0", "< 4.1"` — accepts any `4.0.x` and keeps the gemspec as the single source of truth for the supported range. Note that an exact `ruby "4.0.0"` is **not** a fix either: it would reject the Flake's own newer Ruby and break the dev shell.

## Step 0 — Classify the bump

The scope depends on which digit moves:

- **Patch** (`4.0.4` → `4.0.5`): **development markers only** — Steps 1–3. The supported-range markers already admit the new patch; leave them untouched.
- **Minor** (`4.0` → `4.1`): Steps 1–3 **plus** Step 6 — a minor bump is also where the supported-range markers move (gemspec ceiling, `Gemfile` range, `Gemfile.lock` floor, `ci.yml` matrix). The `references/ruby` submodule tracks branch `ruby_4_0` (see AGENTS.md) — a minor bump may need that branch repointed.
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

## Step 2 — `.ruby-version` and `.tool-versions`

Two single-line version files. Set each to the full `x.y.z` version.

`.ruby-version` is read by rbenv / chruby / asdf and by `ruby/setup-ruby` in CI:

```
4.0.5
```

`.tool-versions` is the asdf / mise version file — a peer of `.ruby-version` recording the same development-Ruby patch, prefixed with the tool name:

```
ruby 4.0.5
```

## Step 3 — `AGENTS.md` — the target-Ruby line

Under "Development Environment":

```
- Target Ruby is `4.0.5`. The gemspec requires Ruby `>= 4.0.0`, `< 4.1`.
```

Update only the *development* digit (`4.0.5`) — the gemspec range stated on the same line is a supported-range fact and moves only on a minor bump (Step 6).

Then `grep -rn` the old version across `docs/` and update **live** docs (`docs/CURRENT_WORK.md`). Leave **dated records** — `docs/adr/*`, `docs/notes/*`, and existing `CHANGELOG.md` entries — untouched: they record a point-in-time fact, not the current target.

## Step 4 — Verify

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command make verify
```

`make verify` chains test + lint + the `rigor check lib` self-check. It must stay clean on the new Ruby. `bundle exec` reads the `Gemfile` `ruby` directive — because that directive is a range, the new patch satisfies it without a `Gemfile` edit.

## Step 5 — Commit

One commit covering every marker that moved. Subject (plain imperative, no prefix):

```
Bump development Ruby to 4.0.5
```

Body — note what changed and why the supported-range markers were left alone, e.g.:

```
Only the development markers move on a patch bump: flake.nix,
.ruby-version, .tool-versions, and the AGENTS.md target line. The Gemfile `ruby`
directive (a >= 4.0.0, < 4.1 range), Gemfile.lock's RUBY VERSION
(held at the 4.0.0 floor), the gemspec range, and the ci.yml
"4.0" minor series are supported-range markers and deliberately
unchanged. flake.lock is unchanged (it pins only the nixpkgs
input).
```

## Step 6 — Minor/major bumps only — the supported-range markers

A **minor** bump is the only time the supported-range markers move. They move together:

- **`rigortype.gemspec`** — re-evaluate the `required_ruby_version` range. The ceiling/floor change only when deliberately changing the *supported* range — a separate decision from the development Ruby.
- **`Gemfile`** — the `ruby` directive is a range mirroring the gemspec. If the gemspec range changed, update the directive to match. Keep it a range; never an exact patch.
- **`Gemfile.lock`** — the `RUBY VERSION` block is held at the supported **floor**. Update it only if the floor moved. Hand-edit it; do **not** regenerate it from the running Ruby (see below).
- **`.github/workflows/ci.yml`** — the `ruby:` matrix uses a minor series (`"4.0"`); `ruby/setup-ruby` resolves it to the latest patch automatically, so a *patch* bump needs no change. A *minor* bump updates the entry (`"4.0"` → `"4.1"`).

### `Gemfile.lock`'s `RUBY VERSION` is not regenerated per bump

Bundler writes the `RUBY VERSION` block from the *running* Ruby whenever `bundle install` / `bundle lock` runs. The project deliberately keeps it at the supported floor (`ruby 4.0.0`) instead, so the lock stays stable across patch bumps and does not record the dev patch. If a `bundle install` rewrites it to the running Ruby, **reset that block to the floor before committing**. `bundle exec` (what `make verify` runs) does not rewrite the lock, so a normal verify leaves it alone.

## Files that deliberately stay untouched on a patch bump

- **`Gemfile`, `Gemfile.lock`, `rigortype.gemspec`, `.github/workflows/ci.yml`** — supported-range markers; a patch bump leaves all four alone (see Step 6 for when they *do* move).
- **`flake.lock`** — pins only the `nixpkgs` *input* revision. `mkRuby` takes the version and hash inline, so a Ruby bump never touches the lock. (Refreshing nixpkgs is a separate `nix flake update` decision.)
- **`docs/adr/*`, `docs/notes/*`** — dated design records; their version mentions are history.

## Quick checklist

### Patch bump

- `flake.nix` — `mkRubyVersion` digits + re-derived `hash`; `cargoHash` verified (not assumed).
- `nix develop --command ruby -v` reports the new version.
- `.ruby-version` — full `x.y.z`.
- `.tool-versions` — `ruby x.y.z`.
- `AGENTS.md` target-Ruby line (development digit only); live `docs/` updated, dated records left alone.
- `Gemfile`, `Gemfile.lock`, `rigortype.gemspec`, `ci.yml` — NOT modified.
- `flake.lock` — NOT modified.
- `make verify` clean on the new Ruby.
- Single commit, `Bump development Ruby to x.y.z`.

### Minor bump — additionally

- `rigortype.gemspec` `required_ruby_version` range re-evaluated.
- `Gemfile` `ruby` directive range updated to mirror the gemspec (still a range).
- `Gemfile.lock` `RUBY VERSION` updated to the new floor (hand-edited, not regenerated).
- `ci.yml` `ruby:` matrix entry bumped.
- `references/ruby` submodule branch repointed if required.
