# ADR-79 — RBS version-range fidelity over checker-pinned determinism

Status: **Accepted, 2026-06-26.** Rigor keeps reading core/stdlib RBS from the `rbs`
gem the project resolves within the gemspec's `rbs >= 3.0, < 5.0`; version-driven diagnostic
variation is treated as correct-by-construction, not a determinism defect. Determinism is
bought tactically (the rbs-compat CI matrix + the `core_overlay` / `gem_overlay` escape
hatches), and a Rigor-held bundled core RBS is recorded as a **deferred, opt-in** option —
not adopted.

Grounding: upstream [rigortype/rigor#22](https://github.com/rigortype/rigor/pull/22)
("Fix RBS 3.x compatibility", fixes #21) which added the `Gemfile.rbs-compat` CI job running
the env specs against both `~> 3.10` and `~> 4.0`; the
[2026-06-16 liquid v5.x sweep note](../notes/20260616-liquid-v5.x-regression-sweep.md)
(the `StringScanner#peek_byte` version-lag FP); the rigor-rs port's design audit
([2026-06-26 note](../notes/20260626-rigor-rs-design-audit.md), risk R2).

## Context

Rigor type-checks against the RBS its **own resolved `rbs` gem** ships, anywhere in the
gemspec range `rbs >= 3.0, < 5.0` (`rigor.gemspec:50`). That width is deliberate: users pin
Ruby and `rbs` to suit their projects, and Rigor follows rather than dictating a version.
PR #22 hardened the loader (`rbs_loader.rb`) to work across the whole range and added a CI
matrix so the range stays honest.

The consequence the rigor-rs port flagged: because core-class signatures differ between `rbs`
releases (e.g. `String#bytes`, `StringScanner#peek_byte`), the *same source* can produce a
different diagnostic set under `rbs 3.10` vs `4.0.2` — across a developer's machine and CI, or
between two developers. rigor-rs resolved this on its side by **vendoring and embedding** core
RBS at build time (its ADR-0007), making `embedded == runtime` byte-deterministic. The open
question for the Ruby reference: should it do the same?

## Decision

**Rigor checks against the RBS the project's own toolchain ships. Variation in diagnostics
across `rbs` versions is fidelity to what the project actually runs, not a bug to engineer
away.**

The discriminating criterion — the reusable rule:

> **Fidelity to the installed toolchain outranks cross-environment bit-determinism.**
> Determinism is bought *tactically* only where a version gap yields a **wrong** result (a
> false positive on a method that exists at runtime), never *structurally* by freezing the
> RBS source away from the project's actual `rbs`.

Concretely:

- **Keep `rbs >= 3.0, < 5.0`.** PR #22's `Gemfile.rbs-compat` CI matrix (`~> 3.10` ∧ `~> 4.0`)
  is the guardrail that keeps the supported range real.
- **Patch version-lag *false positives* at the source**, not the version: the unconditional
  Rigor-owned `data/core_overlay/` reopen (`rbs_loader.rb` `core_overlay_sig_paths`, e.g. the
  `StringScanner` methods `rbs 4.0.2` omits) and the ADR-72 Gemfile.lock-gated
  `data/gem_overlay/` for `:missing`-RBS gems. Rigor therefore *already* holds a small,
  surgical slice of its own core RBS — used to fix wrongness, not to replace the source.

## Deferred alternative — a Rigor-held bundled core RBS (not adopted)

Vendoring/embedding a full core+stdlib RBS as Rigor's source of truth (rigor-rs's route) buys
cross-environment determinism, but is rejected **as the default** because:

1. It **decouples diagnostics from the project's actual `rbs`/Ruby** — Rigor would report
   against a version the project may not run, reintroducing the very fidelity gap the
   wide-range support exists to close.
2. It adds a standing **maintenance burden** to track each upstream `rbs` release (the same
   release-cadence cost the rigor-rs audit recorded as R2 for the embedded approach).
3. It **duplicates** what `core_overlay` already does tactically and proportionately.

**Re-evaluation trigger:** if cross-environment *nondeterminism* — diagnostic drift between
CI and dev not attributable to a fixable overlay gap — becomes a demonstrated support cost,
revisit, scoped as an **opt-in pinned-RBS mode** (a config-selected vendored core), so
fidelity-to-installed stays the default and determinism is a deliberate per-project choice.
rigor-rs's vendor+embed is the reference design for that mode if it lands.

## Consequences

- **Positive:** diagnostics reflect the toolchain the project runs; wide Ruby/`rbs` support is
  preserved; no new vendoring or version-tracking surface.
- **Negative:** cross-environment determinism stays best-effort — a new `rbs` release can shift
  diagnostics until a `core_overlay` patch lands. Bounded by the compat CI matrix (breakage is
  caught) and the two overlay escape hatches (wrongness is patchable without a Rigor release
  pinning `rbs`).
- **Carry-over:** the opt-in pinned-RBS mode remains a live, unbuilt option behind the
  re-evaluation trigger above.

## Relationship to other ADRs

- **ADR-72** — the Gemfile.lock-gated `gem_overlay` is the conditional twin of the
  unconditional `core_overlay` this ADR leans on for tactical determinism.
- **ADR-54 / ADR-7** — cache + RBS shipping; the overlay dirs ride in the loader signature
  paths the env-cache descriptor already digests.
- **rigor-rs ADR-0007** (sibling Rust port) — adopts the *opposite* default (vendor + embed)
  for its single-binary, Ruby-free distribution goal; this ADR records the reference's
  deliberate divergence and the conditions under which it would converge.
