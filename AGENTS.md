# AGENTS.md

This file is a development note for agents working in this repository. For broader project context, read `README.md` and `docs/adr/0-concept.md`. For the type system, start with the quick guide at `docs/types.md`; the normative type-language specification is split into topical documents under `docs/type-specification/`, and the analyzer-internal contracts (engine surface, type-object public API) live alongside it under `docs/internal-spec/`.

All project-authored documentation in this repository should be written in English. Treat external vendored or submodule documentation as upstream material and do not rewrite it only for language consistency.

## Project Overview

Rigor is an inference-first static analyzer for Ruby. It keeps application code free of type annotations and runtime dependencies, and starts with a CLI-first development experience.

The current implementation is an initial scaffold. It uses `Prism` to parse Ruby source files and exposes syntax diagnostics through the CLI as the smallest useful analysis surface.

## Development Environment

- Target Ruby is `4.0.3`. The gemspec requires Ruby `>= 4.0.0`, `< 4.1`.
- All development-time commands MUST run through the Flake. Do not run `bundle`, `rake`, `rspec`, `rubocop`, or `exe/rigor` directly from the host shell.
- The Flake shell includes Git 2.54.0 and GNU Make.
- `flake.nix` points Bundler at `vendor/bundle`; keep local gem installs isolated from global machine state.
- The license is MPL-2.0. The official repository is `https://github.com/rigortype/rigor`.
- The Flake mandate covers local development. CI (`.github/workflows/ci.yml`) installs Ruby via [`ruby/setup-ruby`](https://github.com/ruby/setup-ruby) instead of Nix and runs `make verify` directly; `references/` submodules are not checked out there because tests and `make check` do not consume them.

### Running commands through the Flake

Enter the Flake shell for interactive work:

```sh
nix --extra-experimental-features 'nix-command flakes' develop
```

Or prefix one-shot invocations with `nix --extra-experimental-features 'nix-command flakes' develop --command`. The command listings below use that prefix in full so each line is directly runnable. If `nix` is not on `PATH`, substitute `/nix/var/nix/profiles/default/bin/nix`.

### Basic setup

Inside the Flake shell, run:

```sh
make setup
```

From outside the Flake shell, prefix the same target:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command make setup
```

`make setup` runs `bundle install`, then `make init-git-config` (applies local git submodule-safety defaults — see below), and then `make init-submodules`. After it finishes, follow the steps in [Verification Notes](#verification-notes).

`make init-git-config` is idempotent and only writes to this clone's `.git/config`. It sets:

- `submodule.recurse = false` — parent operations (`reset`, `checkout`, `pull`) do **not** recurse into submodules. Submodule updates go through explicit `make init-submodules` / `make pull-submodules` instead, so a single broken submodule cannot abort a parent-side `git reset --hard`.
- `fetch.recurseSubmodules = on-demand` — `git fetch` only pulls submodule objects when the parent commits actually need them.
- `status.submoduleSummary = true` and `diff.submodule = log` — submodule pointer changes show up in `git status` and `git diff` instead of being silent.
- `push.recurseSubmodules = check` — `git push` refuses if a referenced submodule commit is not yet pushed upstream.

## Common Commands

Primary workflows (from the Flake shell, `make test`, `make lint`, `make check`; from outside, prefix with `nix --extra-experimental-features 'nix-command flakes' develop --command`):

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command make test
nix --extra-experimental-features 'nix-command flakes' develop --command make lint
nix --extra-experimental-features 'nix-command flakes' develop --command make check
```

- `make verify` runs `test`, `lint`, and `check` in sequence.
- `make check-json` runs `rigor check --format=json lib` (machine-readable diagnostics).
- Submodule maintenance: `make init-submodules`, `make pull-submodules`.

`bundle exec exe/rigor help` and `bundle exec exe/rigor version` remain available for CLI discovery. `rigor init` writes a starter `.rigor.yml` file. Use `--force` when overwriting an existing file intentionally.

`rigor type-of FILE:LINE:COL` is a probe over `Scope#type_of`. It locates the deepest expression enclosing the position, runs the inference engine, and prints the inferred type and its RBS erasure. `--format=json` switches to machine-readable output, and `--trace` records fail-soft fallbacks via `Rigor::Inference::FallbackTracer` so the missing-node coverage is visible from the CLI.

`rigor type-scan PATH...` is the file/directory-level companion. It walks every Prism node, runs `Scope#type_of` on each, and reports per-node-class coverage (visits vs. directly-unrecognized counts) plus a list of fallback example sites. Use it to track which expression shapes the engine still has to learn and to gate CI builds with `--threshold=RATIO`.

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec exe/rigor type-of lib/foo.rb:10:5
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec exe/rigor type-of --trace --format=json lib/foo.rb:10:5
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec exe/rigor type-scan lib
nix --extra-experimental-features 'nix-command flakes' develop --command bundle exec exe/rigor type-scan --format=json --threshold=0.7 lib
```

## Directory Layout

- `lib/rigor`: library code and CLI implementation
- `lib/rigor/analysis`: diagnostics, analysis results, and the analysis runner
- `sig`: public RBS signatures for Rigor itself
- `spec`: RSpec test suite
- `docs/types.md`: one-page quick guide to the Rigor type system
- `docs/type-specification`: normative type specification, split into topical documents
- `docs/internal-spec`: analyzer-internal contracts (engine surface, type-object public API)
- `docs/adr`: architecture decision records
- `references/`: long-lived **external** specifications and upstream submodules (not Rigor product code; see below)

## References under `references/`

The `references/` directory groups Git submodules used only as read-only specifications or upstream codebases. They are large, so the root [`.ignore`](.ignore) file lists `/references/` to keep [`ripgrep` (`rg`)](https://github.com/BurntSushi/ripgrep) from traversing them by default. Git is unaffected.

To search a reference tree intentionally, disable ignore files and **scope the path** to the tree you need:

```sh
rg PATTERN --no-ignore references/rbs
rg PATTERN --no-ignore references/python-typing
```

`--no-ignore` (or short `-u`) turns off all ignore files for that invocation. Scoping the path avoids pulling in normally ignored areas such as `vendor/`.

### Catalog

| Submodule | Upstream | Use |
| --- | --- | --- |
| `references/rbs` | `https://github.com/ruby/rbs.git` | RBS syntax, standard library signatures, test cases, and implementation behavior. Reference material for staying compatible with the RBS ecosystem. |
| `references/python-typing` | `https://github.com/python/typing.git` | Written-down Python typing concepts (gradual typing, generics, protocols, variance) borrowed only by idea. Not a syntax compatibility target. |
| `references/ruby` | `https://github.com/ruby/ruby.git` (branch `ruby_4_0`) | Ruby interpreter source. Parsed offline to derive a PHPStan-functionMap-style catalog of built-in methods: argument/return types plus per-method effect facets (pure, self-mutating, block-dependent). Read-only; do not link Rigor runtime code against it. |

### Submodule rules

- These submodules are reference material, not Rigor runtime code. Do not require, import, or copy upstream implementation into Rigor product code. Read the relevant specification or behavior, then implement the smallest appropriate Rigor-side behavior.
- Update a submodule only when intentionally changing the referenced revision.
- If a submodule is empty after cloning, run `nix --extra-experimental-features 'nix-command flakes' develop --command make init-submodules`.
- Drive submodule lifecycle through Make targets: `make init-submodules`, `make pull-submodules`. Avoid raw `git submodule update --recursive` against the whole tree — it bypasses the sparse-checkout setup baked into `init-submodules` for `references/phpstan` and `references/TypeScript-Website`.
- Do **not** hand-edit `.gitmodules` or `.git/config` for renames. Use `git mv old/path new/path` and then `git submodule sync` so `.git/config` follows `.gitmodules`. Hand edits leave stale `submodule.<name>.*` sections in `.git/config` and orphan `.git/modules/<old>/` directories, which can crash later parent operations with a `submodule.c` BUG assertion.
- Run `make doctor-submodules` if anything looks off (e.g. `git status` failing, parent operations exploding on a submodule). It detects: stale `.git/config` sections without a matching `.gitmodules` entry, dangling `.git` pointers in submodule worktrees, orphaned `.git/modules/<name>/` directories, and incomplete gitdirs (missing `HEAD` or `objects`). It reports issues and suggested fixes; it does not modify anything itself.
- Recovery cookbook for the common breakage modes (run after a backup if anything looks valuable):
  - **Stale `.git/config` section** (renamed away in `.gitmodules`): `git config --remove-section submodule.<old/name>`.
  - **Orphaned `.git/modules/<name>/`** (no longer in `.gitmodules`): `rm -rf .git/modules/<name>` after confirming nothing references it.
  - **Submodule worktree `.git` points to a missing/incomplete gitdir**: `git submodule deinit -f <path>` then `make init-submodules` to re-clone cleanly.
  - **Parent `git reset` aborts because of submodule recursion**: should not happen once `make init-git-config` has run, but as an escape hatch use `git -c submodule.recurse=false reset --hard <ref>`.

## Implementation Guidelines

- Keep additions small and aligned with the existing structure and naming.
- Prioritize the CLI-first workflow. Do not assume an LSP server or long-running daemon yet.
- Preserve the design goal that Ruby application code MUST NOT require Rigor-specific annotations or DSLs.
- Use RBS for external dependency and standard library type information. Future Rigor-specific advanced type expressions live in RBS comment extensions.
- Keep metaprogramming support out of the core where possible; steer it toward the future plugin API.
- For any change that touches type-model behavior — normalization, narrowing, erasure, signature handling, diagnostic identifiers, budgets — treat `docs/type-specification/` as the binding specification and `docs/adr/1-types.md` as the design-rationale companion. Update the relevant topical document when behavior changes.
- For any change that touches analyzer-internal contracts — `Scope`, fact store, effect model, capability-role inference, type-object public surface, factory-routed normalization, diagnostics-display routing — treat `docs/internal-spec/` as the binding specification and `docs/adr/3-type-representation.md` as the design-rationale companion. Update the relevant document when contracts change.

## Commit Messages

- Use a plain imperative subject in sentence case (e.g. `Add GitHub Actions CI running make verify on Ruby 4.0`, `Bump up version to 0.0.1`).
- Do **not** use Conventional-Commits-style `type:` or `area:` prefixes. The subject starts with a capitalised verb, no leading tag.
- Keep the subject self-contained and reasonably short; detail belongs in the body. Wrap the body at ~72 columns and write it for humans — explain the why and any context a future reader will need, not the diff itself.
- Release version bumps follow the fixed form `Bump up version to x.y.z`. See [`.codex/skills/rigor-release-prep/SKILL.md`](.codex/skills/rigor-release-prep/SKILL.md) for the full release-prep flow.

## Verification Notes

After making changes, run:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command make verify
nix --extra-experimental-features 'nix-command flakes' develop --command git diff --check
```

Inside the Flake shell, `make verify` is enough for the project checks.

If the Flake shell or its dependencies are unavailable, mention any skipped verification in the final report. For a minimal syntax-only check:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command sh -c 'for f in $(find bin exe lib spec -name "*.rb"); do ruby -c "$f" || exit 1; done'
```
