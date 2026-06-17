# ADR-63 — User-facing type-protection coverage

Status: **Accepted — Tier 1 (static proxy) IMPLEMENTED 2026-06-14 (`rigor coverage
--protection`) and Tier 2 (mutation effectiveness) IMPLEMENTED 2026-06-14 (`rigor coverage
--protection --mutation`).** Extends `rigor coverage` with a *protection* dimension: not
"how precise are my types" but "if I introduce a bug, would Rigor catch it" — the
user-facing surfacing of the ADR-62 teeth work.

Grounding: [ADR-62](62-mutation-testing-teeth-measurement.md) (the internal teeth
methodology this productizes) and
[`docs/notes/20260613-mutation-teeth-harness.md`](../notes/20260613-mutation-teeth-harness.md).

## Context

`rigor coverage` already reports **type precision** — the fraction of expressions Rigor
gives a precise (non-`Dynamic`) type, with `--threshold` and `--format json`
(`Inference::PrecisionScanner`). That answers "how well-typed is my code", but not the
question a user actually cares about: **how protected am I** — at a call site, would
Rigor catch a wrong method, a wrong argument, a missing nil-check? Precision is necessary
for protection but not identical to it, and a flat "% of expressions typed" buries the
actionable signal (the *call sites* where adding a type would buy real catching power).

The ADR-62 mutation harness measures protection directly (does breaking the code make
Rigor bite) but is deliberately dev-only. This ADR surfaces that value to users.

## Decision

Add a **protection** mode to `rigor coverage` (`rigor coverage --protection`), reported
in two tiers with one shared framing rule.

**Framing criterion (load-bearing, from ADR-62 Criterion A):** the metric is always
presented as *effectiveness / where-to-add-a-type*, never as raw mutation "survival". A
low score points the user at the **unprotected sites** (a `Dynamic` receiver, an
unkillable mutation) as "add a type here", never as "your code is broken". Mis-framed,
this would frighten working code and breach the false-positive discipline.

- **Tier 1 — static protection proxy (the v1; cheap, interactive).** Over one
  `type_of` pass (reusing `PrecisionScanner`), classify every **dispatch site** (method
  call) by whether its **receiver** types to a concrete, non-`Dynamic` class — i.e. a
  site where Rigor's call rules *can* bite. Report the per-file / aggregate **protected
  ratio** and list the unprotected (`Dynamic`-receiver) sites. This is a sound
  *upper bound* on real protection (a concrete receiver is necessary but not sufficient
  for a diagnostic to fire) and is one analysis pass — fast enough to run interactively
  and in CI.
- **Tier 2 — mutation effectiveness (implemented 2026-06-14).** The truth tier: for each
  type-visible mutation at a site, does Rigor kill it (ADR-62)? Reports the per-file
  *actual* kill rate. It refines Tier 1 (could-bite → does-bite) at the cost of N
  analyses per site, so it is an opt-in CI deep-dive (`--protection --mutation`), scoped
  to changed files by default. Productizing it ships a **narrow, curated subset** of the
  ADR-62 harness (the per-file effectiveness measurement) as a supported command — it
  does **not** ship the dev sweep / fuzz / clustering tooling, which stays dev-only per
  ADR-62 WD4. This is a deliberate, scoped refinement of that WD, not a reversal. The
  productized core lives in `lib/rigor/protection/` (`Mutator` + `MutationScanner` — the
  warm loop, type-aware filter, and kill criterion lifted from `tool/mutation/`, which now
  reuses the lib `Mutator` so there is one source of truth).

Both tiers reuse the existing `coverage` plumbing: `--threshold` becomes the **CI gate**
(exit 1 below the protected/effectiveness ratio) and `--format json` the machine output —
so "report + gate" is satisfied without new surface.

## Working decisions

- **WD1 — extend `rigor coverage`, do not add a command.** The protection metric is a
  sibling of type-precision; one command with a `--protection` mode keeps the "coverage"
  concept together and reuses threshold/JSON. (`coverage --protection` = Tier 1;
  `coverage --protection --mutation` = Tier 2.) New flags are public contract under
  ADR-50 WD1.
