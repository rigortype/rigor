# rigor-rs design audit — does the Rust reimplementation avoid the Pzoom trap?

Status: external-project design audit, authored 2026-06-26. Companion to
[`20260626-pzoom-port-and-rigor-architecture.md`](20260626-pzoom-port-and-rigor-architecture.md).
Audits the design docs of **rigor-rs** (`/Users/megurine/repo/rust/rigor-rs`), a Rust
reimplementation of Rigor maintained by the same author, against the lesson of Matt Brown's
[*From Psalm to Pzoom*](https://mattbrown.dev/articles/from-psalm-to-pzoom). Non-normative;
this repo's ADRs/spec bind. rigor-rs is actively under construction — this is a snapshot
audit of ADR-0001…0031 + `CONTEXT.md` + `CURRENT_WORK.md` + the 2026-06-26 spike findings as
they stood on the audit date.

## Why this audit exists

The strategic motive for rigor-rs is **preemption**: ship a well-built Rust alternative before
someone else publishes a worse one ("a faster Rust Rigor") that proliferates on the strength
of a benchmark number while being unsound. The Pzoom note established the structural reason a
compiled port of a dynamic-language analyzer fails to get adopted — loss of scan-time
execution, i.e. the plugin ecosystem. This audit asks whether rigor-rs's design actually
escapes that trap, and whether its shape serves the preemption goal.

## Verdict — it avoids the trap structurally

rigor-rs is not a naive "rewrite it in Rust" attempt. It answers Pzoom's root cause head-on
with an optional, cached **Ruby sidecar** (ADR-0008), and it studies the relevant failure
cases by name and designs around each:

| Precedent | Failure mode | rigor-rs countermeasure |
|---|---|---|
| **Pzoom** | Compiling away scan-time execution → plugins don't run → not adopted | **Ruby sidecar** (ADR-0008/0013): the folding long tail and all plugin target-library invocations run in the project's real Ruby |
| **artichoke** | Reimplementing Ruby itself = unbounded surface area | Parity is scoped to **Rigor's diagnostic behaviour** (ADR-0001), not Ruby execution semantics |
| **pylyzer** | Parasitizing a foreign inference engine → correctness ceiling | Reuse **only the parser/data** (prism, ruby-rbs); the index *and* inference engine are owned in Rust (ADR-0004) |

Distinguishing those three failure modes is rare. ADR-0004's demotion of Rubydex from
"default backend" to "optional accelerator behind a trait" — justified explicitly by the fact
that Pzoom hand-built its own populator — is the sharpest single call in the corpus.

## Strengths

1. **Parity contract discipline (ADR-0002/0011).** The correctness bar is set-equality of
   `(rule id, location)` pairs, leaving message wording free to improve. The differential
   harness is a **one-sided gate**: if rigor-rs emits a diagnostic the reference does not, the
   build fails. That mechanizes Rigor's zero-false-positive rule directly. Currently green at
   7/7, 0 FP. This is the "tests as equivalence oracle" lesson from Pzoom, hardened into "diff
   against the live reference."
2. **Divergence-registry loophole armor (ADR-0011).** "Don't reproduce reference bugs
   bug-for-bug" is permitted but fenced: upstream report required + reviewer sign-off + every
   *unregistered* divergence is red. Closes the "declare any inconvenient divergence a defect"
   escape hatch.
3. **Sound degradation (ADR-0008).** With no sidecar, analysis widens/declines to a
   **zero-FP sound subset** (fewer diagnostics, none wrong) — matching the reference's
   decline-to-silence discipline.
4. **Never-crash isolation (ADR-0016) + budget on-hit policy (ADR-0024).** "Never error on
   working code" is preserved: a budget hit widens and emits at most an `:info` `static.*`
   note. The top Rigor value — don't frighten working code — is inherited.
5. **Drop-in compatibility (ADR-0009/0014/0015/0030/0031).** Config winner-takes-all,
   warn-and-ignore unknown keys, full CLI surface with explicit "not implemented", and the
   severity-resolution / suppression-order / rule-id taxonomy all map onto the reference.

A point worth recording because it inverts an initial audit finding: a sub-agent flagged that
rigor-rs "ships precision budgets the reference hasn't wired" as a parity/FP break. The ADR
text refutes this — ADR-0024 says rigor-rs **MUST NOT** enforce `union_size` /
`structural_growth` until the parity snapshot reflects their activation, shipping only the
named constants so later config wiring is non-breaking. That is the correct handling and a
credit, not a risk. (Lesson: verify a sharp criticism against the source before ranking it.)

## Risks and gaps (priority order)

**R1 — the sidecar/standalone dilemma (most important; strategic).** "Single static binary,
no Ruby runtime" and "full parity" cannot both hold at once. Standalone-Rust mode is only a
sound subset — it *silently drops* some diagnostics; full parity needs the project's Ruby
sidecar. The docs are honest about this (a credit), but it is exactly the structural fact
Pzoom hit. The "bad competitor" this project wants to preempt will market itself as "pure
Rust, no sidecar" and *look* faster on a benchmark. The defense is positioning, not code:
win the message that "sidecar-less pure Rust silently misses bugs." Worth promoting to an
explicit product-positioning statement, plus CLI/`doctor` surfacing of coverage loss when the
sidecar is absent.

**R2 — embedded-RBS staleness (ADR-0007).** Vendoring/embedding RBS at build time couples
stdlib-RBS fixes to rigor-rs's release cadence; the Ruby tool can ship a fix by bumping a gem.
A Pzoom-shaped residual weakness. No out-of-band refresh path is specified — though the
interim `RIGOR_RBS_CORE_DIR` runtime path (ADR-0004) is a natural seam to formalize as the
"update stdlib RBS without a rebuild" route.

**R3 — chasing a moving reference (the Pzoom maintenance warning, literally).** The reference
has ~78 ADRs, many in-flight (ADR-46 incremental; ADR-66/67/68 proposed). rigor-rs owes
perpetual follow. Snapshot-pinning + the registry are good governance, but the registry
presumes an upstream tracker (`rigortype/rigor`) that should be confirmed to exist, and
"trends toward empty" assumes upstream responsiveness. One maintainer on both sides helps
coordination but is the **double-maintenance cost** Pzoom quantified (~100 h, ~$2k). ADR-0001
should state the **exit condition** — when Ruby Rigor is retired and the implementation
re-unifies — to avoid drifting into the indefinite split ADR-0001 itself rejected.

**R4 — ADR spec density / parity-execution risk.** Several ADRs delegate the load-bearing
algorithm to "the reference spec binds": normalizing-builder operand ordering (ADR-0005/0020),
the "related class" definition in the overridable-method gate (ADR-0023), and whether a
`maybe`-purity unknown call sweeps `object-content` in the invalidation cascade (ADR-0022).
Acceptable for an ADR (rationale, not spec), but it concentrates parity risk in the
implementation + harness. The harness is the safety net and is green — but the corpus is only
7 fixtures. **Landing OSS corpora (Redmine/Mastodon) is the urgent next step** (already noted
in CURRENT_WORK §14); the subtle cases won't surface on 7 files.

**R5 — self-invented `internal-error` rule id.** CURRENT_WORK admits this id has no reference
counterpart, so the one-sided gate treats it as an FP in principle. Decide early: align to the
reference's crash behaviour or register it formally in ADR-0016.

## Fit against the preemption goal

**High.** The design is the "good version published first to crowd out the bad version."
Everything a naive challenger omits — a zero-FP differential harness, owning the engine
(avoiding parasitism), the sidecar that preserves scan-time execution, drop-in config/CLI/
baseline compatibility — is central here. The biggest vulnerability is not technical: it is
communicating that "pure Rust is fast but silently misses bugs" (R1), defended through
positioning, docs, and a `doctor`-style "sidecar absent ⇒ reduced coverage" signal.

## Recommended actions (priority order)

1. **Make R1 explicit.** Promote "standalone = sound subset; full parity requires the
   sidecar" to a product-positioning statement (ADR-0008 or a new ADR), and surface
   sidecar-absent coverage loss in the CLI / `doctor`. This is the strongest shield against
   the "bad competitor."
2. **Land OSS corpora (R4).** Grow the harness corpus to Redmine/Mastodon scale to expose
   subtle parity cases; 7 fixtures can't grade the design.
3. **State the exit condition (R3).** Add the criteria for retiring Ruby Rigor and
   re-unifying to ADR-0001, to prevent indefinite double maintenance.
4. **Formalize the RBS refresh seam (R2).** Elevate the `RIGOR_RBS_CORE_DIR`-style out-of-band
   overlay to the supported "update stdlib RBS without a rebuild" path in ADR-0007.
5. **Confirm registry governance (R3/R5).** Verify the `rigortype/rigor` upstream tracker
   exists and that "reviewer sign-off" is meaningful under a single maintainer.

## One-line summary

rigor-rs's design names and designs around all three relevant failure modes (Pzoom,
artichoke, pylyzer) and is structurally the right shape to preempt a worse Rust alternative.
The residual risks are not technical soundness but (a) communicating the unavoidable "pure-Rust
standalone is fast but silently misses bugs" trade-off and (b) the perpetual cost of tracking
parity against a fast-moving reference.
