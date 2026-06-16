# Act-on-coverage skill — skeleton draft (ADR-63 WD5)

Status: **Draft / parked.** This is the SKILL.md skeleton for the
[ADR-63 WD5](../adr/63-type-protection-coverage.md) act-on-coverage layer. It is **not** a
live skill — it is deliberately kept out of `.claude/skills/` (which Claude Code
auto-discovers in this repo as *contributor* workflows) because WD5 scopes it to **user
projects** via the ADR-31 external-author / v0.2.0-queued path, not Rigor's own tree.
Promote it to a real `SKILL.md` under whatever external-author packaging v0.2.0 settles on.

The skeleton encodes the WD5 discipline as an executable procedure so the design can be
dry-run and the friction fed back into the WD before it graduates.

---

```markdown
---
name: rigor-protection-uplift
description: >
  Close type-protection holes that `rigor coverage --protection` surfaces. For each
  unprotected dispatch site, try `rigor sig-gen` first, hand-author only the minimal
  residual annotation, then verify with a double gate — the site becomes protected AND
  `rigor check` stays diagnostic-clean. Use when asked to "raise type protection",
  "add types where Rigor can't catch bugs", or to act on `coverage --protection` /
  `--mutation` output. For user projects, never Rigor's own lib/.
---

# rigor-protection-uplift

Productizes ADR-63 WD5 — the act-on-coverage loop. `rigor coverage --protection` (Tier 1)
and `--mutation` (Tier 2) *surface* "add a type here"; they never author the type. This
skill *acts* on that surfacing under the discipline that keeps Rigor false-positive-safe.

## When to use
- A user wants to raise how much of their code Rigor can actually catch bugs in.
- You have `coverage --protection` output (an `add_a_type_here` list) and want to close it.

## When NOT to use
- Rigor's own `lib/` or the bundled `plugins/` / `examples/` (self-check tree) — injecting
  hand types there collides with the sig-gen-first ethos; use `rigor sig-gen` directly and
  treat gaps as engine signal.
- "Make my code more precise" with no protection goal — that is `coverage` (precision),
  not `--protection`.

## Load-bearing rules (read before touching a single type)
1. **The signal prioritizes and verifies; the contract sources the type (ADR-59).** Never
   write the type the mutation/coverage signal "wants". Write the type the code *actually
   has*, derived from the implementation and its callers. A type guessed from the signal is
   a false-confidence type — worse than no type.
2. **sig-gen first (AGENTS.md § RBS Authorship).** A hand-written annotation is only the
   *residual* sig-gen cannot reach. Every residual is a sig-gen-improvement report to file,
   not a private fix to pocket.
3. **"Minimal" = annotation footprint, not minimal-to-kill-the-mutant.** Optimizing
   literally for mutant death Goodharts the metric. Add the smallest *true* annotation that
   models the contract; if that happens to also kill the mutant, good.
4. **Robustness (ADR-5).** Tighten returns, keep params lenient. An over-tight param
   annotation breaks callers and breaches the false-positive discipline.

## Procedure

### Phase 1 — surface the holes
```
rigor coverage --protection --format json PATHS
```
Read `add_a_type_here` (ranked by traffic: `count`, `method_name`, `examples`). Optionally
confirm the highest-traffic ones actually buy catching power with the Tier 2 deep dive:
```
rigor coverage --protection --mutation --format json   # changed-files by default
```

### Phase 2 — sig-gen first
```
rigor sig-gen --diff PATHS      # inspect; --write to apply
```
Adopt every concrete inferred signature. Note where sig-gen emits `untyped` for a site on
the `add_a_type_here` list — that is the **residual** Phase 3 owns.

### Phase 3 — author the residual (cheapest carrier per hole class)
| Hole class                          | Cheapest carrier                                  |
| ----------------------------------- | ------------------------------------------------- |
| `Dynamic` method return             | annotate that method's return in `sig/…rbs`       |
| `Dynamic[top] \| nil` ivar read     | `# @rbs @field: T` (ADR-58 territory)             |
| untyped param feeding the receiver  | a *lenient* param annotation                      |
Write the minimal true type. Prefer annotating the *upstream* source of the Dynamic (the
method return / the ivar) over the call site itself.

