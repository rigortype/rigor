# CLAUDE.md

Project-level briefing for Claude (and any other agent that reads top-level docs by convention). The authoritative agent contract for this repository is [`AGENTS.md`](AGENTS.md) — read it first; this file is a navigation index that points at the documents an agent typically needs and the per-task skills bundled with the project.

## Read these first

| Document | Purpose |
| --- | --- |
| [`AGENTS.md`](AGENTS.md) | Development environment (Flake mandate, target Ruby), common commands, directory layout, references/ submodule rules, implementation guidelines, commit-message style, and verification protocol. **Required reading.** |
| [`README.md`](README.md) | User-facing project overview (CLI, what `rigor check` does today). |
| [`docs/types.md`](docs/types.md) | One-page quick guide to the Rigor type system. Start here for the type model mental model. |
| [`docs/MILESTONES.md`](docs/MILESTONES.md) | Release-by-release commitment envelope. v0.0.3 (released), v0.0.4 (planned), v0.1.0 (long horizon — caches and plugin API). |
| [`docs/CURRENT_WORK.md`](docs/CURRENT_WORK.md) | Resume bookmark for the next implementer. Names the highest-leverage v0.0.4 slice, parallel-safe entry points, and open engineering items. Transient. |

## Authoritative specifications

When a change touches type-language behaviour or analyzer-internal contracts, the spec binds. ADRs record design rationale and rejected/deferred alternatives.

### Type specification (normative)

| Document | Scope |
| --- | --- |
| [`docs/type-specification/README.md`](docs/type-specification/README.md) | Reading order + RFC 2119 conventions for the spec corpus. |
| [`docs/type-specification/overview.md`](docs/type-specification/overview.md) | Core principle (RBS superset), design priorities. |
| [`docs/type-specification/robustness-principle.md`](docs/type-specification/robustness-principle.md) | Postel's law for types — strict on returns, lenient on parameters. The asymmetric authorship rule every Rigor-authored type observes. |
| [`docs/type-specification/relations-and-certainty.md`](docs/type-specification/relations-and-certainty.md) | Subtyping (`<:`) and gradual consistency, trinary certainty. |
| [`docs/type-specification/value-lattice.md`](docs/type-specification/value-lattice.md) | Lattice identities and `Dynamic[T]` algebra. |
| [`docs/type-specification/special-types.md`](docs/type-specification/special-types.md) | `top`, `bot`, `untyped`/`Dynamic[T]`, `void`, `nil`, `bool`/`boolish`. |
| [`docs/type-specification/rbs-compatible-types.md`](docs/type-specification/rbs-compatible-types.md) | RBS forms accepted by Rigor. |
| [`docs/type-specification/rigor-extensions.md`](docs/type-specification/rigor-extensions.md) | Refinements and other internal-only forms beyond RBS. |
| [`docs/type-specification/imported-built-in-types.md`](docs/type-specification/imported-built-in-types.md) | Reserved built-in refinement names (`non-empty-string`, `positive-int`, …). |
| [`docs/type-specification/type-operators.md`](docs/type-specification/type-operators.md) | `~T`, `T - U`, indexed access, display contract. |
| [`docs/type-specification/structural-interfaces-and-object-shapes.md`](docs/type-specification/structural-interfaces-and-object-shapes.md) | RBS interfaces, inferred object shapes, capability roles. |
| [`docs/type-specification/control-flow-analysis.md`](docs/type-specification/control-flow-analysis.md) | Edge-aware narrowing, equality semantics, fact stability, mutation effects. |
| [`docs/type-specification/rbs-extended.md`](docs/type-specification/rbs-extended.md) | `%a{rigor:v1:…}` annotations, predicate / assertion / return-override grammar. |
| [`docs/type-specification/normalization.md`](docs/type-specification/normalization.md) | Deterministic normalization rules. |
| [`docs/type-specification/rbs-erasure.md`](docs/type-specification/rbs-erasure.md) | Conservative erasure to RBS. |
| [`docs/type-specification/inference-budgets.md`](docs/type-specification/inference-budgets.md) | Budget table and boundary contracts. |
| [`docs/type-specification/diagnostic-policy.md`](docs/type-specification/diagnostic-policy.md) | Diagnostic identifier taxonomy and suppression markers. |

### Analyzer-internal contracts (normative)

