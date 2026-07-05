---
name: rigor-protection-uplift
description: |
  Close the type-protection holes `rigor coverage --protection` surfaces: for each unprotected dispatch site, run `rigor sig-gen` first, hand-author only the minimal residual annotation, then verify with a double gate — the site becomes protected AND `rigor check` gains no new diagnostic. Triggers: "raise type protection", "add types where Rigor can't catch bugs", "act on coverage --protection / --mutation output", "make more of this code bug-catchable". NOT for Rigor's own `lib/` or the bundled plugins (use `rigor sig-gen` directly there and treat gaps as engine signal), and NOT for first-time setup (use rigor-project-init).
license: MPL-2.0
metadata:
  version: 0.1.0
  homepage: https://github.com/rigortype/rigor
---

# Rigor Protection Uplift

`rigor coverage --protection` (Tier 1) and `rigor coverage --protection
--mutation` (Tier 2) *surface* "add a type here" — they never author the
type. This skill *acts* on that surfacing under the discipline that keeps
Rigor false-positive-safe: protection goes up, and not one line of
working code starts reporting a new diagnostic.

## First: load the version-current copy

This skill's exact commands, flags, carrier syntax, and rule ids drift
between Rigor releases, so follow the copy that ships with the **installed**
Rigor rather than any vendored or frozen copy of this file. Get the
complete current procedure in one call:

```sh
rigor skill --full rigor-protection-uplift
```

If you already loaded this skill *via* `rigor skill` you have the current
copy — just proceed. If `rigor` is not on `PATH`, this task needs it: run
**`rigor-next-steps`** to install Rigor first, then come back.

## When to use

- A user wants to raise how much of their code Rigor can actually catch
  bugs in.
- You have `coverage --protection` output (an "add a type here" list) and
  want to close it.

## When NOT to use

- **Rigor's own `lib/`, or the bundled `plugins/` / `examples/`** — the
  self-check tree. Hand-authoring types there collides with the
  sig-gen-first ethos; run `rigor sig-gen` directly and treat residual
  gaps as engine signal to report, not a private fix.
- **"Make my code more precise" with no protection goal** — that is
  `rigor coverage` (precision), not `--protection`.
- **A project with no Rigor config yet** — onboard first with
  `rigor-project-init`.

## Load-bearing rules (read before touching a single type)

1. **The signal prioritises and verifies; the contract sources the
   type.** Never write the type the coverage/mutation signal "wants".
   Write the type the code *actually has*, derived from the
   implementation and its callers. A type guessed from the signal is a
   false-confidence type — worse than no type.
2. **sig-gen first.** A hand-written annotation is only the *residual*
   `rigor sig-gen` cannot reach. Every residual is a sig-gen-improvement
   to report, not just a private fix.
3. **"Minimal" = annotation footprint, not minimal-to-kill-the-mutant.**
   Optimising literally for mutant death games the metric. Add the
   smallest *true* annotation that models the contract; if that also
   kills the mutant, good.
4. **Robustness (ADR-5).** Tighten returns, keep parameters lenient. An
   over-tight param annotation breaks callers and breaches the
   false-positive discipline.

## Procedure

### Phase 1 — surface the holes

```sh
rigor coverage --protection --format json PATHS
```

Read the ranked "add a type here" list (`count`, `method_name`,
`examples`). Optionally confirm the highest-traffic ones actually buy
catching power with the Tier 2 deep dive:

```sh
rigor coverage --protection --mutation --format json   # changed-files by default
```

### Phase 2 — sig-gen first

```sh
rigor sig-gen --diff PATHS      # inspect; --write to apply
```

Adopt every concrete inferred signature. Note where sig-gen emits
`untyped` for a site on the "add a type here" list — that is the
**residual** Phase 3 owns.

### Phase 3 — author the residual (cheapest carrier per hole class)

| Hole class                          | Cheapest carrier                              |
| ----------------------------------- | --------------------------------------------- |
| `Dynamic` method return             | annotate that method's return in `sig/…rbs`   |
| `Dynamic[top] \| nil` ivar read     | `# @rbs @field: T` (ADR-58 territory)         |
| untyped param feeding the receiver  | a *lenient* param annotation                  |

Write the minimal true type. Prefer annotating the *upstream* source of
the Dynamic (the method return / the ivar) over the call site itself.

**Trap (carrier-additivity):** a sidecar `sig/…rbs` is NOT purely
additive. Declaring a class there flips it from inference-mode to
RBS-declared mode and *drops every member the RBS omits* — a lone
`def formatted: () -> String` can make Rigor forget the inferred
`initialize` and reject `Money.new(500)`. So either (1) adopt the full
Phase-2 sig-gen base into the file and add the residual on top, or
(2) use an in-place additive carrier (rbs-inline `#:` / a
`%a{rigor:v1:…}` return-override) that annotates the method without
re-declaring the class. "Minimal footprint" means the smallest *true*
type, never the smallest *file*.

### Phase 4 — double-gate verify (both must hold)

```sh
rigor coverage --protection PATHS   # (a) the site is now protected / ratio up
rigor check PATHS                   # (b) no NEW diagnostic vs the post-sig-gen baseline
```

If (b) regresses, the annotation modeled the wrong contract — **revert
it**, do not suppress the diagnostic. If (a) did not move, the carrier
was wrong (often: you typed the call site, not the upstream Dynamic
source). Gate (b) is a *diff* against the post-sig-gen state, not an
absolute "zero diagnostics" — sig-gen itself can surface the
acknowledge-mode FP envelope a project baseline absorbs; this skill owns
only the increment it adds.

### Phase 5 — feed the residual back

File each Phase-3 residual as a sig-gen gap (what shape did inference
miss?). The hand annotation is the stopgap; the durable fix is raising
inference so the residual disappears.

## Honest bounds

Hand-RBS uplift is a finisher, not a path to 80% protection. The
dominant remaining holes after this loop are intractable from
annotation alone — external-gem Dynamic receivers, polymorphic value
types, generic type parameters, dynamically-built classes. Those need
parametric types / external RBS / engine folding (and are where the
`rigor-plugin-author` escalation or a Rigor issue comes in), not another
hand annotation. Expect a low-20s → low-30s% protection lift on a mature
library, at zero diagnostic cost.
