# ADR-93 — Default rbs-inline ingestion: reconciling ADR-32's opt-in with the always-parse spec

Status: **Proposed, 2026-07-16.** Measurement-gated (WD4); nothing implemented. The
divergence this reconciles is marked in
[`overview.md`](../type-specification/overview.md) § "Compatibility hierarchy" per
[ADR-92](92-normative-status-fidelity.md).

Grounding: [`docs/notes/20260716-dspec-formal-spec-substrate-evaluation.md`](../notes/20260716-dspec-formal-spec-substrate-evaluation.md)
§ "第四の事例" — the adjudication, with the timeline and the upstream `disabled`-handling
verification.

## Context

The binding spec ([`overview.md`](../type-specification/overview.md), 2026-04-28) makes
inline rbs-inline annotations **official type sources**: "always parsed and used whenever
present", "MUST NOT require `# rbs_inline: enabled` to begin parsing them", with only the
upstream configuration directives interpreted (so `# rbs_inline: disabled` remains the
per-file opt-out). [ADR-32](32-rbs-inline-comment-ingestion.md) (2026-05-25, shipped
v0.1.10) contradicts it on both axes without citing it: ingestion is an opt-in plugin, and
the plugin's WD2 default requires the magic comment — listing the spec-mandated always-on
behaviour as a rejected alternative. Per CLAUDE.md the spec binds, so the shipped default is
non-conforming.

The practical cost is real: a user writing `def foo #: void` — a form the spec's own style
guidance *strongly recommends* — gets silence through three stacked gates (plugin not
configured, magic comment absent, upstream's top-level-def gap), and nothing tells them
which gate ate the annotation.

Two facts make reconciliation cheap. Upstream honours `# rbs_inline: disabled`
**unconditionally** (`rbs-inline` `parser.rb:73`, checked before the `opt_in` branch), so
the plugin's existing `require_magic_comment: false` mode (ADR-32 WD10) is *exactly* the
spec's semantics — parse whenever present, `disabled` opts out. And the bundled plugin plus
the upstream library are already the vendored, reviewed code path; no new code source is
introduced by wiring them on.

## Decision

> **The spec's activation model is the contract: annotation comments are type sources
> whenever present, and only the upstream configuration directives gate them. Conformance is
> delivered by wiring and defaults — never by re-implementing the grammar (ADR-32 WD1/WD3
> stand) and never by narrowing the spec to bless the accident.**

## Working decisions (proposed shapes, open to adjustment)

**WD1 — flip the plugin's `require_magic_comment:` default to `false`.** For a project that
has already configured the plugin, annotations outside magic-comment files start binding.
This is a diagnostic strengthening, which [ADR-50](50-release-engineering-and-stability-strategy.md)
allows in a minor (output is non-contract; the baseline absorbs); the per-file escape stays
(`# rbs_inline: disabled`), and the old behaviour stays one config line away. ADR-32 WD2's
upstream-alignment rationale does not survive contact with a binding MUST NOT.

**WD2 — default-wire the bundled plugin, presence-gated.** When the upstream `rbs-inline`
library is resolvable — in Rigor's own environment or through the analyzed project's bundle
per [ADR-90](90-target-library-resolution-from-project-bundle.md)'s fallback — the bundled
plugin activates without a `plugins:` entry, in WD1's conforming mode. This deliberately
reverses [ADR-27](27-tool-distribution-model.md)/[ADR-31](31-contribution-and-supply-chain-policy.md)'s
auto-load deferral for **one bundled plugin**, on three grounds recorded here: the spec
binds; the executed code is the already-bundled plugin plus its declared upstream dependency
(not arbitrary third-party plugin code — the case the deferral guards); and the gate is
[ADR-72](72-gemfile-lock-gated-rbs-overlays.md)'s shape, keyed on what is actually on disk.
Opt-out surface: project-level (a `plugins:` entry disabling it — exact shape open, the
plugin-entry schema has no `enabled:` key today) and per-file (`# rbs_inline: disabled`).

**WD3 — the standalone residual.** A bare `gem install rigortype` has no `rbs-inline`
library anywhere, and "always parsed whenever present" cannot be satisfied without one. The
honest options: (i) promote `rbs-inline` to a core runtime dependency — its dependency
closure is `prism` + `rbs`, both already required, but it adds a versioned surface and
contradicts [ADR-0](0-concept.md)'s zero-dep stance; (ii) keep the residual marked in
`overview.md` and emit a routing hint (an `rbs.coverage.*`-style `:info`) when
annotation-shaped comments are seen with no synthesizer available. Deferred to the WD4
measurement; (ii) is the conservative default.

**WD4 — measurement gate before any default flips.** A corpus sweep with WD1+WD2 active:
count files carrying annotation-shaped comments without the magic comment, and adjudicate
every new diagnostic per the ADR-57 protocol (genuine = the spec working; artifact = fix at
root). The known upstream top-level-def gap (ADR-32 WD9) is measured, not assumed, and its
routing (hint vs upstream issue) decided on the numbers.

## Rejected alternatives

- **Re-implement the annotation grammar in core.** ADR-32 WD1's grammar-drift rejection
  stands; the binding clause mandates behaviour, not an implementation route.
- **Narrow the spec MUST to match ADR-32.** It reverses a founding commitment ("official
  type sources") that the user report validates, and the clause predates the ADR — the
  accident does not get to rewrite the intent it violated.
- **Keep the status quo unmarked.** Forbidden by ADR-92; the marker already landed.

## Consequences

- Positive: the spec, the ADR corpus, and the shipped default stop disagreeing; `#: void`
  and friends work out of the box wherever the library exists, which is what both the spec
  and the user report ask for.
- Negative / cost: a behaviour-changing default (bounded by WD4's adjudication + the
  baseline); a recorded partial reversal of the ADR-27/31 deferral; WD3's residual keeps a
  marker alive until resolved.
- Carry-over: the opt-out schema for default-wired plugins (WD2); the WD3 choice.

## Relationship to other ADRs

- **ADR-32** — the contract this amends: WD2's default and the opt-in activation are
  superseded on acceptance; WD1/WD3/WD4–WD10 (upstream library, synthesizer hook, caching,
  fail-soft) are untouched.
- **ADR-92** — supplies the criterion that forced the reconciliation and holds the marker.
- **ADR-72 / ADR-90** — the presence-gated shape and the bundle-fallback resolution WD2
  composes.
- **ADR-27 / ADR-31** — the auto-load deferral WD2 partially and explicitly reverses.
- **ADR-50** — classifies WD1/WD2 as minor-legal strengthenings; WD4 is their gate.
