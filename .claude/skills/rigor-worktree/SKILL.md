---
name: rigor-worktree
description: >-
  Create an isolated Rigor worktree with its copy-on-write gem bundle. Use for parallel work, a
  subagent checkout, or a dependency-bump branch; not for ordinary branch work that needs no isolation.
metadata:
  internal: true
---

# Create a worktree with its bundle in place

A worktree is the isolation boundary for parallel work: a lib-editing
agent gets its own tree so the `exe/rigor` another agent invokes is not
the code being rewritten under it, and a branch with its own
`Gemfile.lock` can `bundle install` without touching anyone else.

```sh
bin/rigor-worktree [--with-references] [--with-tools] <branch> [start-point]
```

- `<branch>` — an existing branch is checked out; a new name is created
  from `<start-point>` (default `origin/master`).
- The worktree lands at `$RIGOR_WT_ROOT/<slug>`, default
  `<main>/../rigor-wt/<slug>` (`~/repo/ruby/rigor-wt/<slug>` in the usual
  layout). `<slug>` is the branch with a leading `codex/` stripped and
  `/` → `-`.

The script runs `git worktree add`, then populates the bundle:

- `vendor/bundle` (~126M, ~9800 files) is **copy-on-write cloned** from
  the main clone — `cp -Rc` / `clonefile(2)` on APFS, a reflink on
  btrfs/xfs, a plain copy elsewhere. A few seconds, near-zero disk until
  blocks diverge, and the copy is **writable and isolated**.
- `.bundle/config` is copied (`BUNDLE_PATH: "vendor/bundle"`, a relative
  path — it only resolves because the real `vendor/bundle` is now
  in-tree).

No `.git/info/exclude` entry is needed: the real `vendor/bundle/`
directory matches the stock `.gitignore` `/vendor/bundle/`, so
`git status` stays clean.

The main clone must have a populated `vendor/bundle` first — the script
refuses otherwise. Run `make setup` there once if needed.

## The worktree-only gotchas the script can't hide

**`references/` submodules are NOT populated in a worktree.** A worktree
shares `.git`, but submodule working trees are per-checkout, so every
`references/*` directory is empty. A spec that reads a reference checkout
(`spec/docs/c_effects_raises_gate_spec.rb` is the clear one; the
builtin-catalog extraction target reads `references/ruby` too) then
**`skip`s — not fails — silently**, and a worker believes its gate ran
when only the fixture arm did. Options:

- `--with-references` — CoW-clones every populated `references/*`
  checkout and re-points each copied `.git` file at the shared module
  store. Fine because `references/` is **read-only** here. The script
  then compares each copy's **top-level entries** against the main
  clone's and **exits non-zero** if one did not land, because the cheap
  looks do not discriminate: a checkout copied one level deep still
  lists under `ls references/` and still answers `git -C
  references/<name> rev-parse HEAD`, while the gate that reads it skips.
- or run `make init-submodules` inside the worktree.

Verify a reference-reading gate actually **executed** (not `pending` /
`skipped`) before believing it.

**`.git` is shared across all worktrees.**

- **Never `git stash`** in a worktree — the stash stack is per-repo, so a
  `stash`/`pop` can pop another session's WIP into your tree. Take
  baselines with `git checkout <sha> -- <path>` … `git checkout HEAD --
  <path>`, and **commit before any baseline swap**.
- **Never `git submodule deinit` / `git submodule update --init` that
  removes a registration** — it deregisters the submodule for the *main
  clone*. Adding a checkout in a worktree is fine; removing a
  registration is never fine. Repair:
  `git submodule update --init --filter=blob:none references/<name>`.

**Push with an explicit refspec, never `-u`.** A worktree branch
created from `master` can carry `branch.<name>.merge = refs/heads/master`
(autoSetupMerge), and this environment sets `push.default = tracking` —
so `git push -u origin <branch>` resolves the destination through the
upstream config and lands the branch's commits on **remote `master`**
directly, bypassing the PR flow. Always push as
`git push origin <branch>:refs/heads/<branch>` (which also makes the
`->` mapping visible in the output — read it). If it ever happens,
restore with
`git push --force-with-lease=refs/heads/master:<pushed-sha> origin <prev-sha>:refs/heads/master`
before anyone fetches.

## `--with-tools`

Also CoW-clones `tool/steep/vendor` and `tool/sorbet/vendor` (each its
own bundle under `tool/*/Gemfile`). Only needed for a branch that runs
`make steep-check` or touches the Sorbet adapter.

## When the branch changes `Gemfile.lock`

Run `bundle install` in the worktree. It re-resolves against the cloned
bundle and diverges only the blocks it changes — the main clone and
sibling worktrees are untouched. This is the whole point of cloning
rather than symlinking.

## Staleness

The clone is pinned to the main clone's `vendor/bundle` at creation time.
If `master` later bumps a gem, an existing worktree keeps the old gems
until you `bundle install` in it.

## Running gates in a worktree

The local gate in a worktree is `make verify-changed`; the full suite is
CI's, on the Draft PR. When a heavy job must run locally anyway — a
full-suite reproduction, a corpus `rigor check` — run it in the
foreground with a generous timeout, never `run_in_background` (a
backgrounded full run is the known stall, and a detached wait cannot
always be woken), and **one heavy job on the machine at a time**: the
host OOM on record (2026-09-01) struck while a corpus `rigor check` over
eleven survey targets ran alongside four resumed workers. Implementation
parallel, heavy verification serial.

## Removing a worktree

```sh
git worktree remove <path>      # --force if the tree is dirty
git worktree prune
```

The CoW clone's disk is reclaimed with the directory.

## Quick checklist

- `bin/rigor-worktree <branch>` — bundle cloned, `.bundle/config` copied,
  `git status` clean.
- Add `--with-references` if any gate this branch runs reads a
  `references/` checkout; otherwise expect silent skips.
- Add `--with-tools` for a Steep / Sorbet branch.
- In the worktree: no `git stash`, no submodule deregistration, commit
  before baseline swaps.
- Gates foreground; one heavy job at a time.
- `bundle install` in the worktree if the branch moved `Gemfile.lock`.
