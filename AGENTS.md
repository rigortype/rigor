<!--
Maintainer notes. Block-level HTML comments are stripped before this file enters an agent's context,
so these cost nothing:

- Claude Code reads CLAUDE.md, not AGENTS.md; CLAUDE.md pulls this file in with `@AGENTS.md`.
- Everything here loads into every session. Keep it under ~200 lines, and keep it INSTRUCTIONS.
  Explaining why a rule exists earns its place only when the why changes what you do.
- Conditional material — needed only by a session already in its area — belongs in .claude/skills/
  or docs/, never here. ADR-97 carries the budget and the gate.
- Section names are load-bearing: "RBS Authorship" and "Release Cadence" are cited by § name from
  ADR-14, ADR-63, the handbook, and the plugin-author skill. Renaming them breaks those citations.
-->

# AGENTS.md

Agent contract for Rigor. Project-authored docs are written in English; vendored and submodule docs are
upstream material — do not rewrite them for language consistency.

## Development Environment

**IMPORTANT: every development command MUST run through the Nix Flake.** Never run `bundle`, `rake`,
`rspec`, `rubocop`, or `exe/rigor` from the host shell.

```sh
nix --extra-experimental-features 'nix-command flakes' develop                  # interactive shell
nix --extra-experimental-features 'nix-command flakes' develop --command <cmd>  # one-shot
```

Abbreviated `nix … develop --command` below; commands are otherwise shown in their in-shell form. If
`nix` is not on `PATH`, use `/nix/var/nix/profiles/default/bin/nix`.

- Target Ruby is `4.0.5`; the gemspec requires `>= 4.0.0`, `< 4.1`.
- `flake.nix` points Bundler at `vendor/bundle`, keeping gem installs off the machine's global state.
- First-time setup is `make setup`.
- Parallel or isolated work gets a worktree via `bin/rigor-worktree <branch>` — it copy-on-write
  clones `vendor/bundle` from the main clone (APFS clonefile), so every tree has an isolated,
  writable bundle instead of a shared `vendor` symlink. `references/` submodules are **not**
  populated in a worktree (pass `--with-references`), and `.git` is shared — never `git stash` or
  deregister a submodule from one. Full contract: the `rigor-worktree` skill.
- CI does **not** use Nix: it installs Ruby via `ruby/setup-ruby` and runs `make verify` directly.

## Common Commands

| Command | What it does |
| --- | --- |
| `make verify` | **The gate**: `test-binpacker` + `lint` + `check` + `check-plugins`. ≈60s on 12 cores. |
| `make test` / `make lint` | Spec suite / RuboCop alone. |
| `make check` | Rigor's self-check (`exe/rigor check lib`). MUST stay clean. |
| `make check-plugins` | Plugin-contract self-check over `plugins/*/lib examples/*/lib` ([ADR-43](docs/adr/43-rbs-complete-ancestor-resolution.md)). MUST stay clean. |
| `make docs-check` | Docs gates: link integrity, manual drift, agent-index budgets. |
| `make verify-sequential` | Use when chasing parallel-only flakes. |
| `make cache-clean` | Wipe `.rigor/cache` — the store never evicts ([ADR-6](docs/adr/6-cache-persistence-backend.md)), so stale slots accumulate. |
| `make steep-install`, `make steep-check` | Cross-checker pass, isolated under `tool/steep/Gemfile`. |

`exe/rigor help` lists the CLI. When diagnosing an inference gap, `rigor type-of FILE:LINE:COL` prints
the inferred type at a position and `rigor type-scan PATH` reports per-node-class coverage.

## Verification

**After any non-trivial change, run `make verify` then `git diff --check`**, inside the Flake.

`make check` and `make check-plugins` MUST stay clean. Fix the cause — an engine regression, a missing
per-class blocklist entry, or a genuine plugin-contract misuse — **never disable the rule**.

## Commit and PR Etiquette

