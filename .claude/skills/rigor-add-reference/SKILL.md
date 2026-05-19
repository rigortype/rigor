---
name: rigor-add-reference
description: Add a new reference submodule under references/ in this repository. Use whenever the user wants to vendor an upstream repo as a reference (e.g. "add sorbet as a reference", "vendor the dry-rb source", "add a submodule for X under references/"), or when a new ADR or feature needs a reference checkout that doesn't exist yet. Covers the full three-file change: .gitmodules + Makefile (two locations) + the submodule pointer, committed together.
---

# Add a Reference Submodule

Use this skill when the user wants to add a new upstream repo under `references/`. The change always touches three things together: `.gitmodules` (via `git submodule add`), `Makefile` (`REFERENCE_SUBMODULES` list + `init-submodules` body), and the submodule pointer commit. They belong in a single commit.

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
