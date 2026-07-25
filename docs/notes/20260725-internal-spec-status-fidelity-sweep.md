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

## Second pass — the three large documents, read line by line

The first pass left `inference-engine.md` (614), `plugin.md` (719) and `cache.md` (836) at the
enumerated-surface level. They were then audited claim by claim, one independent-context agent each,
every finding required to carry `file:line` evidence, and the load-bearing ones re-verified against
`lib/` before anything was applied. The three documents together produced **31 findings** — four times
the first pass's rate over eight documents, which is the expected shape: these are the oldest and
largest documents in the corpus, and size is where an unrevisited sentence hides.

### `cache.md` — 12 findings

The subsystem has churned through ADR-6, ADR-45, ADR-54, ADR-60, ADR-87 and ADR-46; the document
tracked the big structural changes and lost the sentences written for an earlier slice.

- **The one that would have cost a plugin author a debugging session.** § `fetch_or_validate` said a
  write that is not `Marshal`-clean "is swallowed: the freshly-computed value is returned and the next
  run recomputes". `try_write_entry` rescues only `SystemCallError, IOError`
  ([`store.rb:496`](../../lib/rigor/cache/store.rb)) — a producer contract violation **raises and
  aborts the run**, deliberately, and `store_spec.rb:363` pins it in that direction. The document
  promised graceful degradation where the code promises visibility.
- **Two rescue clauses narrated as `StandardError`** that are `::RBS::BaseError` in `lib/`
  (`rbs_loader.rb:644`, `rbs_constant_table.rb:26`). Both carry comments saying the narrow rescue is
  deliberate — a broad one hid a v0.0.9 regression. A port following the document would reintroduce it.
- **An expired reservation.** § Diagnostic provenance said no production caller sets a non-default
  `source_family`; four do (`:rbs_extended`, `plugin.<id>`, `:contribution_merge`, `:plugin_loader`).
  Only `generated.<provider>` is still reserved, and now says so with the marker.
- **A counter-bump order that was the reverse of the code**, a `:stat` comparator missing from the
  strictness ordering, an in-process memo attributed to a method that deliberately has none, "the
  single producer-facing entry point" when there are three, a slice narrative that outran itself, a
  descriptor section two producers and one config slot short, and a `--cache-stats` sample stale in
  both of its checkable fields.

The sample fix is worth recording as a pattern: the marker literally contains the gem version, so any
pinned sample rots at the next release — the same failure class this sweep exists to close. It now
carries both a current literal **and** the composition it is built from, so a future reader can tell
staleness from fault without reading `lib/`.

### `inference-engine.md` — 12 findings

- **A normative purity clause that `lib/` violates.** The document says `type_of` "MUST NOT mutate the
  receiver scope or any object reachable from it" and that the fallback tracer "is the ONLY mutable
  state observable from `Scope#type_of`". Two identity-keyed side-tables — `dynamic_origins` (ADR-75 /
  ADR-82) and `void_origins` (ADR-100) — are written in place during `type_of`, on the fallback path,
  regardless of `tracer:` ([`expression_typer.rb:934`](../../lib/rigor/inference/expression_typer.rb)
  and a dozen more sites), and are public readers. The provenance model postdates the clause and the
  document never mentions it. What still holds — the return value and every flow-state field are pure,
  and the tables are excluded from `Scope#==` / `#hash` and never read back into a typing decision — is
  now stated as the guarantee, rather than left to be inferred from a clause that overshoots.
- **Two self-contradictions.** The `&&` / `||` result-type MUST ("the union of the two operand types",
  narrowing deferred to a later slice) is contradicted by the same document 240 lines later and by
  `statement_evaluator.rb:1250`, which unions the *narrowed* LHS edge with the RHS. The compound-write
  deferral is contradicted 18 lines later by the section describing the handlers that landed.
- **`OverloadSelector`'s contract described a single first-match-wins pass** over declaration order.
  It is three ordered passes (strict → alias-strict-arm → gradual) over a list already reordered by
  receiver affinity, so a gradually-matching first overload loses to a strictly-matching later one.
- **A removed surface still named in the present tense** — `with_declared_types`, which exists nowhere
  in the repo except that sentence, and whose removal *this same document* records 280 lines earlier.
  The mechanical backtick pre-pass should have caught it and did not: it only checks names the document
  spells inside backticks against `lib/`, and this one is spelled that way — a gap in the pre-pass, now
  known.
- Plus `DEFAULT_LIBRARIES` enumerated as 11 names when it ships 55, a `DiscoveryIndex` field list two
  short, a `dispatch` signature missing `call_node:`, a tier order missing two live tiers (one of them
  above "first"), and `ScopeIndexer.index`'s `Hash#default` described as the caller's `default_scope`
  when it is the seeded scope.

### `plugin.md` — 7 findings, one of them the sweep's best catch

**The document told plugin authors that three live APIs were deleted.** ADR-80 renamed
`type_specifier` → `narrowing_facts`, and a mechanical rename swept the parenthetical that was supposed
to name the **old** surfaces — so the sentence reads "the old verb … is gone in 0.3.0, together with the
reader (`narrowing_facts_rules`), the engine consumer (`#narrowing_facts_for`), and the capability key
(`narrowing_facts_methods`)". All three are the *current* spellings, all three ship
([`base.rb:413`](../../lib/rigor/plugin/base.rb), `:548`, `plugins_renderer.rb:109`), and two are pinned
as live by `public_api_drift_spec`. The document contradicts the drift spec directly and itself twice.
The audience for this sentence is a plugin author who has just been told to migrate *to* those names.

The rename's blast radius is the lesson: a search-and-replace over prose cannot distinguish a name being
*used* from a name being *quoted as removed*, and the second reading inverts the meaning.

The rest: the engine no longer invokes `#node_rule_diagnostics` (ADR-52 WD4 moved dispatch to one shared
walk; the instance method survives for plugin specs), `tableize` is documented as delegating to
`ActiveSupport::Inflector` when it is deliberately **not** (AS returns `admin/users`, ActiveRecord's real
table name is `admin_users` — a port following the document is wrong on every namespaced model),
`additional_initializers` missing its `block_methods:` tier, the `plugins:` entry shape missing
`enabled:` (the ADR-93 opt-out for the auto-wired default), `#prepare` described as run-once when it runs
once *per plugin instance* — coordinator plus every fork worker — and a v0.1.0 status anchor the document
itself outruns.

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

**Built, same day** ([#211](https://github.com/rigortype/rigor/issues/211)) — `manual_drift_spec.rb`
axis 6, recorded as ADR-92 WD6. Two things it taught while being calibrated against the live corpus,
both now encoded in the check:

- **Bullets are not sentences.** Joining a hard-wrapped paragraph pairs a marker in one list item
  with a version literal in the next, and the axis reports a sentence nobody wrote. List items and
  table rows are split as their own units first.
- **Sharing a sentence is not being promised.** "Re-attempt the v0.0.9 carry-over … that work is
  descoped and lands in a separate v0.1.x ticket" names an old version for *history* while promising
  something else. The version must sit within a short window of the marker — the promise has to
  *govern* the version.

The gate is a floor, not a ceiling: `public-api.md` carried three stale sentences it does not match
("until v0.1.0 ratifies them", "still in flux as the v0.1.0 plugin observability story finalises",
"the one plugin-side cache producers **will** ride" — they do ride it). Found by reading, fixed in
the same pass. Per ADR-92 WD1 the manual probe stays the instrument for the prose body.
