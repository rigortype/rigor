# ADR-102 — The unused-code reachability report is a report, not a diagnostic

Status: **Proposed, 2026-08-15.** Nothing implemented. Fixes the decisions the
`rigor unused` slices build against ([#344](https://github.com/rigortype/rigor/issues/344)
umbrella; [#347](https://github.com/rigortype/rigor/issues/347) tracer bullet). Two
working decisions — WD5's incremental interaction and WD8's treatment of test-only
references — are **open** and MUST be closed before #347 lands; every other WD is settled
by the measurement below.

Grounding: [`docs/notes/20260813-unused-constant-fp-baseline.md`](../notes/20260813-unused-constant-fp-baseline.md)
(three-project corpus measurement, redmine adjudicated in full) and
[ADR-21](21-rubydex-evaluation.md), which already settled what Rigor consumes from
Shopify's rubydex rather than becomes.

## Context

"Which code here is dead?" is a question every large Ruby codebase asks, and one Rigor
is unusually well placed to answer: it already resolves constants through Ruby's nesting
rules rather than by name matching, which is the capability that separates a real answer
from `grep`. The prompt was a 2026 report of using rubydex to find unused Rails
controllers, whose candidate list decayed `631 → 9 → 3 → 2` across three corrections and
whose author concluded the tool narrows candidates rather than producing answers.

We measured the same funnel ourselves rather than inheriting that conclusion. On redmine,
after four stages of increasingly expensive root knowledge, **57 candidates survived and
4 were genuine — 7.0 % precision**, with all 57 hand-adjudicated. Mastodon and
conference-app produced 113 and 14 survivors on the same funnel.

The intent this ADR serves: turn "which code is dead?" from an unanswerable question
into a **review queue a human can work through**, without spending any of the
false-positive budget that makes `rigor check` worth running. Those two goals are in
direct tension, and every decision below is a consequence of resolving it in the same
direction.

## Decision

The discriminating criterion, stated once because every working decision follows from it:

> **A signal whose precision is bounded by knowledge the analyzer cannot have — rather
> than by how well it analyzes — belongs in a report, not in the diagnostic stream.**

Reachability is bounded that way. Its accuracy is a function of the *root set*: routes,
DI wiring, reflection, framework naming conventions, callers outside the analysis root.
Better inference does not move it. Contrast `call.undefined-method`, whose precision *is*
a function of analysis quality — improve the dispatcher and it improves. That is the line,
and it is reusable: it decides future signals (a "probably unreachable branch" report, a
"likely unused config key") without re-litigating this one.

### WD1 — Report, never a diagnostic, at any severity

`rigor unused` is its own subcommand in the `rigor triage` / `rigor coverage` family. It
MUST NOT emit into the `check` diagnostic stream, including as `:info`. At 7.0 % precision
a diagnostic teaches people to route around the tool, which costs more than the feature
returns (AGENTS.md § Implementation Guidelines; [ADR-5](5-robustness-principle.md)).

### WD2 — Reachability from roots, not reference counting

The model is mark-and-sweep from an explicit root set. Two measured facts force this:

- **Root knowledge is the entire lever.** Subtracting route-derived roots removed 40 % /
  62 % / 67 % of the class tier across the three targets — more than every other stage
  combined — and that was with a regex extractor.
- **Widening the analysed root is not a lever.** Declarations and references are gated on
  the same analysed-file predicate, so they widen together and cancel: +1 / −3 / +2
  candidates. Rigor MUST NOT ship advice that says "add `config/` and the report improves".

### WD3 — Roots are plugin-supplied

The core defines the root *protocol*; framework knowledge stays in plugins, carried by the
existing `produces:` / `fact_store` mechanism ([ADR-9](9-cross-plugin-api.md),
[ADR-2](2-extension-api.md)). `rigor-rails-routes` already interprets `config/routes.rb`
via Prism with no Rails runtime, which beats the source article's approach on two axes: no
boot, and both branches of a `get "..." if <cond>` route are visible — the step that
article had to perform by hand.

Two convention rules retire 66 % of redmine's remaining artifacts (the helper-module
pairing, and "a class whose body calls a registration DSL is a root"). Both are
plugin-shaped, which is the point.

### WD4 — `cannot-decide` is part of the output contract

A constant Rigor cannot *prove* unreferenced MUST be reported as undecidable, never folded
into "unused". Dynamic construction (`constantize`, `const_get`, interpolated names), class
names as data in YAML / locales, and ERB templates all demote. Stratify with
[ADR-65](65-diagnostic-evidence-tier-and-doc-url.md)'s evidence tier so a reader sorts by
confidence instead of reading a flat list.

### WD5 — Whole-project only *(OPEN — decide before #347)*

A reachability answer is sound only over a full run, which collides with
[ADR-45](45-unchanged-project-fast-path.md)'s run-result cache and
[ADR-46](46-incremental-dependency-graph.md)'s per-file incremental path. Two candidates:
**(a)** `rigor unused` refuses under `--incremental` with a diagnostic message, or **(b)**
it silently forces a full pass. (a) is recommended — a silently-slow command is worse than
an explicit refusal, and it keeps the soundness boundary visible. Whichever is chosen MUST
be pinned by a spec; leaving it to emerge is not an option, because the failure mode is a
confidently-wrong candidate list rather than an error.

### WD6 — Class and module constants only at launch

The value-constant tier stays out. `Scope#in_source_constants` is per-file by design and
is not carried in the cross-file project seed, so a value constant read from another file
never resolves and its candidacy is spurious by construction — 38 / 89 / 0 candidates
across the corpus with no way to be right. Reopening that is [#352](https://github.com/rigortype/rigor/issues/352),
with its own false-positive surface.

Ownership means **declared first here**, not declared here: reopening a gem or stdlib class
currently registers it as a project declaration, which produced three of redmine's
artifacts from a single initializer.

### WD7 — The reference corpus is wider than the analysis corpus

`PathExpansion::RUBY_GLOB` is `**/*.rb`, so `.rake` files sit inside `paths:` and are never
read — pure artifacts on two of three targets. Reading a file to harvest references is far
cheaper than type-checking it, and the report MUST take the wider corpus.

### WD8 — Test-only references *(OPEN — decide before #349)*

A class referenced only from its own spec is dead production code with a live test. Options:
count test references as reachability (simple, hides real findings), ignore them (noisy),
or **track the referencing file's role and report the distinction** — recommended, because
"used only by its own test" is the most actionable row the report can produce. The choice
changes the data model, not just a filter, so it cannot be deferred past #349.

### Re-evaluation triggers

WD1 reopens if adjudicated precision on a corpus target clears ~80 % — high enough that a
diagnostic would stop being noise — and not before; a lower bar re-opens the argument
without changing the arithmetic. WD3 reopens if a root class turns out to be genuinely
framework-independent (project-wide config conventions), which would belong in the core
rather than in a plugin. WD6 reopens the moment #352 lands. WD7 reopens if the wider
reference corpus measurably slows a run, which the note's cost argument predicts it will
not. WD2, WD4 and WD5 are structural and have no trigger short of a redesign.

## Rejected and deferred alternatives

| Alternative | Why not |
| --- | --- |
| Ship as an `:info` diagnostic | Still trains readers to ignore output, and `:info` is the severity people filter first. The criterion does not admit a severity escape hatch. |
| Reference counting ("zero references ⇒ unused") | The naive form measured 99.7 % FP on Rigor's own `lib`; every correction in the source article was a missing root, not a missing reference. |
| Widen `paths:` as the mitigation | Measured: +1 / −3 / +2. Declarations widen with references. |
| Hardcode Rails knowledge in the core | Contradicts ADR-2's plugin boundary; the two highest-yield rules are framework conventions, which is exactly what plugins are for. |
| Consume rubydex's cross-reference index | ADR-21 Track 3 already conditions this on the LSP roadmap; the declaration substrate Rigor needs is already present. |
| Value constants at launch | Spurious by construction until #352 lands. |
| Unused *methods* | Deferred to [#351](https://github.com/rigortype/rigor/issues/351). Rigor can reach it where a type-free indexer cannot, but the tier inherits this one's problems at ten times the volume and needs an API-boundary definition first. |

## Consequences

**Positive.** The question gets a defensible answer without touching the diagnostic
stream's trustworthiness. The root protocol is reusable by any future reachability
question. Static route parsing removes the manual step the source article could not
automate.

**Negative.** A 7 % precision report is a review queue, and the documentation must say so
plainly rather than implying a defect count — an over-sold report is the failure mode that
makes users stop opening it. Root supply also carries an asymmetry: a root source that
*over*-supplies silently hides real dead code, which is worse than one that under-supplies,
so each plugin's contribution needs its own corpus check.

**Carry-over.** WD5 and WD8 are open. The #345 probe instrumentation lives in four engine
files until #349's re-measurement is done, then comes out (tracked on #344).

## Relationship to other ADRs

[ADR-21](21-rubydex-evaluation.md) settled the rubydex question in three tracks; this is
the independent fourth question of what Rigor builds natively, and does not reopen it.
[ADR-45](45-unchanged-project-fast-path.md) / [ADR-46](46-incremental-dependency-graph.md)
own the caching boundary WD5 must resolve against.
[ADR-9](9-cross-plugin-api.md) and [ADR-2](2-extension-api.md) supply the root-contribution
mechanism. [ADR-65](65-diagnostic-evidence-tier-and-doc-url.md) supplies the tier vocabulary.
[ADR-5](5-robustness-principle.md) is the discipline WD1 enforces.