- Imperative subject in sentence case. **No** Conventional-Commits `type:` / `area:` prefixes.
- Wrap the COMMIT body at ~72 columns; explain the *why*, never the diff.
- **Never wrap anything GitHub renders as Markdown** — a PR or issue body, a comment, a release body, a
  wiki page. GitHub turns a single newline inside a paragraph into `<br>`, so column-wrapped prose renders
  ragged. One line per paragraph and per list item, however long; tables, headings and fenced code keep
  their own line breaks. This is the same reason `CHANGELOG.md` entries are single long lines: the release
  section is extracted verbatim as the GitHub Release body. Wrapping is for commit messages, which are
  shown as preformatted text, and for files in the repo tree, which render as ordinary Markdown.
- Version bumps use the fixed form `Bump up version to x.y.z`.
- **Markdown-only changes commit straight to `master`** — CI skips the suite for an all-`.md` push
  (`paths-ignore`), so a docs PR buys only a redundant run. Never open a PR whose only change is
  `docs/CURRENT_WORK.md`. Anything touching a non-`.md` file is code: branch + PR.
- Push with an explicit refspec — `git push origin HEAD:refs/heads/<branch>`. This clone's
  `push.default` can otherwise land a bare `push -u` on `master`.
- **PRs are born Draft and stay Draft until they may land.** `gh pr ready` only on the user's
  explicit instruction to land that PR, with CI green on its head commit and no standing stop
  instruction. The instruction arrives in chat: this is a one-developer repository and every PR is
  opened under the user's account, so a GitHub APPROVE on it cannot exist (an author cannot approve
  their own PR) — never wait for one. A stop instruction becomes `gh pr ready --undo` at once.
  Draft is the one hold signal another session — or this one after compaction — can see
  ([postmortem](docs/notes/20260908-pr-788-draft-discipline-postmortem.md)).
- **Land your own audited+green PRs as you go; do not queue them.** In an autonomous session, merge
  each PR this session opened (`gh pr merge N --merge`) as soon as the diff is audited and
  `make verify` + CI are green; fork the next branch from post-merge `master`. If the merge is denied,
  say so immediately. Batching or stacking is reserved for changes the user must adjudicate as a set —
  deferral manufactures stacks and sibling conflicts ([ADR-105](docs/adr/105-pr-landing-flow.md)).
- **Another session's open PR or uncommitted tree is in-flight: hands off.** Do not commit, rebase,
  push, merge, or build on it until its owning session hands the lane over. A green gate is not a
  hand-over.
- **A fix for a bug report credits the reporter**: `Co-Authored-By: Name <email>` on every commit of
  the fix, fragment commit included, and `thank you @handle!` in the changelog entry. Ask for a missing
  email, never guess. This is credit to a person; AI attribution lines stay out of commits and PR bodies.

## Release Cadence

Normative in [ADR-50](docs/adr/50-release-engineering-and-stability-strategy.md) § WD5; the mechanical
flow is the `rigor-release-prep` skill.

- **The only release path is the user invoking `/rigor-release-prep`.** A release goal or date in a
  task is context, not that invocation: land the fixes, leave `[Unreleased]` and `changelog.d/`
  untouched, stop. `Rigor::VERSION`, `CHANGELOG.md` released-version sections, `Gemfile.lock`, and the
  README status line change only inside it; adding `## [Unreleased]` entries does not count.
- **Single-digit version components.** `0.0.9`'s successor is `0.1.0`, never `0.0.10`; `0.9.x`'s is
  `1.0.0`. Recursively, at every position.
- **Never run `bundle exec rake release`** without explicit authorisation — it tags, pushes, and
  publishes to RubyGems.
