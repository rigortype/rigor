---
name: rigor-add-reference
description: |
  Add a new git submodule under references/ for vendored upstream source, and the reference for everything else about references/. Use when the user asks to "vendor X as a reference", "add a submodule under references/", or when a new ADR / feature needs a reference checkout — the three-file change (.gitmodules, Makefile's REFERENCE_SUBMODULES + init-submodules, the submodule pointer) committed together. ALSO use when asking what a given references/ tree is for, or when a submodule misbehaves: an empty checkout after cloning, `git status` failing, a parent `git reset` aborting on a submodule, a stale .git/config section after a rename, or a `submodule.c` BUG assertion.
metadata:
  internal: true
---

# Add a Reference Submodule

Use this skill when the user wants to add a new upstream repo under `references/`. The change always touches three things together: `.gitmodules` (via `git submodule add`), `Makefile` (`REFERENCE_SUBMODULES` list + `init-submodules` body), and the submodule pointer commit. They belong in a single commit.

The standing rule is in `AGENTS.md`: these submodules are **read-only reference material, not Rigor code** — never require, import, or copy upstream implementation into product code; read the behaviour, then implement the smallest Rigor-side equivalent. Update a submodule only when intentionally changing the referenced revision.

## The catalog — what each tree is for

| Submodule | Upstream | Use |
| --- | --- | --- |
| `references/rbs` | `https://github.com/ruby/rbs.git` | RBS syntax, stdlib signatures, test cases, implementation behaviour. The compatibility target for the RBS ecosystem. |
| `references/python-typing` | `https://github.com/python/typing.git` | Written-down Python typing concepts (gradual typing, generics, protocols, variance), borrowed **by idea only**. Not a syntax compatibility target. |
| `references/ruby` | `https://github.com/ruby/ruby.git` (branch `ruby_4_0`) | Ruby interpreter source. Parsed offline to derive the PHPStan-functionMap-style catalog of built-in methods: argument / return types plus per-method effect facets (pure, self-mutating, block-dependent). Never link Rigor runtime code against it. |
| `references/typeprof` | `https://github.com/ruby/typeprof.git` | TypeProf source — the reference implementation of Ruby type inference. Read for ideas and behaviour comparisons; never import or require it. |

The trees are large, so the root `.ignore` lists `/references/` to keep `rg` out by default (git is unaffected). Search one intentionally, and **scope the path** so you do not pull in `vendor/`:

```sh
rg PATTERN --no-ignore references/rbs
```

## Step 0 — Decide the checkout strategy

Before running any command, ask (or infer from context) whether a **sparse checkout** is needed:

- **Full checkout** (default): the whole repo is useful — use `git submodule update --init --filter=blob:none`.
- **Sparse checkout**: the repo is large but only a subdirectory matters (e.g. `references/phpstan` needs only `website/`, `references/TypeScript-Website` needs only `packages/documentation/copy/en`). Use the `sparse-checkout` pattern from `init-submodules` in the Makefile.

When in doubt, full checkout is fine. Sparse is an optimisation, not a correctness requirement.

## Step 1 — Register the submodule

```sh
git submodule add <upstream-url> references/<name>
```

Use `https://` URLs for read-only public repos (like sorbet). Use `git@github.com:` SSH URLs for repos where write access is possible or expected (like the existing `ruby/typeprof`). Match the convention of whichever group the new submodule belongs to.

This writes the `.gitmodules` entry and stages `references/<name>` automatically.

## Step 2 — Update the Makefile

Edit `Makefile` in **two** places:

### 2a. `REFERENCE_SUBMODULES` list (used by `make pull-submodules`)

Append the new entry at the end of the list, continuing the `\`-continuation style:

```makefile
REFERENCE_SUBMODULES := \
	references/rbs \
	... \
	references/typeprof \
	references/<name>      # ← add here
```

### 2b. `init-submodules` target body

**Full checkout** — add one line after the last simple `git submodule update` line (before the `@if` sparse-checkout blocks):

```makefile
	git submodule update --init --filter=blob:none references/<name>
```

**Sparse checkout** — add an `@if` block modelled on the existing `phpstan` or `TypeScript-Website` blocks. The structure is:

```makefile
	@if [ ! -e references/<name>/.git ]; then \
		url="$$(git config -f .gitmodules submodule.references/<name>.url)"; \
		sha="$$(git rev-parse HEAD:references/<name>)"; \
		echo "Initializing references/<name> sparsely (<which-subdirectory>)"; \
		git clone --no-checkout --filter=blob:none "$$url" references/<name>; \
		git -C references/<name> fetch origin "$$sha"; \
		git -C references/<name> sparse-checkout init --cone; \
		git -C references/<name> sparse-checkout set <subdirectory>; \
		git -C references/<name> checkout --detach "$$sha"; \
		git submodule absorbgitdirs references/<name>; \
	else \
		git submodule update --init --filter=blob:none references/<name>; \
	fi
```

The `absorbgitdirs` call is required for sparse-checkout blocks because `git clone` puts the `.git` directory inside the worktree rather than under `.git/modules/`.

## Step 3 — Verify the staged set

```sh
git status
```

Expected staged files:

- `modified: .gitmodules`
- `modified: Makefile`
- `new file: references/<name>` (the submodule pointer)

No other files should be staged. If `references/<name>/` appears as untracked content rather than a submodule pointer, the `git submodule add` in Step 1 didn't complete cleanly — re-run it.

## Step 4 — Commit

Commit all three together. Subject line format (plain imperative, no prefix):

```
Add references/<name> submodule
```

Body (optional, include if the purpose isn't obvious from the name):

```
Wire <name> into REFERENCE_SUBMODULES and init-submodules so
make pull-submodules and make init-submodules keep it in sync
automatically.
```

## Quick checklist

- `git submodule add` ran successfully and `references/<name>` is initialised.
- `REFERENCE_SUBMODULES` in `Makefile` includes `references/<name>`.
- `init-submodules` in `Makefile` has the correct block for the chosen checkout strategy.
- `git status` shows exactly the three expected staged entries.
- Commit contains `.gitmodules`, `Makefile`, and `references/<name>` — nothing else.

## Submodule hygiene

Drive the lifecycle through the Make targets: `make init-submodules`, `make pull-submodules`. Avoid raw `git submodule update --recursive` against the whole tree — it bypasses the sparse-checkout setup `init-submodules` bakes in for `references/phpstan` and `references/TypeScript-Website`. If a submodule is empty after cloning, run `nix … develop --command make init-submodules`.

**Never hand-edit `.gitmodules` or `.git/config` for a rename.** Use `git mv old/path new/path`, then `git submodule sync` so `.git/config` follows `.gitmodules`. Hand edits leave stale `submodule.<name>.*` sections and orphan `.git/modules/<old>/` directories, which can crash later parent operations with a `submodule.c` BUG assertion.

`make setup` runs `make init-git-config`, which is idempotent and writes only to this clone's `.git/config`. What it sets and why:

- `submodule.recurse = false` — parent operations (`reset`, `checkout`, `pull`) do **not** recurse, so one broken submodule cannot abort a parent-side `git reset --hard`.
- `fetch.recurseSubmodules = on-demand` — `git fetch` pulls submodule objects only when parent commits need them.
- `status.submoduleSummary = true`, `diff.submodule = log` — pointer changes show up instead of being silent.
- `push.recurseSubmodules = check` — `git push` refuses if a referenced submodule commit is not pushed upstream.

## Recovery cookbook

Run `make doctor-submodules` first when anything looks off (`git status` failing, parent operations exploding on a submodule). It detects stale `.git/config` sections with no `.gitmodules` entry, dangling `.git` pointers in submodule worktrees, orphaned `.git/modules/<name>/` directories, and incomplete gitdirs (missing `HEAD` or `objects`). It reports and suggests; it changes nothing itself.

Then, after a backup if anything looks valuable:

| Breakage | Fix |
| --- | --- |
| Stale `.git/config` section (renamed away in `.gitmodules`) | `git config --remove-section submodule.<old/name>` |
| Orphaned `.git/modules/<name>/` (no longer in `.gitmodules`) | `rm -rf .git/modules/<name>` after confirming nothing references it |
| Submodule worktree `.git` points at a missing / incomplete gitdir | `git submodule deinit -f <path>`, then `make init-submodules` to re-clone |
| Parent `git reset` aborts on submodule recursion | Should not happen once `make init-git-config` has run; escape hatch is `git -c submodule.recurse=false reset --hard <ref>` |