**Trap (dry-run-confirmed):** a sidecar `sig/…rbs` is NOT purely additive. Declaring a
class there flips it from inference-mode to RBS-declared mode and *drops every member the
RBS omits* — a lone `def formatted: () -> String` made Rigor forget the inferred
`initialize` and reject `Money.new(500)`. So either (1) adopt the full Phase-2 sig-gen base
into the file and add the residual on top, or (2) use an in-place additive carrier
(rbs-inline `#:` / a `%a{rigor:v1:…}` return-override) that annotates the method without
re-declaring the class. "Minimal footprint" means the smallest *true* type, never the
smallest *file*.

### Phase 4 — double-gate verify (both must hold)
```
rigor coverage --protection PATHS   # (a) the site is now protected / ratio up
rigor check PATHS                   # (b) diagnostic-clean: NO new diagnostic vs baseline
```
If (b) regresses, the annotation modeled the wrong contract — **revert it**, do not suppress
the diagnostic. If (a) did not move, the carrier was wrong (often: typed the call site, not
the upstream Dynamic source).

### Phase 5 — feed the residual back
File each Phase-3 residual as a sig-gen gap (what shape did inference miss?). The hand
annotation is the stopgap; the durable fix is raising inference so the residual disappears.
```

---

## Dry-run findings (2026-06-16)

Ran the WD5 loop against a synthetic target (`Money#formatted` returns through an untyped
helper; `amount = Money.new(500); amount.formatted.upcase`). Result: **the procedure holds,
and the double gate earned its keep.**

