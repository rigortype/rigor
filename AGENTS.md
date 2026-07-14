# AGENTS.md

This file is a development note for agents working in this repository. For broader project context, read `README.md` and `docs/adr/0-concept.md`. For the type system, start with the quick guide at `docs/types.md`; the normative type-language specification is split into topical documents under `docs/type-specification/`, and the analyzer-internal contracts (engine surface, type-object public API) live alongside it under `docs/internal-spec/`.

All project-authored documentation in this repository should be written in English. Treat external vendored or submodule documentation as upstream material and do not rewrite it only for language consistency.

## Project Overview

Rigor is an inference-first static analyzer for Ruby. It keeps application code free of type annotations and runtime dependencies, and starts with a CLI-first development experience.

The implementation sits on top of the v0.1.0 plugin contract. It parses Ruby with `Prism`, runs a flow-sensitive type-inference engine over each file, consults RBS signatures (bundled stdlib + project `sig/` + gem RBS) plus in-source `def` / `define_method` / `attr_*` / `Data.define` discovery, and reports a deliberately-narrow rule catalogue (the `call.*` / `flow.*` / `def.*` / `assert.*` / `dump.*` families). **Production plugins** for real gems / frameworks (Rails, RSpec, dry-rb, Sorbet, Devise, Sidekiq, etc.) live under [`plugins/`](plugins/README.md); plugin-contract **walkthroughs** (tutorials over deliberately simplified virtual use cases — `rigor-deprecations`, `rigor-lisp-eval`, `rigor-pattern`, `rigor-routes`, `rigor-units`) live under [`examples/`](examples/README.md). Both counts drift as new entries land, so consult each README for the canonical list rather than hard-coding it elsewhere. The twelve-chapter (plus six appendices) end-user handbook lives under [`docs/handbook/`](docs/handbook/README.md).

**Where the "what is true today" state lives.** This file is the cross-version agent contract; it intentionally does NOT name the version in progress, the recently-landed slices, or the deferred work. The canonical resume bookmark is [`docs/CURRENT_WORK.md`](docs/CURRENT_WORK.md); the forward-looking commitment envelope (active cycle + queued work) is [`docs/ROADMAP.md`](docs/ROADMAP.md); the released-version record is `CHANGELOG.md`; the ADR index sits in [`CLAUDE.md`](CLAUDE.md) § "Architecture decision records". Always start a session by reading the first three for current state. AGENTS.md changes only when the contract itself changes — the Flake mandate, commit conventions, release cadence, references / submodule rules, the spec-binds-on-conflict invariants below.

## Development Environment

- Target Ruby is `4.0.5`. The gemspec requires Ruby `>= 4.0.0`, `< 4.1`.
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

Or prefix one-shot invocations with `nix --extra-experimental-features 'nix-command flakes' develop --command` — abbreviated `nix … develop --command` in the example blocks below (expand `…` to `--extra-experimental-features 'nix-command flakes'`). If `nix` is not on `PATH`, substitute `/nix/var/nix/profiles/default/bin/nix`.

### Basic setup

Inside the Flake shell, run:

```sh
make setup
```

From outside the Flake shell, prefix the same target:

```sh
nix … develop --command make setup
```

