# ADR-57 — Opening the implicit-self call return-adoption gate (ADR-24 WD3 revisit)

Status: **Proposed, 2026-06-12.** Measurement done (WD1); the gate stays
closed until the itemized firing classes are adjudicated and the
artifact classes fixed (WD2/WD3). Archetype: evaluation-proposal.
Stakes: high (the gate exists because of a measured FP regression; the
FP-discipline value binds).

Grounding: the gate-open experiment below (2026-06-12) and the
[2026-06-12 Dynamic-fall survey](../notes/20260612-dynamic-fall-pattern-survey.md)
(bucket B2, re-diagnosed: the survey's "non-constant param" framing was
wrong — toplevel calls with non-constant args already type precisely;
the actual residual is this gate).

## Context

ADR-24 WD3 gates the adoption of a resolved implicit-self call's return
type inside method bodies: only `Bot` (and, since ADR-55, value-pinned
results during an unroll) are adopted; everything else stays
`Dynamic[top]` (`ExpressionTyper#adoptable_self_call_result?`). The
gate was installed because unconditional adoption regressed
`rigor check lib` by 16 diagnostics (measured pre-ADR-55/56).

This is now the **single largest remaining Dynamic source** for plain
procedural Ruby:

```ruby
def helper(x) = x * 2
def outer = helper(3)        # outer → Dynamic[top] (helper resolves; adoption gated)
class S; def run = helper(3); end   # same
def fib(n) = n < 2 ? n : fib(n-1) + fib(n-2)
fib(x)                       # 1 | Dynamic[top] — the gate also blocks ADR-55's
                             # fixpoint summary from reaching in-body call sites
```

Adjacent, measured separately: module-singleton calls
(`Util.triple(x)` for `def self.triple`) type `Dynamic[top]` through a
different resolution path (singleton dispatch on a module constant) —
slice-able independently of the gate.

## WD1 — Gate-open measurement (2026-06-12)

Unconditionally opening the gate (return `true`) on the post-ADR-55/56
engine yields **+25 firings on `rigor check lib`** (baseline: zero).
Distribution:

- ~17 `always-truthy/falsey-condition` warnings — adopted returns
  (often constants or non-nil nominals) folding conditions. Mixed
  population: some will be genuine dead branches, some artifact
  (helper-return imprecision the `Dynamic` had masked — the exact
  failure mode ADR-55's clamp and ADR-56's write-back kept finding).
- 4 `argument-type mismatch` errors on `Configuration.load`-style
  paths — adopted returns now carrying `String? | false`-shaped
  optionality into call sites (genuine-or-artifact per site).
- 1 `possible nil receiver` error, 1 `return-type mismatch` warning,
  2 misc.

The historical "16" is now "25" — the population shifts as engine
precision moves, which is itself the argument for re-measuring per
engine generation rather than treating the gate as permanent.

## WD2 — Decision criterion

> The gate opens **per adjudicated firing class, not wholesale**: every
> firing in the gate-open delta (self-check + corpora) is classified
> *genuine* (the adopted type is right and the diagnostic is earned) or
> *artifact* (the adopted type is wrong — an evaluator blind spot).
> Artifacts are fixed at their root (each one is an engine bug worth
> finding — the ADR-55/56 arc fixed five this way); when the residual
> delta is all-genuine, the gate opens, and the genuine firings land as
> wins. Until then the gate stays. No firing class is suppressed to
> force the timeline.

Tier order (each its own corpus-gated slice):

1. **Adjudicate the 25** (self-check) + the corpus delta (Mastodon /
   haml / kramdown gate-open runs): itemized genuine/artifact table.
2. **Fix the artifact classes.** Known suspects from the ADR-55/56 arc:
   block-internal `return` not contributing to a method's return type
   (the tail-only body evaluator), optionality over-joining on early
   returns, constants surviving paths they shouldn't.
3. **Open the gate** (possibly staged: Dynamic-free results first,
   then all), re-measure, land with the genuine firings itemized in
   the CHANGELOG.
4. **Module-singleton resolution** (`def self.x` via module constant
   receiver) as an independent slice — same adjudication protocol.

If ADR-50's bleeding-edge overlay ships first, the opened gate is a
natural first `bleeding_edge:` feature; otherwise it lands as a normal
engine-precision change under the WD2 criterion.

## Rejected / deferred alternatives

- **Open wholesale now, absorb via baseline.** Rejected — 4 of the 25
  are *errors*; FP discipline forbids shipping unadjudicated errors on
  working code (rigor's own CLI works).
- **Keep the gate permanently.** Rejected as a standing position — the
  gate's cost grows as the rest of the engine gets more precise (it now
  blocks ADR-55's summaries); WD1 shows the blocker population is
  finite and enumerable.
- **Adopt only non-value-pinned nominals (skip constants).** Considered
  as tier staging; not a criterion by itself — constant adoption is
  where most of the value (and most of the artifact risk) lives.

## Relationship to other ADRs

- **ADR-24** — this revisits WD3 with its own method: the measurement
  that closed the gate is re-run per engine generation, and the gate
  opens by adjudication, not assertion.
- **ADR-55 / ADR-56** — supplied the blind-spot-fixing precedent (five
  artifact classes found and fixed) and the adjudicated-gate protocol
  (ADR-56 WD4) this ADR adopts; opening the gate is what lets their
  precision reach in-body call sites.
- **ADR-50** — the bleeding-edge overlay is the natural staging vehicle
  if it ships first.