- **WD2 — Tier 1 is a dispatch-site receiver-concreteness scan.** A call site is
  *protected* when `concrete_class_name(receiver_type)` is non-nil (the same predicate the
  call rules gate on), *unprotected* when the receiver is `Dynamic`/`Top`. Implicit-self
  and receiver-less calls are excluded (no receiver to score). Reuses the
  `PrecisionScanner` walk; no new analysis.
- **WD3 — report + gate.** Text report: aggregate + per-file protected %, and a ranked
  "add a type here" list of unprotected call sites (highest-traffic receivers first).
  `--threshold` gates; `--format json` carries `{protected, unprotected, ratio, sites}`
  for CI. The structured fields follow ADR-61 (an agent consumes them without parsing
  text).
- **WD4 — Tier 2 phased, changed-files-scoped (implemented).** The mutation tier ships
  after Tier 1, defaults to `git`-changed files (`git status --porcelain`; explicit paths
  override and enable the whole-project opt-in), and reuses the ADR-62 warm loop moved
  into `lib/` (`Protection::MutationScanner` over a once-built
  `LanguageServer::ProjectContext`). Its kill criterion (a new diagnostic signature versus
  a clean baseline) and FP-safe type-aware filter are exactly ADR-62's. `--mutation`
  requires `--protection` (usage error otherwise); `--threshold` gates on the effectiveness
  ratio; `--format json` carries `{mode, killed, survived, effectiveness_ratio, files,
  add_a_type_here}`.
- **WD5 — the act-on-coverage skill layer (proposed; not implemented).** Tiers 1–2
  *surface* "add a type here"; they never author the type. The follow-on is an **agent
  skill** (not a new analyzer surface) that closes the loop per unprotected site:
  `coverage --protection` (Tier 1 `add_a_type_here`, optionally Tier-2-confirmed) → **try
  `rigor sig-gen` first** → hand-author a *minimal* annotation only for the residual sig-gen
  cannot reach → **double-gate verify**. **Load-bearing criterion (ADR-59):** the mutation /
  coverage signal is a *witness that prioritizes and verifies*, never the type's *source* —
  the type is modelled from the real contract (code + usage), so a wrong guess can never
  become a binding signature. Guardrails: (a) **sig-gen-first** (AGENTS.md § RBS Authorship)
  — a hand-written annotation is the residual, and each residual is itself a
  sig-gen-improvement signal to record, not discard; (b) **"minimal" = annotation
  *footprint*, not minimal-to-kill-the-mutant** — optimizing literally for mutant-death
  Goodharts the metric and yields semantically-wrong types (worse than none, a future FP
  source); (c) **double gate** — a candidate lands only when the site becomes protected /
  the targeted mutant dies *and* `rigor check` stays diagnostic-clean (no new FP), reusing
  the ADR-62/57 adjudicate-don't-assume protocol; (d) **robustness** (ADR-5: tighten
  returns, keep params lenient — an over-tight param annotation breaks callers, breaching
  the FP discipline); (e) **cheapest carrier per hole class** — `Dynamic` return → annotate
  that method's return (via sig-gen); `Dynamic[top] | nil` ivar read → `# @rbs @field: T`
  (ADR-58 territory, the protection-hole majority); untyped param → a lenient param
  annotation. **Carrier caveat (dry-run-confirmed 2026-06-16):** a sidecar `.rbs` is *not*
  purely additive — declaring a class flips it from inference-mode to RBS-declared mode and
  drops the inferred members the file omits (a lone `formatted: () -> String` sig regressed
  `Money.new(500)` to a "wrong number of arguments" FP because the partial RBS had no
  `initialize`). So either adopt the full sig-gen base *before* adding the residual, or use
  an in-place additive carrier (rbs-inline `#:` / `%a{rigor:v1:…}`). Gate (c) catches the
  miss either way. **Scope: user projects, not Rigor's own `lib/`** — injecting hand types into
  the self-checked tree collides hardest with the sig-gen ethos; this rides the ADR-31
  external-author / v0.2.0-queued skill path, not a contributor lib-coverage tool. Entry
  tier is the shipped Tier-1 static proxy (interactive); Tier-2 confirmation is an opt-in
  deepening. May graduate to its own ADR + `SKILL.md` once past WD shape.