| Document | Scope |
| --- | --- |
| [`docs/internal-spec/README.md`](docs/internal-spec/README.md) | Index of analyzer-side surfaces. |
| [`docs/internal-spec/internal-type-api.md`](docs/internal-spec/internal-type-api.md) | Public type-object surface (the contract every `Rigor::Type::*` carrier satisfies). |
| [`docs/internal-spec/inference-engine.md`](docs/internal-spec/inference-engine.md) | Engine surface (`Scope`, fact store, effect model, capability-role inference, normalization, RBS erasure routing). |
| [`docs/internal-spec/implementation-expectations.md`](docs/internal-spec/implementation-expectations.md) | Engine-surface stability and public-API contract. |

### Architecture decision records (rationale)

| ADR | Topic |
| --- | --- |
| [`docs/adr/0-concept.md`](docs/adr/0-concept.md) | Project concept and design boundaries. |
| [`docs/adr/1-types.md`](docs/adr/1-types.md) | Type model and RBS-superset strategy. |
| [`docs/adr/2-extension-api.md`](docs/adr/2-extension-api.md) | Plugin extension surface (deferred to v0.1.0). |
| [`docs/adr/3-type-representation.md`](docs/adr/3-type-representation.md) | Internal type-object layout. Working decisions for OQ1 (Constant scalar shape — Hybrid), OQ2 (predicate naming — drop the `?`), OQ3 (refinement carrier — Difference + Refined). |
| [`docs/adr/4-type-inference-engine.md`](docs/adr/4-type-inference-engine.md) | Inference-engine architecture. |
| [`docs/adr/5-robustness-principle.md`](docs/adr/5-robustness-principle.md) | Design rationale for Postel's law. Companion to `docs/type-specification/robustness-principle.md`. |

## Skills available in this repository

The `.codex/skills/` tree carries per-task playbooks. Each skill has a `SKILL.md` describing when to invoke it and what steps it codifies.

| Skill | Use when |
| --- | --- |
| [`.codex/skills/rigor-release-prep/SKILL.md`](.codex/skills/rigor-release-prep/SKILL.md) | Preparing a RubyGems release: bumping `Rigor::VERSION`, updating `CHANGELOG.md` (Keep a Changelog 1.1.0), regenerating `Gemfile.lock`, building the gem, and running `bundle exec rake release`. |
| [`.codex/skills/rigor-builtin-import/SKILL.md`](.codex/skills/rigor-builtin-import/SKILL.md) | Importing a Ruby core / stdlib class into Rigor's catalog-driven inference pipeline. Records the nine-stage flow (locate sources → extend `TOPICS` → regenerate YAML → wire loader → curate `:leaf` blocklist → decide RBS::Extended overrides → fixture → verify → changelog) and the decision points where the procedure is NOT mechanical. |

## Commit message style (mirrors AGENTS.md)

- Plain imperative subject in sentence case. No Conventional-Commits-style `type:` or `area:` prefixes.
- Subject is self-contained and reasonably short; detail belongs in the body.
- Wrap the body at ~72 columns; explain the why, not the diff.
- Release version bumps follow the fixed form `Bump up version to x.y.z`.

## Verification protocol (mirrors AGENTS.md)

After non-trivial changes, run:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command make verify
nix --extra-experimental-features 'nix-command flakes' develop --command git diff --check
```

`make verify` chains `make test`, `make lint`, and `make check`. The last target (`bundle exec exe/rigor check lib`) is the project's own self-check — it MUST stay clean. False positives there indicate either an engine regression or a missing per-class blocklist entry; fix the cause rather than disabling the rule.

If the Flake shell is unavailable, mention any skipped verification in the final report.

## Notes for delegated agents

- Do NOT bypass the Flake. `bundle`, `rake`, `rspec`, `rubocop`, and `exe/rigor` MUST run inside `nix … develop` per AGENTS.md.
- Do NOT modify `references/` submodules unless the task is "bump references/<name>". The vendored sources are read-only; engine changes happen against Rigor's own code.
- Do NOT run `bundle exec rake release` without explicit user authorisation. The release task tags `vx.y.z`, pushes to origin, and publishes to RubyGems.
- The reading order for a returning implementer is in [`docs/CURRENT_WORK.md`](docs/CURRENT_WORK.md). It points back at the relevant ADRs and skills for the v0.0.4 work.