`make setup` runs `bundle install`, then `make init-git-config` (applies local git submodule-safety defaults — see below), and then `make init-submodules`. After it finishes, follow the steps in [Verification Notes](#verification-notes).

`make init-git-config` is idempotent and only writes to this clone's `.git/config`. It sets:

- `submodule.recurse = false` — parent operations (`reset`, `checkout`, `pull`) do **not** recurse into submodules. Submodule updates go through explicit `make init-submodules` / `make pull-submodules` instead, so a single broken submodule cannot abort a parent-side `git reset --hard`.
- `fetch.recurseSubmodules = on-demand` — `git fetch` only pulls submodule objects when the parent commits actually need them.
- `status.submoduleSummary = true` and `diff.submodule = log` — submodule pointer changes show up in `git status` and `git diff` instead of being silent.
- `push.recurseSubmodules = check` — `git push` refuses if a referenced submodule commit is not yet pushed upstream.

## Common Commands

Primary workflows, shown in their in-shell form. From outside the shell, prefix each with the one-shot runner from above (`nix … develop --command`):

```sh
make test
make lint
make check
```

- `make verify` runs `test-binpacker` (the spec suite across `binpacker`'s worker pool — `workers: auto` in `binpacker.yml`, defaulting to the CPU count), `lint`, `check`, and `check-plugins`. Total wall time on a 12-core laptop ≈ 60s vs ≈ 220s for the sequential variant. Use `make verify-sequential` when chasing parallel-only flakes; `make verify-parallel` is a backward-compatible alias for the default.
- `make check-json` runs `rigor check --format=json lib` (machine-readable diagnostics).
- `make check-plugins` runs `rigor check plugins/*/lib examples/*/lib` — the plugin-contract self-check ([ADR-43](docs/adr/43-rbs-complete-ancestor-resolution.md)). A bundled plugin that misuses the `Plugin::Base` contract surface (e.g. calls a method the contract's RBS does not declare) fails here with `call.undefined-method`. Lib dirs only — the `demo/` trees deliberately exercise un-modelled framework DSLs. MUST stay clean.
- Submodule maintenance: `make init-submodules`, `make pull-submodules`.
- Cross-checker pass: `make steep-install` once, then `make steep-check`. Steep runs under an isolated `tool/steep/Gemfile` so its dependency tree (rbs, prism, …) cannot bleed into Rigor's own `Gemfile.lock`. `make steep ARGS="check --severity-level=error"` is the pass-through escape hatch.
- Cache maintenance: `bundle exec exe/rigor check --cache-stats lib` inventories the per-slot footprint of `.rigor/cache`; `make cache-clean` wipes the directory. Per [ADR-6](docs/adr/6-cache-persistence-backend.md) the store is sharded "no eviction" — config / dependency churn over a long-lived clone accumulates stale slots that only `cache-clean` releases.

`bundle exec exe/rigor help` and `bundle exec exe/rigor version` remain available for CLI discovery. `rigor init` writes a starter `.rigor.yml` file. Use `--force` when overwriting an existing file intentionally.

`rigor type-of FILE:LINE:COL` is a probe over `Scope#type_of`. It locates the deepest expression enclosing the position, runs the inference engine, and prints the inferred type and its RBS erasure. `--format=json` switches to machine-readable output, and `--trace` records fail-soft fallbacks via `Rigor::Inference::FallbackTracer` so the missing-node coverage is visible from the CLI.

`rigor type-scan PATH...` is the file/directory-level companion. It walks every Prism node, runs `Scope#type_of` on each, and reports per-node-class coverage (visits vs. directly-unrecognized counts) plus a list of fallback example sites. Use it to track which expression shapes the engine still has to learn and to gate CI builds with `--threshold=RATIO`.

```sh
# In-shell forms (prefix with `nix … develop --command` from outside):
bundle exec exe/rigor type-of lib/foo.rb:10:5
bundle exec exe/rigor type-of --trace --format=json lib/foo.rb:10:5
bundle exec exe/rigor type-scan lib
bundle exec exe/rigor type-scan --format=json --threshold=0.7 lib
```

## Directory Layout

- `lib/rigor`: library code and CLI implementation
- `lib/rigor/analysis`: diagnostics, analysis results, and the analysis runner
- `sig`: public RBS signatures for Rigor itself
- `spec`: RSpec test suite
- `plugins/`: **production plugins** targeting real gems / frameworks (Rails, RSpec, dry-rb, Sorbet, Devise, Sidekiq, etc.). Each gem has `lib/`, optionally a runnable `demo/`, a README, and an end-to-end integration spec under `spec/integration/plugins/`. Read [`plugins/README.md`](plugins/README.md) for the canonical inventory + comparison table; the list drifts, so do not duplicate it here.
- `examples/`: **plugin-contract walkthroughs** (tutorials over deliberately simplified virtual use cases — `rigor-deprecations`, `rigor-lisp-eval`, `rigor-pattern`, `rigor-routes`, `rigor-units`). Each spotlights a single architectural surface so plugin authors can read the smallest possible code that demonstrates one slice of the contract at a time. Integration specs under `spec/integration/examples/`. Read [`examples/README.md`](examples/README.md) for the recommended reading order.
- `docs/handbook/`: twelve-chapter (plus six appendices) end-user walkthrough of the type model, written for Ruby programmers without prior static-typing background. Informational — `docs/type-specification/` binds when they disagree.
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
| `references/typeprof` | `https://github.com/ruby/typeprof.git` | TypeProf source. Reference implementation of Ruby's type inference approach. Read for implementation ideas and behaviour comparisons; do not import or require upstream code into Rigor. |

### Submodule rules

- These submodules are reference material, not Rigor runtime code. Do not require, import, or copy upstream implementation into Rigor product code. Read the relevant specification or behavior, then implement the smallest appropriate Rigor-side behavior.
- Update a submodule only when intentionally changing the referenced revision.
- If a submodule is empty after cloning, run `nix … develop --command make init-submodules`.
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
- **Type-model vocabulary (avoid two common misreads).** Rigor's type model is an **RBS superset** — gradual (`Dynamic[T]`), **nominal by default**, with **structural** typing only at interface boundaries (the one-page guide is [`docs/types.md`](docs/types.md); the normative corpus is [`docs/type-specification/`](docs/type-specification/README.md)). When writing code comments, RBS, diagnostics, or docs, two words are easy to misuse: **"interface"** in Rigor/RBS is *structural* — like Go's `interface` or Python's `typing.Protocol`, satisfied by *having the methods* with no `implements` clause (Ruby has none) — **not** the Java / PHP *nominal* sense most readers import; qualify it on first use as "structural interface" / "RBS interface". **"protocol"** is overloaded — the structural-typing feature is the *interface* just described, whereas a **protocol contract** is [ADR-28](docs/adr/28-path-scoped-protocol-contracts.md)'s path-scoped *behavioural* method contract (a plugin-manifest field); do not conflate the two. The same discipline applies to **engine-internal contracts**, where the trap is easiest to fall into: a duck-typed module seam (e.g. each dispatch tier's `try_dispatch(CallContext) -> Type?` shape, the `_DispatchTier` contract) is itself a *structural interface* — name and describe it as an **interface** (or "tier contract" / "structural contract"), **not** a "protocol," so that word stays reserved for the ADR-28 sense even in internal naming and comments (Ruby's idiomatic "the `each` protocol" notwithstanding). The canonical explainer is the handbook appendix [Protocols, interfaces, and structural typing](docs/handbook/appendix-protocols-and-structural-typing.md).
- Prioritize the CLI-first workflow. Do not assume an LSP server or long-running daemon yet.
- Preserve the design goal that Ruby application code MUST NOT require Rigor-specific annotations or DSLs.
- Use RBS for external dependency and standard library type information by default. Rigor-specific advanced type expressions live in RBS comment extensions (`%a{rigor:v1:…}`) parsed by [`lib/rigor/builtins/imported_refinements.rb`](lib/rigor/builtins/imported_refinements.rb). The parser is a two-pass design — scan to a `Rigor::TypeNode` AST, then a `Resolver` pass walks the AST through built-in registry → plugin `TypeNodeResolver` chain → RBS Nominal fallback. When extending the payload grammar, edit the parser AND the spec rows in [`docs/type-specification/imported-built-in-types.md`](docs/type-specification/imported-built-in-types.md) / [`docs/type-specification/type-operators.md`](docs/type-specification/type-operators.md) in the same commit.
- Opt-in gem-source inference (`dependencies.source_inference:` in `.rigor.yml`) walks a no-RBS gem's `lib/` as a `Dynamic[T]`-bearing fallback below the RBS tier. RBS / RBS::Inline / generated stubs / plugin contracts always win on conflict; the dispatcher tier ordering is normative.
- Keep metaprogramming support out of the core where possible; steer it toward the future plugin API.
- For any change that touches type-model behavior — normalization, narrowing, erasure, signature handling, diagnostic identifiers, budgets — treat `docs/type-specification/` as the binding specification and `docs/adr/1-types.md` as the design-rationale companion. Update the relevant topical document when behavior changes.
- For any change that touches analyzer-internal contracts — `Scope`, fact store, effect model, capability-role inference, type-object public surface, factory-routed normalization, diagnostics-display routing — treat `docs/internal-spec/` as the binding specification and `docs/adr/3-type-representation.md` as the design-rationale companion. Update the relevant document when contracts change.

## RBS Authorship

The project's **aspiration**: deterministic inference — driven by [`rigor sig-gen`](docs/adr/14-rbs-sig-generation.md) — should be precise enough that AI-authored RBS becomes unnecessary. Each gap that pushes someone toward freehand AI RBS in this repository is information about where the inference engine still has work to do; the preferred response is to extend the deterministic generator rather than route around it. AI assistance for RBS is not strictly forbidden — but it is rarely the right first move in this repo, and any AI-authored RBS lands only after explicit human review.

`rigor sig-gen` is the project's standard authoring tool. It emits RBS from Rigor's inference results, classifies each method as `new-file` / `new-method` / `tighter-return` / `equivalent` / `skipped`, and enforces the soundness disciplines that hand-rolling bypasses:

- `def.return-type-mismatch` strict-acceptance check (the generator never emits a tightening the analyzer itself would reject).
- ADR-5 robustness asymmetry (strict on returns, lenient on parameters; `--params=untyped` default, `observed` opt-in via `--observe=PATH`).
- `erase_to_rbs` round-trip discipline (every carrier without faithful RBS spelling erases to its nominal envelope).

**How to apply.**

- When a session needs RBS coverage in this repo, propose `rigor sig-gen --print` / `--diff` first. Land hand-edited RBS only when the generator's classification surfaces a real gap that warrants a separate inference-engine improvement, AND the user has reviewed the alternatives.
- When sig-gen falls short on a method shape (`sig.skipped.complex-shape`, missing carrier, etc.), record the gap as a follow-up candidate for the inference engine. Avoid backfilling with freehand RBS just because it would be quick — the gap is the more valuable signal.
- Hand-edits to existing `.rbs` files for corrections (renames, typos, intentional widening per ADR-5 clause 2) remain acceptable when authorised.
- Reading existing RBS (project `sig/`, `data/vendored_gem_sigs/`, `references/`) is always fine.

This is project-internal practice. Outside the rigor repository, treat AI-authored RBS suggestions normally.

### Inference-vs-RBS contradiction rule (sig-gen output)

When `rigor sig-gen` proposes a **`tighter-return`** that contradicts existing RBS, the default policy is to **NOT overwrite, even with `--overwrite`.** The dogfood pass on Rigor's own `lib/` (2026-05-12) produced 7 tighter-return candidates and every one turned out to be an inference incompleteness — early-return `return nil unless …` paths missed, two-valued booleans literal-folded to one, `Array[T]` collapsed to `Tuple[T, ...]` — rather than a real precision win. The existing hand-maintained RBS captured branches the inference engine does not yet see, so the existing form is more accurate.

Treat any tightening that **loses union members** compared to the declared RBS as a contradiction signal: do not apply, and surface the discrepancy as a follow-up candidate for the inference engine. New methods (no existing RBS) remain freely applicable after review; `equivalent` classifications are no-ops.

## Commit Messages

- Use a plain imperative subject in sentence case (e.g. `Add GitHub Actions CI running make verify on Ruby 4.0`, `Bump up version to 0.0.1`).
- Do **not** use Conventional-Commits-style `type:` or `area:` prefixes. The subject starts with a capitalised verb, no leading tag.
- Keep the subject self-contained and reasonably short; detail belongs in the body. Wrap the body at ~72 columns and write it for humans — explain the why and any context a future reader will need, not the diff itself.
- Release version bumps follow the fixed form `Bump up version to x.y.z`. See [`.claude/skills/rigor-release-prep/SKILL.md`](.claude/skills/rigor-release-prep/SKILL.md) for the full release-prep flow.

## Documentation-only changes

Markdown / documentation-only changes — ADRs, `docs/notes/`, [`docs/CURRENT_WORK.md`](docs/CURRENT_WORK.md), `CHANGELOG.md` `[Unreleased]` entries, READMEs, skills — land as **direct commits to `master`, not through a pull request.** CI's `paths-ignore: ["**/*.md"]` (on the `push` trigger in [`.github/workflows/ci.yml`](.github/workflows/ci.yml)) skips the whole Ruby test / lint / self-check suite for a push whose files are all Markdown, so a docs PR only buys a redundant full CI run plus review noise. The filter is deliberately **not** applied to `pull_request` — a path-filtered *required* check hangs pending and blocks the merge — so the skip only takes effect on the direct-push path. Practical rules:

- **Never open a pull request whose only change is `docs/CURRENT_WORK.md`.** It is a transient resume bookmark; refresh it with a direct commit to `master`, or fold the refresh into the substantive PR it accompanies.
- A Markdown-only change commits straight to `master`. A change that also touches Ruby (or any non-`.md` file) is code and goes through a branch + PR as usual — a mixed commit runs the full suite, which is correct.

- **No autonomous version bumps.** `Rigor::VERSION` (in `lib/rigor/version.rb`), `CHANGELOG.md` released-version sections, and `Gemfile.lock` MUST only be bumped on explicit user request. Land feature commits with their `## [Unreleased]` CHANGELOG entries — written user-facing at landing per § "CHANGELOG Style" — and stop there; the user drives the cut-over to a numbered release. Adding entries under `## [Unreleased]` does NOT count as a version bump.
- **Single-digit version components.** Each `x.y.z` component stays single-digit. `0.0.9`'s successor is `0.1.0` — never `0.0.10`. `0.9.x`'s successor is `1.0.0`. Same rule applies recursively at every position.
- The `bundle exec rake release` task (which tags `vx.y.z`, pushes to origin, and publishes to RubyGems) is gated separately — never run it without explicit user authorisation, even when the version is already bumped.

## CHANGELOG Style

`CHANGELOG.md` follows [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/). The goal is for users to scan changes quickly, so every entry is written from the user's perspective, not the implementer's.

**When to write — at landing, in release-style.** Write each `## [Unreleased]` entry from the user's perspective at the moment the change lands, as if release notes were cut that day. The commit message and the CHANGELOG entry have different audiences and are written differently in the **same** landing: the commit body stays a detailed engineering record (file paths, method names, rationale, soundness gates) for `git log` archaeology, while the CHANGELOG entry is user-facing release notes. Do not defer the user-facing version to release-prep — a `[Unreleased]` section that already reads like release notes at any moment keeps release-prep mechanical (the v0.1.12 cut spent ≥3× longer than necessary rewriting drift that should never have accumulated).

**Why a release-time pass still exists — and what it is not.** Keep a Changelog organises by **user-recognisable change**, a unit that does not line up with **commits**: one user-facing change may land across several commits, and several small commits may each fold into a single entry. That misalignment can only be reconciled with cycle-wide context, so release-prep **consolidates, reorders, and dedupes** entries — it is *not* a licence to skip landing-time quality and rewrite commit prose wholesale at the end. The verbose `[Unreleased]` drafts an implementation agent tends to produce are not waste: when an entry has drifted detail-heavy, mine the detail down into child items rather than discarding it.

**Entry shape:**

- Each top-level bullet is a **single, complete sentence** — one period, no em-dash clauses or run-ons. It must be self-contained enough that a user understands the change without reading the body.
  - Prefix with a bracketed subsystem label: `**[rigor check]**`, `**[type system]**`, `**[baseline]**`, `**[plugins]**`, etc.
  - End with a GitHub issue / PR link and `thank you @handle!` when applicable.
- Child items (`  - …`) add supplementary detail: one topic per item, two to three sentences max. Use further nesting only to enumerate a short list.
- **Do not document internal changes.** Implementation detail (class renames, gemspec deletions, internal refactors, test coverage counts) is omitted unless it directly affects what users can do or observe. Ask: "Would a user care about this if they weren't reading the source?"
- A changelog entry is **not** a commit message, and its unit is the user-recognisable change, not the commit: many commits may collapse into one entry, and one change may span many commits. Write each entry user-facing from the start (see "When to write" above); cross-entry consolidation is the release-time job, not a deferred rewrite.

**Correct shape:**

```markdown
- **[rigor baseline generate]** Fixed a crash when `plugins:` entries in `.rigor.yml` were plain strings.

- **[plugins]** All bundled plugins now ship inside the `rigortype` gem, so `require "rigor-foo"` works without any `RUBYLIB` or `Gemfile` workaround.
  - Activate any plugin with one line in `.rigor.yml`: `plugins: [rigor-foo]`.
```

**Incorrect — do not write like this:**

```markdown
# ✗ two sentences joined by em-dash
- **[plugins]** All bundled plugins now ship inside the `rigortype` gem — `require "rigor-foo"` resolves without any workaround. Activate with `plugins: [rigor-foo]`.

# ✗ internal implementation detail as child item
  - Individual gemspecs inside `plugins/` are removed; the plugin family ships as a single unit.

# ✗ commit-message prose instead of user-meaningful description
- **[baseline]** Fix `group_for_baseline` to normalise paths to relative before building bucket keys.
```

The full release-prep flow (archival rule, link format, sealing `[Unreleased]`) is in [`.claude/skills/rigor-release-prep/SKILL.md`](.claude/skills/rigor-release-prep/SKILL.md).

## Verification Notes

After making changes, run:

```sh
nix … develop --command make verify
nix … develop --command git diff --check
```

Inside the Flake shell, `make verify` (without the prefix) is enough for the project checks.

If the Flake shell or its dependencies are unavailable, mention any skipped verification in the final report. For a minimal syntax-only check:

```sh
nix … develop --command sh -c 'for f in $(find bin exe lib spec -name "*.rb"); do ruby -c "$f" || exit 1; done'
```
