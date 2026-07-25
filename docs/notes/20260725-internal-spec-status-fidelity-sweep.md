# internal-spec status-fidelity sweep (ADR-92 probe, 2026-07-25)

[#163](https://github.com/rigortype/rigor/issues/163). ADR-92's normative-status-fidelity probe was run
against [`internal-type-api.md`](../internal-spec/internal-type-api.md) only; the reading-order table lists
14 other documents that were never swept. This ledger records the probe per document — what was checked,
what was found, and what was left alone — so the next sweep starts from evidence rather than from scratch.

**The probe.** For each document: take the surfaces it *enumerates* (ADR-92 WD1 binds enumerable
declaration tables, not the ~836 prose `MUST`s), and for each, ask whether it exists in `lib/` as written.
Three outcomes per divergence, per ADR-92's Decision: implement, narrow the clause to what ships, or mark
the gap. Silence is never one of them.

A mechanical pre-pass (extract every backticked `Foo::Bar` / `#method` / `CONSTANT` from each document and
check for a definition site in `lib/`) found **no** unbacked names: the five hits it produced are all cases
where the document is already correct — a hook it describes as removed (`#flow_contribution_for`, ADR-52
WD3), an explicitly hypothetical class (`Rigor::Type::IntegerType`), spec-side snapshot constants, and
Prism / Ruby core methods. The ADR-92 class is not name drift; it is a document stating in the present
tense a *behaviour* that never shipped. That needs reading, not grepping — as ADR-92 WD1 already says.

## Findings

### `implementation-expectations.md` — two aspirational bullets in § Engine surface

The document's § *Engine surface* is a nine-bullet enumeration of what "the core type engine MUST expose".
Seven are shipped. Two are not:

- **"Inference budgets and incomplete-inference results that preserve the reason inference stopped."**
  There is no incomplete-inference result carrier anywhere in `lib/` (no `IncompleteInference`, no
  `incomplete_inference`), and the configurable `budgets:` surface is unwired — which
  [`inference-budgets.md:75`](../type-specification/inference-budgets.md) already marks and this document
  does not. What ships: three hard-coded recursion / fan-out guards, ADR-10's per-gem budget
  (`Configuration::Dependencies::DEFAULT_BUDGET_PER_GEM`, `budget_overrun_strategy`), and
  `DynamicOrigin::ANALYZER_BUDGET_CUTOFF` — which does preserve *a* reason, as a provenance cause on the
  value rather than as a result object. The consuming diagnostic family (`static.incomplete-inference.*`)
  is Reserved.
- **"Capability-role inference that can cache per-method requirement summaries, match them against indexed
  named interfaces when available, and keep anonymous shapes when matching is ambiguous or too expensive."**
  `capability.role` / `requirement.summar` / `role.inference` match **11 documents across the two spec
  corpora and zero files in `lib/`**; so do `interface_match` / `named_interface` / `structural_interface` /
  `InterfaceIndex`. What ships is the *explicit* half: `RbsExtended::ConformanceChecker` checks a
  `conforms-to` directive against an RBS-defined interface (presence + signature compatibility), and
  `rbs_extended.unsatisfied-conformance` reports it. The inference half — deriving a required role from a
  method body, then matching it — is exactly what
  [`control-flow-analysis.md:221`](../type-specification/control-flow-analysis.md) already lists as
  deferred. So the two corpora contradict each other, and the internal-spec side is the one stating the
  unshipped half in the present tense.

### `reflection.md` — the surface is accurate; the status framing is three versions stale

All 13 methods enumerated under § *Public API* exist in
[`lib/rigor/reflection.rb`](../../lib/rigor/reflection.rb) with the documented signatures and keyword
shapes. The drift is in the framing, not the contract:

- The Status line pins the document to **v0.0.7** and describes the facade as "the substrate the v0.1.0
  plugin API **will be** designed against". v0.1.0 shipped long ago; the current release is v0.3.0.
- § *Future evolution* states that "the v0.1.0 plugin API extends this module along three axes" —
  provenance `(value, source_family)` pairs, a unified Rigor-side `MethodDefinition` carrier, and cache
  slice descriptors. **None of the three is in `lib/rigor/reflection.rb`**; the module carries no
  provenance surface at all. A reader taking the document at its word would expect all three to be present
  as of v0.1.0.

This is ADR-49 axis 6 applied to a spec document: a future-tense promise pinned to a version that has since
shipped without it reads, after the fact, exactly like a claim that it shipped.

### `worker-session.md` — under-enumerated constructor, no false claim

§ *Shareable inputs* opens with "the constructor accepts only inputs that cross a worker boundary safely"
and then enumerates them — but omits `source_files:` and `record_dependencies:`, both of which
`WorkerSession#initialize` accepts today, and § *Ownership boundary* does not mention `#drain_dependencies`
(the ADR-46 dependency-recording window `#analyze` wraps when `record_dependencies:` is set). Everything
the document *does* say is accurate, including the equivalence contract and the `prepare`-at-construction
rule. This is completeness drift from ADR-46 landing, not an aspirational claim.

### `flow-contribution.md` — the document contradicts itself about the merger

§ Status says "v0.0.9 ships only the bundle struct itself — the merger **lands** alongside the plugin
API in v0.1.0", and § *Slot definitions* says "the merger that lands in v0.1.0 **will** define a tagged
element form". Both are stale: § *Element-list flattening*, in the same document, correctly records that
`#to_element_list` **shipped in v0.1.0** alongside the merger, and
[`flow-contribution-merger.md`](../internal-spec/flow-contribution-merger.md) specifies it. The
enumerated eight-slot table itself is exact against `lib/rigor/flow_contribution.rb`, `role_conformance`
included.

### `plugin-trust.md` — a deferral that expired

§ *What slice 2 deliberately does NOT do* closes with "Slice 2 only builds the descriptor; **nothing
consumes it yet**." That has been false since the run-result cache landed:
`Analysis::Runner#run_dependency_descriptor` reads each plugin's `@io_boundary` and folds
`boundary.cache_descriptor.files` into the run's dependency descriptor, so a boundary read participates
in invalidation like any analyzed or `sig` file. This is the *inverse* of the ADR-92 class — a document
under-claiming what ships — and it is the case ADR-92 WD4 calls "the marker expires". Every enumerated
surface in the document (`TrustPolicy` fields and predicates, the three `IoBoundary` methods, the seven
`AccessDeniedError` reasons, the three `Services` methods) is accurate and drift-pinned by
`public_api_drift_spec`. The section also had a stray paragraph wedged between two list items, splitting
the list in rendered output; fixed in the same pass.

### `baseline.md` — clean

Bucket key tuple, both match modes, the `count` multiplicity rule, and `CURRENT_VERSION = 1` all match
[`lib/rigor/analysis/baseline.rb`](../../lib/rigor/analysis/baseline.rb) exactly.

### Clean at the depth probed

- **`config.md`** — the two-source-of-truth split, the three validation tiers, `KNOWN_KEYS` /
  `RESERVED_NAMESPACES` / `#unknown_keys`, and all three gate axes match
  `lib/rigor/configuration.rb` and `spec/rigor/config_schema_spec.rb`.
- **`diagnostic-shape.md`** — all ten fields match `Diagnostic`'s `attr_reader` list; both factories,
  the `qualified_rule` derivation, and the `enrich_json`-only placement of `evidence_tier` /
  `documentation_url` are exact.
- **`inference-engine.md`** — the stability contract's enumerated surfaces hold, including the full
  Fallback Tracer protocol (`record_fallback` / `events` / `empty?` / `size` / `each`). Its "Slice N"
  framing is historical narration around normative rules that still bind, not a status claim.
- **`macro-substrate.md`**, **`plugin-cache-producers.md`**, **`dependency-source-inference.md`** —
  these already practise ADR-92's rubric unprompted: each deferral is marked at the point of
  declaration (`:receiver_singleton` / `:dsl_recorder` "reserved names, not yet accepted"; the
  descoped v0.0.9 `Reflection` carry-over; the deferred per-method return precision), and
  `plugin-cache-producers.md` even annotates a superseded item with the ADR that replaced it.

## Coverage — what depth each document actually got

Honesty about the instrument, since a sweep that over-claims its own coverage is the failure this
ledger exists to prevent:

- **All 18 documents** got the mechanical name-level pre-pass (every backticked surface checked for a
  definition site in `lib/`) — clean, as described above.
- **Read in full and probed claim by claim:** `implementation-expectations.md`, `reflection.md`,
  `worker-session.md`, `baseline.md`, `diagnostic-shape.md`, `config.md`, `plugin-trust.md`,
  `flow-contribution.md`.
- **Probed at the enumerated-surface and status-claim level, not read line by line:**
  `inference-engine.md` (614), `plugin.md` (719), `cache.md` (836),
  `dependency-source-inference.md` (475), `flow-contribution-merger.md` (223),
  `plugin-cache-producers.md` (267), `macro-substrate.md` (195), `public-api.md` (194). A
  corpus-wide grep for version-anchored future tense and deferral language covered every one of them;
  the hits it produced are adjudicated above. A full claim-by-claim read of the three large documents
  is the obvious next slice if #163 stays open.

## The dominant class, and what it suggests for the gate

`internal-type-api.md` — the one document ADR-92 swept — was the *never implemented* class. Only
`implementation-expectations.md` repeats it. The dominant class in the rest of the corpus is different
and was not anticipated: **a version-anchored future tense that the release then outran**. "The merger
lands in v0.1.0", "the v0.1.0 plugin API extends this module", "nothing consumes it yet" were all true
when written and are all false now, and nothing in the corpus expires them. Three of the five findings
are that shape.

ADR-92's WD4 gate cannot see this class — it reads the diagnostic-family table. A cheap gate that
could: flag any spec sentence naming a released version in the future tense ("lands in v0.1.0", "will
be", "v0.1.0 introduces") once `Rigor::VERSION` has passed that version. That is a mechanical,
low-false-positive check over a corpus this small, and it would have caught three of these five before
a reader did. Worth its own issue rather than being smuggled into this sweep.
