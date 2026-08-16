# CONTEXT.md — domain glossary

The terms this project speaks in, with the traps marked. Canonical sources: the one-page type-system
guide [`docs/types.md`](docs/types.md), the normative corpus
[`docs/type-specification/`](docs/type-specification/README.md), and the analyzer-internal contracts
[`docs/internal-spec/`](docs/internal-spec/README.md). This file defines *usage*; those documents
define *behaviour*.

## Trapped terms — check before using

- **interface** — always *structural* in Rigor/RBS (Go's `interface`, Python's `Protocol`): satisfied
  by having the methods, no `implements` clause. Never the Java/PHP nominal sense. Qualify as
  "structural interface" on first use. An engine-internal duck-typed seam (a dispatch tier's
  `try_dispatch`) is an **interface**, not a protocol.
- **protocol** — reserved for [ADR-28](docs/adr/28-path-scoped-protocol-contracts.md)'s path-scoped
  *behavioural* method contract (a plugin-manifest field). Do not use it for structural typing.
- **scope** — overloaded three ways, so never write it bare. `Rigor::Scope` is the inference
  object (flow state + discovery index); **analysis scope** is which files one invocation produces
  diagnostics for (editor mode's option A / option B); **publish set** is the LSP's notification
  target. Qualify which one you mean on every use.
- **budget** — the spec's configurable `budgets:` table is **not wired** (#123 tracks it); operative
  cutoffs today are three hard-coded guards plus ADR-10's `budget_per_gem`. Do not describe budget
  behaviour as configurable.

## Core vocabulary

- **carrier** — an internal type object (`Rigor::Type::*`) carrying more precision than its RBS
  erasure: `Constant[T]`, `Tuple`, `HashShape`, `Refined`, `DataInstance`, … The full contract every
  carrier satisfies is `docs/internal-spec/internal-type-api.md`.
- **`Dynamic[T]`** — the gradual type: "statically unknown, believed within envelope `T`"; `untyped`
  is `Dynamic[top]`. A `Dynamic` carries a **dynamic origin** (why it is dynamic — ADR-75/82), which
  routes remediation.
- **narrowing** — flow-sensitive refinement of a binding's type along control-flow edges
  (`docs/type-specification/control-flow-analysis.md`).
- **folding** — evaluating an expression to a value-precise carrier at analysis time
  (`[1,2].first → Constant[1]`).
- **erasure** — the conservative mapping of a carrier to spellable RBS
  (`docs/type-specification/rbs-erasure.md`).
- **dispatch tier** — one stage of method-call resolution; the dispatcher's tier ordering is
  normative (`docs/internal-spec/inference-engine.md`).
- **diagnostic** — one finding, identified as `family.rule-name` (`call.undefined-method`);
  the taxonomy is `docs/type-specification/diagnostic-policy.md`.
- **baseline** — `.rigor-baseline.yml`, the acknowledged pre-existing diagnostics a project starts
  from (ADR-22); only *new* findings surface.
- **publish set** — the URIs one `textDocument/publishDiagnostics` round targets. Distinct from the
  analysis scope that produced the diagnostics: a whole-project analysis can have a publish set of
  one open buffer.
- **protection coverage** — the user-facing "what fraction of call sites the types protect" metric
  (`rigor coverage --protection`, ADR-63/70).
- **plugin contract** — the `Plugin::Base` manifest surface (`plugins/` production gems,
  `examples/` walkthroughs); the extension seams are narrow per ADR-37.
- **plugin gate** — compiled per-run tables that keep plugin code off the hot path (ADR-52).
- **WD** (working decision) / **slice** — a numbered sub-decision inside an ADR / an independently
  landable increment of one.
- **corpus / survey project** — real OSS apps under `~/repo/ruby/rigor-survey/` used as FP gates;
  "byte-identical on the corpus" is the standard no-regression claim.
- **teeth** — a check's ability to actually fail (measured by mutation, ADR-62); its dual is the
  **false-positive discipline**: "the program works" outranks worst-case static reading.
- **evaluation line** — the `0.2.x`/`0.3.x` releases: gather feedback, complete the feature set,
  freeze the contract at v1.0.0 (ADR-50).
- **effect label** — a dot-path side-effect classification (`io.db.read`, `nondet.time`,
  `rails.activejob.enqueue`) checked by segment-aware prefix subsumption; the *second dimension*
  beside a type (ADR-103). Always the compound — bare "effect" already names the engine-internal
  **effect model** and the **flow effect** bundle (`Rigor::FlowContribution`), which are about
  narrowing / mutation / escape facts, not I/O.
- **effect summary** — a method's inferred effect labels: a *proven* lane, a *declared* (`≤`)
  lane, and an exhaustiveness bit; non-exhaustive reads "these, and possibly more" and never
  produces a finding.
- **effect envelope** — an author-declared upper bound on a method's effect labels (`%a{pure}`,
  `%a{rigor:v1:effect …}`, or a `.rigor.yml` convention stanza), checked against the proven lane
  only. Always the compound — bare "envelope" is already `Dynamic[T]`'s "believed within envelope
  `T`" and ADR-100's "FP envelope".
- **origin** — where an effect label came from: `(callee-or-construct, colouring-source)`,
  line-free; policy tolerance discharges a whole origin at once.
- **effect snapshot** — `.rigor-effects.yml`, the committed record of every method's *direct*
  summary plus the transitive **reach** at declared entry points; `rigor effects check` gates its
  drift. Not a **baseline**: a baseline hides known findings so only new ones surface, the snapshot
  hides nothing and records observed state.
- **reach** — the transitive effect footprint of an entry point (a controller action, a job's
  `perform`), as opposed to a method's *direct* summary (its own code plus catalogued callees).