## Rejected / deferred alternatives

| Alternative | Verdict |
| --- | --- |
| Headline the raw mutation **survival %** | **Rejected** — the ADR-62 Criterion-A trap; survival is dominated by correct equivalent-mutants and reads as "your code is broken". Always frame as effectiveness / add-a-type. |
| A new dedicated command (`rigor teeth`) | **Rejected** — protection is a coverage dimension; extending `coverage` reuses threshold/JSON and keeps the concept together (WD1). |
| Mutation (Tier 2) as the only / default tier | **Rejected** — minutes per project, not interactive; Tier 1's one-pass proxy carries the everyday value, Tier 2 is the opt-in deep-dive. |
| Whole-project Tier 2 by default | **Deferred** — changed-files default; whole-project is an explicit opt-in (ADR-46 incremental would make it cheaper later). |
| Ship the full ADR-62 harness (sweep/fuzz/clustering) as user CLI | **Rejected** — stays dev-only (ADR-62 WD4); only the narrow per-file effectiveness measurement is productized. |
| Author the *minimal type that kills the mutant* (mutation-as-type-source) | **Rejected (WD5)** — Goodharts the metric: kills the synthetic variant while diverging from the real contract, a false-confidence type worse than none. The signal prioritizes/verifies; the contract sources the type (ADR-59). |
| The act-on-coverage layer as a new CLI/engine surface | **Deferred to a skill (WD5)** — authoring a type is an agent judgement (sig-gen-first, then a residual annotation, gated by `rigor check`), not an analyzer pass; it consumes the shipped command rather than extending it. |

## Consequences

- **Positive** — users get an actionable "how protected is my code + where to add a type"
  view that the mutation work proved meaningful; reuses the existing coverage gate/JSON;
  Tier 1 is cheap and sound.
- **Negative** — Tier 1 over-estimates (concrete receiver ≠ a diagnostic actually fires);
  the report must teach that it is an upper bound. Tier 2 adds a supported, perf-sensitive
  surface (the maintenance ADR-62 deliberately avoided) — hence phased and scoped.
- **Carry-over** — both tiers have landed. The optional per-file mutation cap is now wired
  as `--limit N` / `--seed` (2026-06-17, with [ADR-70](70-fused-protection-coverage.md)'s
  `--include-dynamic` cost), bounding pathological files via a deterministic sample (ratios
  become estimates, noted on stderr). Remaining demand-gated: an ADR-46-incremental-backed
  cheaper whole-project Tier 2. **WD5 (proposed)** — the
  act-on-coverage skill that authors the residual type and verifies, downstream of the
  shipped command; design parked here, may graduate to its own ADR + `SKILL.md`.

## Relationship to other ADRs

- **ADR-62** — productizes its teeth measurement for users; honours WD4 by shipping only a
  narrow subset (Tier 2), keeping the dev harness dev-only.
- **ADR-61** — the JSON protection fields follow its structured-not-string rule.
- **ADR-50** — the new `--protection` / `--mutation` flags and JSON keys are frozen public
  vocabulary.
- **ADR-23** — `triage`-adjacent: protection points attention (where to type), never feeds
  severity.
- **ADR-59** (WD5) — the witness-not-signature rule: a mutation/coverage signal prioritizes
  and verifies a type but never sources it; the contract does.
- **ADR-31 / AGENTS.md § RBS Authorship** (WD5) — the act-on-coverage layer is the
  external-author / v0.2.0-queued skill path and is sig-gen-first; a hand-written annotation
  is the residual sig-gen cannot reach.