- Write each `## [Unreleased]` entry **user-facing at landing**, as if release notes were cut that day:
  one self-contained sentence under a `**[subsystem]**` label, no internal implementation detail, and
  the full markdown link to the PR that lands it. The commit body is where the engineering record goes.
  Full entry rules: the `rigor-release-prep` skill.
  - **The link is the half that gets more expensive to add later.** You know your own PR number now;
    recovering it at the cut costs a cycle-wide enumeration plus a per-entry match against it. v0.3.6
    reached its release with 21 entries and zero links, and reconstructing the 18 dominated the prep.
- **Entries land as fragment files, never as direct `[Unreleased]` edits.** Write
  `changelog.d/<section>/<branch-slug>.md` — one bullet line in the entry grammar above, `<section>`
  one of `added changed deprecated removed fixed security`. Release prep consolidates fragments into
  `CHANGELOG.md` at the cut; only release prep writes `[Unreleased]`. Gate:
  `spec/docs/changelog_fragments_spec.rb`. Why ([ADR-105](docs/adr/105-pr-landing-flow.md)): GitHub
  ignores `.gitattributes merge=union` for PR mergeability, so same-anchor entries serialized a
  19-PR queue into ~17 update+CI cycles; per-PR file additions cannot conflict. Do **not** skip the
  entry: the link is cheapest at landing (above). Reviewing the wording belongs **at the cut**,
  where release prep consolidates across the whole cycle anyway.

## Implementation Guidelines

- **Ruby application code MUST NOT require Rigor-specific annotations or DSLs.**
- **False positives outrank worst-case static reading.** "The program works" is the top-tier value;
  weigh FP cost heavily — in the engine, and equally in tooling and gates. A check that fires on
  correct input teaches people to route around it.
- CLI-first. Do not assume an LSP server or a long-running daemon.
- Keep metaprogramming support out of the core where possible; steer it toward the plugin API.
- **The spec binds, and an ADR only says why.** Type-model behaviour (normalization, narrowing,
  erasure, signature handling, diagnostic identifiers, budgets) is normative in
  [`docs/type-specification/`](docs/type-specification/README.md); analyzer-internal contracts
  (`Scope`, fact store, effect model, capability-role inference, type-object surface) in
  [`docs/internal-spec/`](docs/internal-spec/README.md). Update the topical document in the same commit
  as the behaviour.
- **Two trapped terms.** *Interface* is always structural here, and *protocol* means only
  [ADR-28](docs/adr/28-path-scoped-protocol-contracts.md)'s path-scoped behavioural contract. Check
  [`CONTEXT.md`](CONTEXT.md) before using either.

## Types and Comments

**A type that Rigor did not produce or check is not written down.** To learn a type, ask Rigor
(`rigor type-of`, `rigor annotate`, `rigor sig-gen --print`), never the surrounding code or a comment.
Types live in `sig/` (checked by `make check`) or are inferred. In `.rb` files a comment never carries
a type: doc tags are typeless YARD (`@param name description`, `@return description`,
`@raise ExceptionClass description`), and `#:` / `# @rbs` never appear under `lib/`, `plugins/*/lib`,
or `examples/*/lib` — the product default ([ADR-93](docs/adr/93-default-rbs-inline-ingestion.md))
would ingest them as live contracts. Gate: `spec/docs/type_shaped_comments_spec.rb`. A comment states
what the next lines and the signature do not — why (an ADR, an issue, a false-positive bound, a
declined alternative), a constraint the type system cannot express, what `nil` means — and never
restates a name, a type, or a signature. Why:
[ADR-107](docs/adr/107-checked-types-and-typeless-comments.md); the agent-facing form Rigor ships to
adopting projects: [ADR-108](docs/adr/108-type-provenance-for-agents.md).

**Prefer `rigor sig-gen` over hand-written or AI-authored RBS here** — a gap that pushes you toward
freehand RBS is information about where inference still has work, and **the gap is the more valuable
signal**. Propose `sig-gen --print` / `--diff` first; land a hand-edit only once the user has reviewed
that alternative. Correcting existing `.rbs` is fine when authorised, and reading it always is.
Rationale, the contradiction rule, and the full policy: [ADR-14](docs/adr/14-rbs-sig-generation.md).

