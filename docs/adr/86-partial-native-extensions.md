# ADR-86 — Partial native extensions for residual hot paths (rejected; rigor-rs owns native speed)

Status: **Accepted, 2026-07-14 — a standing REJECTION.** Replacing the remaining
hot paths with C / Rust / Go extensions was evaluated against the v0.3.0
campaign's closing profile and rejected: no residual kernel passes the
criterion below, and native-speed demand routes to the rigor-rs sibling port.
One demand-gated non-native candidate is recorded (WD4). Re-evaluation
triggers are explicit; this ADR exists so the question is not re-litigated
from zero.

Grounding: [`20260713-corpus-perf-campaign.md`](../notes/20260713-corpus-perf-campaign.md)
§ "Closing re-profile" (the residual-profile bucketing this decision reads).

## Context

After the v0.3.0 performance arc (PRs #74–#82: deferred YJIT, allocation-free
AST iteration, plugin-prepare caching, lazy/single-parse pre-pass, the
run-scoped return memo, pre-pass incrementalization), the residual profile no
longer contains a dominant pure-Ruby kernel. The natural next question —
"port just the hot paths to C/Rust/Go" — was evaluated against that measured
residual rather than against intuition.

The decisive observation: **the classically native-able hot paths are already
native.** `RBS::Parser._parse_signature` (18–27% of kramdown's residual cold
allocations) is the rbs gem's C parser; `Prism.parse` (~12% on
mastodon-models) is the same C library CRuby itself uses; Psych/YAML (~11%,
the i18n plugin's locale scan) is libyaml; SHA-256 digesting, Marshal, and
zlib are C. What Ruby pays around them is the call loop and the
materialization of Ruby objects — costs a native wrapper cannot remove
without changing what the API returns.

The two residual pure-Ruby costs:

1. **The inference engine itself** — the Rails-regime "flat" profile
   (`expression_typer` / `method_dispatcher` / `statement_evaluator` /
   `scope`, ~25% spread with no dominant frame). There is no narrow kernel to
   extract; porting it is porting the engine.
2. **The type-carrier equality / union-normalization kernel** — kramdown's
   top CPU self-cost (15.8% wall) but only 2–5% of residual allocations
   corpus-wide. Its operands are Ruby object graphs (nested ValueSemantics
   carriers), so a native implementation crosses the C↔Ruby boundary per
   field (`rb_funcall` / `rb_equal`) and gains little over YJIT'd Ruby; a
   real win requires moving the carrier REPRESENTATION native — i.e. the
   interning/hash-consing redesign already rejected three times on measured
   evidence (2026-06-20 ×2, the P9 probe) plus FFI complexity on top.

## Decision

**Do not add native extensions to the Ruby rigor.** The criterion a future
candidate must pass, all three parts:

1. **Representation-complete kernel** — a narrow, hot function whose inputs
   and outputs cross the FFI boundary wholesale (bytes/scalars/handles), with
   no per-element Ruby-object traffic inside the loop. (The equality kernel
   fails this; the parse/digest kernels already are native.)
2. **Not already winnable in Ruby** — the same speedup must not be available
   from YJIT'd Ruby, allocation removal, caching, or process/thread
   parallelism. Fine-grained C methods are opaque to YJIT and can regress
   against the JIT'd Ruby they replace (the P2 dispatch measurement is this
   session's in-family evidence for boundary costs deciding outcomes).
3. **Worth the platform tax** — the win must clear the standing costs a
   rigor-owned extension adds: the precompiled-gem platform matrix
   ([ADR-27](27-tool-distribution-model.md) /
   [ADR-31](31-contribution-and-supply-chain-policy.md)), the ruby.wasm
   playground build ([ADR-29](29-browser-playground.md)), and Ractor-safety
   ([ADR-15](15-ractor-concurrency.md) Phase 4).

**Division of labor:** users who need native speed are served by
**rigor-rs**, the sibling Rust port whose single-binary, Ruby-free goal is
already recorded as a deliberate design divergence
([ADR-79](79-rbs-version-range-over-pinned-determinism.md)). The Ruby rigor's
comparative advantage — the plugin ecosystem, in-process Ruby interop, the
wasm playground — is exactly what in-tree native fragments would erode while
duplicating rigor-rs's maintenance surface.

## Working decisions

- **WD1 — the already-native inventory is the first check.** Any future
  "port the hot path" proposal starts by classifying the frames: rbs C
  parser, prism, psych, digest/Marshal/zlib were all native before this ADR;
  their residual cost is Ruby-side materialization, not computation.
- **WD2 — the flat engine routes to rigor-rs, not to an extension.** No
  extractable kernel exists; a partial port would freeze an FFI boundary
  through the engine's most change-prone code (the same reason ADR-46
  rejected the Salsa-style rewrite: surface size).
- **WD3 — the equality kernel stays Ruby.** Representation-bound (criterion
  1), ceiling 2–5% of allocations / one regime's CPU, and the interning
  prerequisite carries the identity/FP risk already adjudicated. Its
  triple-negative probe history binds until a profile shows the bucket
  growing past ~15% corpus-wide.
- **WD4 — the one demand-gated candidate is not native-first.** The
  monorepo warm floor's glob+digest revalidation (~55% of gitlab-models'
  1.48s floor) is IO-shaped: try a pure-Ruby thread pool over the digest
  loop first (OpenSSL releases the GVL on large buffers; a half-day spike),
  then FS-event invalidation as part of the daemon/watch product decision,
  and only then a native batch hasher. Each step is gated on the previous
  one measuring insufficient.

## Rejected alternatives

- **C/Rust equality-and-normalization kernel** — criterion 1 failure +
  the interning prerequisite (WD3).
- **Native discovery/pre-pass walker** — post-[ADR-85](85-seed-bundles-and-lazy-def-node-handles.md)
  the pre-pass is cached on the paths that matter; its cold share is ~2–3%
  of a run. Dead ceiling.
- **Whole-engine extension** — that is rigor-rs by another, worse route.
- **Go specifically** — cgo's thread/runtime model makes an in-process
  fine-grained Ruby extension the worst FFI fit of the three named options;
  a Go sidecar process would be an IPC redesign, not a hot-path swap.

## Consequences

- Positive: the native question has a written answer with a reusable
  three-part criterion; the family strategy (Ruby rigor = ecosystem +
  compatibility + YJIT; rigor-rs = native speed) is explicit; the one
  IO-shaped candidate is staged cheapest-first.
- Negative: if a future workload surfaces a genuinely
  representation-complete hot kernel, this ADR must be revisited rather
  than quietly bypassed — that is intended friction.
- Re-evaluation triggers: (a) a profile showing a single pure-Ruby frame
  ≥15% corpus-wide that satisfies criterion 1; (b) the equality bucket
  growing past ~15% corpus-wide; (c) rigor-rs being abandoned (voids the
  division of labor); (d) the WD4 ladder exhausting its non-native rungs
  with the monorepo floor still dominant.

## Relationship to other ADRs

[ADR-79](79-rbs-version-range-over-pinned-determinism.md) records the
rigor-rs divergence this ADR leans on; [ADR-27](27-tool-distribution-model.md) /
[ADR-31](31-contribution-and-supply-chain-policy.md) /
[ADR-29](29-browser-playground.md) / [ADR-15](15-ractor-concurrency.md) own
the platform taxes in criterion 3; [ADR-83](83-dynamic-origin-algebra.md) is
the precedent for recording a measured rejection as an ADR; the
[campaign note](../notes/20260713-corpus-perf-campaign.md) carries the
residual-profile tables this decision reads.
