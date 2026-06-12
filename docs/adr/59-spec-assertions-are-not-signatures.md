# ADR-59 — Spec assertions are not implementation signatures

Status: **Accepted (strong form rejected), 2026-06-12.** The
founding-era idea that RSpec assertions could serve as a type-inference
*source for the implementation* — `expect(foo(1)).to be_a(String)` ⇒
adopt `foo: (Integer) -> String` — is rejected as policy, not deferred.
The three weak forms that are compatible with the false-positive
discipline (contradiction diagnostic, `Dynamic`-interior hints, runtime
trace → sig-gen) are recorded here as the sanctioned future paths, all
demand-gated. README commitment #2 is reworded in the same change so the
public framing matches what shipped.

## Context

"Your specs are types" is one of the three README design commitments.
What shipped under it (rigor-rspec / rigor-factorybot, "Pillar 2") is
real but flows in one direction only: matcher assertions narrow locals
*within the spec body* (`plugins/rigor-rspec/lib/rigor/plugin/rspec/matcher_analyzer.rb`,
`post_return_facts`), `let` / `subject` bindings carry the
*implementation's* inferred type into `it` bodies, and factory
definitions publish an ADR-9 `:factory_index` fact. No channel feeds a
spec assertion back into the inferred signature of a `lib/` method, and
the original strong-form idea predates the FP discipline that now
governs every precision change. This ADR retires the idea explicitly so
it stops resurfacing as an open question, and records what may ship in
its place.

## Decision

Reject spec-assertion-derived implementation signatures. The
discriminating criterion:

> A test assertion is a per-input *witness*, not a universal claim.
> Witnesses bound a signature from the wrong side on both ends, so
> spec-derived type claims may land only where being wrong cannot fire
> a diagnostic — the gradual interior (`Dynamic`'s `static_facet`), a
> human-review channel (`rigor sig-gen` output), or as a check run
> *against* inference — never as an adopted signature.

## Working decisions

- **WD1 — Why the strong form is unsound for Rigor, independent of
  effort.** Observed returns are a *lower* bound: the union of asserted
  return types is a subset of the true return type, so adopting it as
  the declared return narrows the signature and fires false positives
  at call sites the suite didn't exercise. Spec call examples are
  likewise a lower bound on accepted parameters; adopting them rejects
  other live callers. The robustness principle (ADR-5: strict returns,
  lenient parameters) needs upper-bound information on exactly the ends
  where tests provide lower bounds. On top of the bound asymmetry,
  assertions are wishes that happen to be executed: `pending` / `xit` /
  tag filters mean a green CI need not have run a given example, the
  analyzer cannot statically know the suite is green at all, and a
  stale assertion drifts exactly like a stale annotation —
  contradicting "types are facts, not wishes" (README commitment #1).

- **WD2 — The blocker is policy, not architecture.** The mechanics
  would be feasible: rigor-factorybot's `producer :factory_index`
  already demonstrates the pattern (an `io_boundary` AST walk of
  project files outside the per-file inference pass, published as an
  ADR-9 fact), and an analogous `spec_return_claims` index needs only
  literal matcher recognition, not full inference. Ordering under the
  fork pool and the ADR-46 spec→lib dependency edges are costs, not
  walls. The rejection therefore does not expire if the architecture
  changes — it expires only if the FP discipline does.

- **WD3 — Sanctioned weak forms (future work, demand-gated).** Each
  satisfies the criterion by construction:
  1. **Contradiction diagnostic** — when inference proves
     `expect(foo(1)).to be_a(String)` impossible (matcher narrowing of
     the subject lands on `bot`), fire a `spec.impossible-assertion`
     diagnostic. This checks the spec *against* inference; the
     inference itself is untouched. Cheapest path; reuses
     `MatcherAnalyzer` plus the ADR-47 bot-detection family.
  2. **`Dynamic`-interior hints** — where inference fell to
     `Dynamic[top]` (metaprogramming, unanalyzed gems), a spec claim
     may refine the `static_facet` to `Dynamic[T]`
     (`lib/rigor/type/dynamic.rb`). `Dynamic` never fires diagnostics,
     so a wrong claim costs nothing; downstream precision, `type-of`,
     and sig-gen hints improve. Mechanism: WD2's claims index consumed
     at dispatch only when the inferred result is `Dynamic[top]`.
  3. **Runtime trace → sig-gen** — execute the suite under a
     TracePoint harness, record *observed* types (facts, not
     assertions), and emit RBS through the existing `rigor sig-gen`
     review channel (ADR-14). Opt-in runtime execution belongs in a
     separate gem, not core, to preserve the "no runtime dependency"
     claim for `rigor check`.

- **WD4 — README alignment.** Commitment #2's wording ("Do you really
  need to write type annotations?", "live type oracle") implied
  spec→implementation inference. Reword to state the shipped direction
  (assertions narrow spec bodies; implementation types flow into
  specs; factories feed the plugin channel) in the same change as this
  ADR. *Follow-up (same day, `62bec417`)*: the reworded commitment read
  as a plugin feature tour, not a design commitment, so the slot was
  re-filled with the false-positive discipline pillar; the rspec /
  factorybot capabilities stay documented in the plugin catalogue, and
  the ROADMAP's "Pillar 2" mentions carry `<del>`/`<ins>` retraction
  markers pointing here.

## Rejected / deferred alternatives

| Alternative | Disposition |
| --- | --- |
| Adopt assertion-derived signatures outright | Rejected — WD1's bound asymmetry makes caller FPs structural, not incidental. |
| Confidence-weighted adoption (assertions as soft signatures that still gate diagnostics) | Rejected — any path where an unverified claim can fire a diagnostic fails the criterion; "soft" does not change which side of the bound the information sits on. |
| Gate adoption on proof the suite is green | Rejected — greenness is unknowable statically, and coupling soundness to CI state imports an unverifiable external precondition. |
| Weak forms 1–3 (WD3) | Deferred, demand-gated — no implementation commitment in this ADR. |

## Consequences

- **Positive**: the founding idea has a recorded resolution instead of
  resurfacing; README commitment #2 becomes factually accurate; the
  three weak forms have a home with their FP-safety arguments already
  made, so any future slice starts from the criterion rather than
  re-litigating it.
- **Negative**: none operational — no shipped behaviour changes.

## Relationship to other ADRs

- **ADR-5** supplies the bound-direction argument WD1 rests on.
- **ADR-9** is the fact-channel substrate the WD3 paths would use;
  rigor-factorybot's `:factory_index` is the worked precedent.
- **ADR-14** owns the sig-gen review channel WD3 path 3 emits into.
- **ADR-47**'s bot-detection machinery is the natural host for WD3
  path 1.