Outside this repository, the shipped `rigor-type-oracle` skill carries the same rule for projects that
adopt it; where it is not adopted, treat AI-authored RBS normally.

## Repository Layout

Only what you would not guess from the tree:

- `plugins/` holds **production** plugins for real gems / frameworks; `examples/` holds
  **plugin-contract walkthroughs** over deliberately simplified use cases. A convention, not a size
  distinction. Each README carries the canonical inventory — the counts drift, so never hard-code them.
- `references/` holds read-only upstream submodules, **not** Rigor code: never require, import, or copy
  them into product code — read the behaviour, implement the smallest Rigor-side equivalent. `.ignore`
  hides them from `rg` (search one with `rg PATTERN --no-ignore references/rbs`). Drive their lifecycle
  through `make init-submodules` / `make pull-submodules`, never raw `git submodule update --recursive`
  — it bypasses the sparse checkouts. Catalog and breakage recovery: the `rigor-add-reference` skill.
- `docs/handbook/`, `docs/manual/`, `docs/types.md` are informational; `docs/type-specification/` and
  `docs/internal-spec/` bind.

## Where the Current State Lives

- [`docs/CURRENT_WORK.md`](docs/CURRENT_WORK.md) — the session handoff: what the next session enters
  on. Short-lived, replaced wholesale. Start here.
- **GitHub Issues** — the backlog, on `rigortype/rigor`. Every mid/long-term work item is an issue;
  release planning is the **Milestones** surface (`v0.3.0`, `v1.0.0`); an external PR is a triage
  surface too. Conventions: [`docs/agents/issue-tracker.md`](docs/agents/issue-tracker.md) and
  [`docs/agents/triage-labels.md`](docs/agents/triage-labels.md)
  ([ADR-98](docs/adr/98-development-flow-document-roles.md)). Do not add backlog sections to tracked
  markdown files.
- [`CONTEXT.md`](CONTEXT.md) — the domain glossary, carrying this repo's trapped terms; how the
  skills consume it is [`docs/agents/domain.md`](docs/agents/domain.md).
- `CHANGELOG.md` — what shipped, written for users; the detail is the git log.
- [`docs/adr/README.md`](docs/adr/README.md) — the complete ADR index (title + status). The decision
  itself is only ever in the ADR body.

## Architecture Decision Records

These are the **premises** — the decisions you would otherwise get wrong without knowing to look them
up. Every other ADR is a lookup: reach it through `docs/adr/README.md`, not from here
([ADR-97](docs/adr/97-adr-index-budgets.md)).

Foundation and conceptual core — what Rigor *is*:

- [ADR-0](docs/adr/0-concept.md) — Project concept and design boundaries
- [ADR-1](docs/adr/1-types.md) — Type model and RBS-superset strategy
- [ADR-2](docs/adr/2-extension-api.md) — Plugin extension API
- [ADR-3](docs/adr/3-type-representation.md) — Internal type-object representation
- [ADR-4](docs/adr/4-type-inference-engine.md) — Type inference engine
- [ADR-5](docs/adr/5-robustness-principle.md) — Robustness principle (Postel's law for types)

Standing policies, binding whatever a contribution touches:

- [ADR-31](docs/adr/31-contribution-and-supply-chain-policy.md) — Contribution + supply-chain policy
- [ADR-49](docs/adr/49-adr-authoring-guidelines.md) — ADR authoring guidelines (the quality rubric)
- [ADR-50](docs/adr/50-release-engineering-and-stability-strategy.md) — Release engineering and stability strategy
- [ADR-97](docs/adr/97-adr-index-budgets.md) — Index entries are not summaries: the ADR-index budgets and their gate
- [ADR-98](docs/adr/98-development-flow-document-roles.md) — Development-flow document roles: handoff, issues, changelog
