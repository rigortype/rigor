<!--
Maintainer notes. Block-level HTML comments are stripped before this file enters an agent's context.

- Claude Code reads CLAUDE.md, not AGENTS.md; CLAUDE.md imports this file.
- This file is loaded in every session. Keep it under ~200 lines and put conditional detail behind
  a pointer. The docs-check gate enforces the ADR premise-set cap (ADR-97); this file's own
  line-count target is not mechanically gated and can quietly regrow if nobody rechecks it.
- "RBS Authorship" and "Release Cadence" are cited section names; keep them stable.
-->

# AGENTS.md

Agent contract for Rigor. Project-authored docs are written in English; vendored and submodule docs are
upstream material and stay upstream.

## Operating rules

Read the pointer that matches the task; a typo fix does not require a repository tour. For a change
request, finish at the observable outcome requested, including its matching validation and handoff,
rather than stopping at the first plausible edit.

## Development Environment

Run every development command through the Nix Flake:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command <cmd>
```

Use an interactive `nix … develop` shell when useful. The Flake owns Ruby 4.0.5 and the vendored
`vendor/bundle`; `make setup` is the first-time setup. For isolated work, read
[`rigor-worktree`](.claude/skills/rigor-worktree/SKILL.md). CI is the exception: it installs Ruby with
`ruby/setup-ruby` and runs the targets `make verify` chains, plus further acceptance gates, directly.

## Validation

Local runs are targeted; the full gate is CI on the pull request.

- Before pushing: `make verify-changed` — whitespace, RuboCop, the affected specs, `spec/docs/`, and
  `rigor check` over what the branch changed, in under a minute. It lists what it cannot cover; CI
  decides those.
- Do not run `make verify`, `make check`, or the whole suite locally. Parallel sessions each running
  it were the bottleneck (five at once took 12–20 minutes each), and CI runs a superset. Run one
  only to reproduce a failure CI does not explain, or for a Flake-environment change CI cannot see.
- A Markdown-only push straight to `master` skips CI: run `make docs-check` first. A Markdown-only
  PR runs it in CI. `make verify-sequential` is for investigating parallel-only flakes.

Keep `make check` and `make check-plugins` clean; CI runs each as its own gate. Fix the cause — an
engine regression, a missing blocklist entry, or a plugin-contract misuse — instead of weakening a
rule.

When a task measures rather than gates — running the engine against a survey project, diffing corpus
diagnostics, benchmarking, or probing an inferred type — read
[`docs/agents/measurement.md`](docs/agents/measurement.md) first. It collects the ways a probe
returns a confident wrong answer.

## Contribution and release flow

Before committing, pushing, opening/landing a PR, or preparing a release, read
[`docs/agents/contribution-flow.md`](docs/agents/contribution-flow.md). It contains the conditional
GitHub Markdown, branch, draft-PR, changelog-fragment, release, and reporter-credit rules.

A change request ends at its landing, not at a local diff: push a Draft PR, run CI and an
independent adversarial review in parallel, apply what they find, and merge when the landing point
was settled in advance. The loop, its round rule, and the reviewer model are in § "Landing a pull
request" there.

## Implementation Guidelines

- Ruby application code does not require Rigor-specific annotations or DSLs.
- False positives outrank worst-case static reading: weigh the cost of a finding on correct programs
  heavily in the engine, tooling, and gates.
- CLI-first; keep metaprogramming support in the plugin API where possible.
- The spec binds and an ADR explains why. When behaviour changes, update the topical document in
  [`docs/type-specification/`](docs/type-specification/README.md) or
  [`docs/internal-spec/`](docs/internal-spec/README.md) in the same change.
- In this repository *interface* means structural typing, and *protocol* means ADR-28's path-scoped
  behavioural contract. Check [`CONTEXT.md`](CONTEXT.md) before using either term.

## Types and Comments

When writing or asserting a type, or a comment that could be read as one, load
[`docs/agents/type-authoring.md`](docs/agents/type-authoring.md). It contains the provenance,
typeless-comment, inline-annotation, and gate rules.

## RBS Authorship

When editing `.rbs`, prefer `rigor sig-gen` and surface an inference gap before hand-authoring a
signature. Follow [`docs/agents/type-authoring.md`](docs/agents/type-authoring.md) for the exceptions
and the review boundary; the section name is retained for existing cross-references.

## Repository Layout

- `plugins/` is production support for real gems/frameworks; `examples/` is plugin-contract walkthroughs.
  Their READMEs are the inventories; do not hard-code counts.
- `references/` contains read-only upstream submodules, never Rigor code. Read behavior there and
  implement the smallest Rigor-side equivalent. Use `make init-submodules` / `make pull-submodules`;
  the [`rigor-add-reference`](.claude/skills/rigor-add-reference/SKILL.md) workflow owns lifecycle and
  recovery.
- `docs/handbook/`, `docs/manual/`, and `docs/types.md` are informational. The type and internal specs
  are binding.

## Where the Current State Lives

- [`docs/CURRENT_WORK.md`](docs/CURRENT_WORK.md) is the transient session handoff; replace it wholesale.
- GitHub Issues hold the backlog for `rigortype/rigor`; Milestones hold release planning. Use
  [`docs/agents/issue-tracker.md`](docs/agents/issue-tracker.md) for issue and triage conventions.
- [`CONTEXT.md`](CONTEXT.md) is the domain glossary. `CHANGELOG.md` is the user-facing shipped record.
  [`docs/adr/README.md`](docs/adr/README.md) is the complete ADR index; open an ADR body for its decision.

## Release Cadence

The release rules are conditional and live in [`docs/agents/contribution-flow.md`](docs/agents/contribution-flow.md).
An issue, date, or release goal does not activate them; only the user's explicit `/rigor-release-prep`
invocation starts release preparation.

## Architecture Decision Records

These are the premises — decisions an agent would get wrong without knowing to look them up. Every
other ADR is a lookup through [`docs/adr/README.md`](docs/adr/README.md), per [ADR-97](docs/adr/97-adr-index-budgets.md).

Foundation and conceptual core:

- [ADR-0](docs/adr/0-concept.md) — project concept and design boundaries
- [ADR-1](docs/adr/1-types.md) — type model and RBS-superset strategy
- [ADR-2](docs/adr/2-extension-api.md) — plugin extension API
- [ADR-3](docs/adr/3-type-representation.md) — internal type-object representation
- [ADR-4](docs/adr/4-type-inference-engine.md) — type inference engine
- [ADR-5](docs/adr/5-robustness-principle.md) — robustness principle

Standing policies:

- [ADR-31](docs/adr/31-contribution-and-supply-chain-policy.md) — contribution and supply-chain policy
- [ADR-49](docs/adr/49-adr-authoring-guidelines.md) — ADR authoring quality rubric
- [ADR-50](docs/adr/50-release-engineering-and-stability-strategy.md) — release engineering
- [ADR-97](docs/adr/97-adr-index-budgets.md) — ADR index budgets and gate
- [ADR-98](docs/adr/98-development-flow-document-roles.md) — development-flow document roles
