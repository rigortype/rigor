# ADR-69 — Pluggable mutation substrate (kill-oracle + operator seam)

Status: **Proposed — not yet implemented; actionable now (a refactor, no new user surface).**
Generalize the ADR-62/63 mutation machinery so the **kill oracle** and the **site-selection
strategy** are parameters, not assumptions baked into `Protection::MutationScanner`. Today
the only oracle is "a new Rigor diagnostic appeared" and the only selector is "keep sites
Rigor can bite"; both are hard-wired. This ADR makes the substrate carry a second oracle
(*"the test suite went red"*) and the inverted selector a test-oriented consumer needs —
the prerequisite for [ADR-70](70-fused-protection-coverage.md) and the optionality
[ADR-71](71-type-guided-external-mutation-testing.md) wants — without re-architecture.

Grounding: [`docs/notes/20260617-type-guided-mutation-testing-strategy.md`](../notes/20260617-type-guided-mutation-testing-strategy.md)
(the strategy split this enables) and the current code:
`lib/rigor/protection/mutator.rb`, `lib/rigor/protection/mutation_scanner.rb`.

## Context

The mutation code has exactly one shape, optimized for the analyzer-teeth question:
`MutationScanner#classify` (`mutation_scanner.rb` ~L85) defines a **kill** as a new
diagnostic-signature versus a clean baseline, and `Mutator#filter_by_type`
(`mutator.rb` ~L89) keeps a mutation only where Rigor's anchor type is concrete (where the
analyzer *can* bite). Both are correct for ADR-62/63 and **wrong** for a test-suite
consumer, which (a) kills by *running tests*, not by re-analysis, and (b) wants the
**opposite** selection — mutate everywhere, especially the `Dynamic` sites the type filter
discards, because that is where tests are the only protection. The two axes are entangled
in one class, so neither ADR-70's dynamic overlay nor any future external tool can reuse the
splicer + warm loop without forking it.

## Decision

Factor the substrate along two seams, leaving the Prism splicer oracle-agnostic.

> **Criterion (the reusable rule):** the **kill oracle** and the **site selector** are
> injected collaborators of the scanner, never properties of the mutator. The `Mutator`
> knows only how to *splice source* and *where contracts live* (the anchor); deciding
> *what counts as a kill* and *which sites are worth mutating* belongs to the consumer. A
> capability the substrate cannot express by swapping an oracle/selector is a seam gap, not
> a reason to copy the mutator.

- **Seam 1 — the kill oracle.** Extract today's logic into a `DiagnosticOracle` (a mutant
  is killed iff `Runner#run_source` yields a diagnostic absent from the clean baseline) and
  define the interface a `TestSuiteOracle` (ADR-70) will implement (run the suite, killed
  iff it goes red). The scanner takes an oracle; `classify` calls `oracle.killed?(clean,
  mutant)`. The `DiagnosticOracle` path stays **byte-identical** to today.
- **Seam 2 — the site selector.** The type-aware filter (`filter_by_type`) becomes one
  strategy (`BiteableSites` — keep concrete-anchor sites, FP-safe), separable from the
  `Mutator` so a consumer can pass `AllSites` / a `Dynamic`-preferring selector instead.
  The mutator still *records* the anchor + its type for reporting; it no longer *decides*
  to drop on it.
- **No new user surface.** This is internal restructuring under ADR-50 (the frozen contract
  is the CLI vocabulary + JSON keys, not the `Protection::*` class shapes). `tool/mutation/`
  and the ADR-63 `coverage --protection --mutation` command observe no behavioural change.

## Rejected / deferred alternatives

| Alternative | Verdict |
| --- | --- |
| Leave the kill/selection logic in `MutationScanner`; copy the mutator for the test consumer | **Rejected** — two divergent copies of the splicer is the maintenance trap; the seam is the cheaper structure and the whole point of ADR-52's "compile once, dispatch by a key the engine holds" instinct applied here. |
| One oracle that returns both "Rigor bit" and "tests went red" | **Rejected** — couples the analyzer run to a test run for *every* mutant, defeating ADR-70's gradual short-circuit (only survivors need the suite). Two oracles, composed by the consumer. |
| Make the seam a public plugin/extension API now | **Deferred to ADR-71** — externalizing is demand-gated; an internal seam is enough for ADR-70 and keeps the surface off the v1.0 freeze. |

## Consequences

- **Positive** — ADR-70 layers a dynamic oracle with no fork; ADR-71's external option
  inherits a clean substrate instead of a rewrite; `tool/mutation/` and `coverage` keep one
  source of truth (the mutator), now genuinely oracle-neutral.
- **Negative** — a small indirection cost (an interface where there was a method) for value
  that only materializes once ADR-70 lands; if ADR-70 were abandoned the seam would be
  dead abstraction (so land them together).
- **Carry-over** — implement alongside ADR-70's first dynamic consumer so the
  `TestSuiteOracle` interface is exercised, not speculative. Gate: the `DiagnosticOracle`
  path is byte-identical on the ADR-63 `coverage --protection --mutation` measurement.

## Relationship to other ADRs

- **ADR-62 / ADR-63** — refactors their shared `Protection::Mutator` / `MutationScanner`;
  the `DiagnosticOracle` is their behaviour, preserved exactly.
- **ADR-70** — the first `TestSuiteOracle` consumer; co-lands with this seam.
- **ADR-71** — the external tool inherits this substrate; the seam is the optionality buy.
- **ADR-50** — internal class shapes are *not* the frozen surface; this adds no CLI/JSON
  vocabulary.
</content>