- **Phase 1** `coverage --protection` → 2/4 protected (50%); `add_a_type_here` = `#format`,
  `#upcase`. The `#upcase` site is the target (rides `formatted`'s untyped return).
- **Phase 2** `sig-gen --print` emitted `initialize`/`helper` but **omitted `formatted`
  entirely** — it declines to emit an `untyped`-return method. That omission *is* the
  residual, concretely confirming the Phase 2 → Phase 3 hand-off.
- **Phase 3 (naive)** wrote a *lone* `class Money; def formatted: () -> String; end`.
- **Phase 4** — gate (a) passed (3/4, `#upcase` now protected) but **gate (b) FAILED**:
  `check` went from `No diagnostics` (baseline) to a fresh
  `Money.new (given 1, expected 0)` error. The partial sidecar RBS flipped `Money` to
  RBS-declared mode and dropped the inferred `initialize`. **The double gate caught a
  hand-written annotation breaking working code** — exactly its purpose.
- **Phase 3 (corrected)** adopted the sig-gen base (`initialize`, `helper`) *then* added the
  residual `formatted`. Re-verify: gate (b) `No diagnostics`, gate (a) **4/4 (100%)**.

Procedure corrections folded back into Phase 3 above and into ADR-63 WD5's carrier caveat:
1. The residual must sit on the sig-gen base, or use an in-place additive carrier — a lone
   partial-class sidecar is not additive.
2. Rigor **trusts** the hand-written RBS return (it did not flag `formatted`'s nil-returning
   body against the declared `String`) — so the author fully owns the contract's
   correctness. Reinforces load-bearing rule 1 (the contract sources the type).
3. Gate (b) must be a **baseline diff** (new-vs-existing diagnostics), not an absolute
   "zero diagnostics" — the target may legitimately carry pre-existing findings.

## Multi-repo pilot validation (2026-06-16)

Ran the WD5 measurement spine across 5 OSS libraries (one Sonnet subagent per repo) under
`rigor-survey`: reset → `sig-gen --write` (M1) → hand-authored residuals under the double
gate (M2). All M2 figures were independently re-measured after the run.

| repo | files | M0 prot | M1 (sig-gen) | M2 (skill) | sig-gen Δ | **skill Δ** | precision M0→M2 | residuals | reverts | check |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| kramdown | 55 | 17.3% | 23.6% | 34.9% | +6.3 | **+11.3** | 55.5→62.0 | 9 | 0 | 10 (flat) |
| haml | 51 | 22.4% | 28.2% | 31.9% | +5.8 | +3.7 | 51.7→55.8 | 10 | 0 | 8 (flat) |
| faraday | 33 | 21.3% | 27.8% | 31.4% | +6.5 | +3.7 | 44.1→49.5 | 10 | 0 | 6 (flat) |
| rgl | 28 | 25.0% | 34.5% | 36.6% | +9.5 | +2.1 | 43.3→48.5 | 11 | 0 | 0 (flat) |
| parser | 56 | 19.7% | 26.5% | 29.0% | +6.8 | +2.5 | 44.1→50.6 | 10 | 0 | 25 (flat) |
| **mean** | | **21.1%** | **28.1%** | **32.8%** | **+7.0** | **+4.7** | | 50 | **0** | **flat** |

**Verdict: the skill raises protection beyond sig-gen on every repo (+2.1 to +11.3pp, mean
+4.7), at zero diagnostic cost** — 50 residual annotations landed, 0 reverted, and each
repo's `check` error count stayed pinned to its M0 baseline throughout. The double gate held
without a single regression in mature code. This empirically backs WD5's premise *and* its
FP-safety claim.

Honest bounds:
- The gain is ceiling-bounded (~30–37% protection on these libs). The dominant remaining
  holes are intractable from hand-RBS — external-gem Dynamic receivers (Temple/Ripper/`ast`),
  polymorphic value types (kramdown `Element#value`), generic type params (rgl
  vertex/weight), dynamic `Options.new` classes (faraday). Those need parametric types /
  external RBS / engine folding, not annotation. The skill is a *low-20s→low-30s%* finisher,
  not a path to 80%.
- sig-gen (M1) is the prerequisite and does comparable heavy lifting; the skill is strongest
  where a lib has many concrete classes whose method returns sig-gen left untyped (kramdown,
  parser's `Source` layer).

Byproducts — real defects surfaced (worth filing against Rigor):
- **sig-gen emits `module X` where the source declares `class X`** in subdirectory RBS
  (parser: `Diagnostic`/`Comment`/`Map`/`Rewriter`/`TreeRewriter`) → RBS
  `DuplicatedDeclarationError` that crashed the whole RBS environment until hand-fixed. A
  concrete sig-gen bug.
- **sig-gen wrote RBS with syntax errors** (rgl, 3 fixups) — an output-validity gap.
- **over-nilable sig-gen returns** (kramdown `children: -> []`) surface `possible nil` FPs —
  the known sig-quality FP class (acknowledge-mode baseline territory).
- Two plausible *real* latent bugs surfaced by sig-gen (not the skill): kramdown
  `link.rb:130` `strip!` on a nilable slice; faraday `connection.rb:296`
  `setup_parallel_manager` on a possibly-nil adapter.

Protocol refinement confirmed: gate (b) must be **no new diagnostics vs the post-sig-gen
(M1) baseline**, not vs pristine — sig-gen itself surfaces the acknowledge-mode FP envelope,
which a project baseline absorbs. The skill owns only the M1→M2 increment.

## Open questions to resolve before promotion
- Packaging: where the external-author skill lives once ADR-31's v0.2.0 path is built.
- Whether Phase 4 (a) should gate on the *specific* site flipping protected (precise) or the
  file ratio rising (cheap) — the dry-run should tell us which is robust.
- Carrier for the ivar class depends on ADR-58 progress + whether the user project uses the
  rbs-inline plugin (ADR-32) vs sidecar `sig/`.
