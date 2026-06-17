# ADR-69 — Pluggable mutation substrate (kill-oracle + operator seam)

Status: **Accepted — both seams implemented 2026-06-17.** Seam 1 (kill oracle) co-landed
with [ADR-70](70-fused-protection-coverage.md); Seam 2 (site selector, surfaced as
`--include-dynamic`) followed the same day — pulled forward from
[ADR-71](71-type-guided-external-mutation-testing.md) when validating ADR-70 showed the fused
overlay could not otherwise reach `Dynamic` sites (the map's most valuable cell). Generalize
the ADR-62/63 mutation machinery so the **kill oracle** and the **site-selection strategy**
are parameters, not assumptions baked into `Protection::MutationScanner`: the substrate now
carries a second oracle (*"the test suite went red"*, `Protection::TestSuiteOracle`) and a
second selector (`:all` — mutate `Dynamic`-receiver dispatch sites too, where a test is the
only possible protection).

Implemented: `diagnostic_oracle.rb` (Seam 1, the extracted ADR-62/63 behaviour),
`Mutator#dispatch_site_mutations` (Seam 2 — every dispatch site, Dynamic included),
`MutationScanner#initialize(oracle:, site_selector:)` + `#scan_file_fused` consuming both.

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

- **Seam 1 — the kill oracle. Implemented.** Today's logic is extracted into a
  `DiagnosticOracle` (a mutant is killed iff `Runner#run_source` yields a diagnostic absent
  from the clean baseline); the interface (`#baseline`, `#killed?`) is what `TestSuiteOracle`
  (ADR-70) implements. The scanner takes `oracle:` and routes its `classify` through it; the
  `DiagnosticOracle` default is **byte-identical** to today (the ADR-63 Tier 2 scanner spec
  is unchanged).
- **Seam 2 — the site selector. Implemented (`MutationScanner site_selector:`).** The
  biteable filter (`filter_by_type` — keep concrete-anchor sites, FP-safe) is now one
  strategy; `Mutator#dispatch_site_mutations` is the other (`:all` — keep every dispatch
  site, Dynamic receiver included; drop only non-dispatch literals). It is gated to the fused
  overlay's `--with-tests` path (at a `Dynamic` site the type pass can never kill, so without
  the test axis these are all noise — the ADR-62 Criterion-A trap). The ADR-63 Tier 2
  `scan_file` stays `:biteable`, unchanged. This was *deferred to ADR-71* until the 2026-06-17
  ADR-70 validation made the demand concrete (the overlay was blind to `Dynamic` sites — the
  exact place a *test*-protection view matters most); building it is contained — it reuses
  the existing warm loop and changes only which sites are mutated — not the ADR-71 external
  product.
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
- **Carry-over** — both seams co-landed with ADR-70; the `DiagnosticOracle` default kept the
  ADR-63 scanner spec green (the byte-identical gate). Seam 2 was pulled forward the same day
  on the validation's empirical demand (the overlay was blind to `Dynamic` sites); validated
  on liquid `lexer.rb` — `--include-dynamic` widened the map from 76 biteable sites (75 type /
  1 test / 0 unprotected) to 115 dispatch sites (75 type / **38 test** / **2 unprotected**),
  surfacing the test-protected `Dynamic` cell and two real gaps biteable-only could not see.
  The remaining ADR-71 boundary is a *public* selector/oracle plugin API, still demand-gated.

## Relationship to other ADRs

- **ADR-62 / ADR-63** — refactors their shared `Protection::Mutator` / `MutationScanner`;
  the `DiagnosticOracle` is their behaviour, preserved exactly.
- **ADR-70** — the first `TestSuiteOracle` consumer; co-lands with this seam.
- **ADR-71** — the external tool inherits this substrate; the seam is the optionality buy.
- **ADR-50** — internal class shapes are *not* the frozen surface; this adds no CLI/JSON
  vocabulary.
</content>
