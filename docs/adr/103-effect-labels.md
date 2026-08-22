# ADR-103 — Effect labels: an opt-in, snapshot-first effect system

Status: **Proposed, 2026-08-16.** Records the decisions reached while designing the effect system in
[`docs/design/20260816-effect-labels.md`](../design/20260816-effect-labels.md) (the design note;
its § 13 lists the choices, this ADR fixes them as working decisions; WD13, coexistence with
`rigor check`, was added the same day; WD14, the pre-implementation decisions, and WD15, the
v0.4.0 default-on ruling and its preconditions, both on 2026-08-17; WD16, which resolves five of
those six preconditions, on 2026-08-22 — the sixth is the release-notes migration note, written at
the release, so nothing about the default changes before v0.4.0). Two items remain open, both
deferrable to the view slices. Implementation is sliced as GitHub issues under the umbrella
[#376](https://github.com/rigortype/rigor/issues/376) (18 tracer-bullet slices, #377–#394; tracker
convention: [ADR-98](98-development-flow-document-roles.md)).

Grounding: Steins' implemented model
([why-effects](https://github.com/rigortype/steins/blob/master/docs/why-effects.md),
[effects.md](https://github.com/rigortype/steins/blob/master/docs/type-specification/effects.md),
[phpdoc-effects-interop.md](https://github.com/rigortype/steins/blob/master/docs/type-specification/phpdoc-effects-interop.md)),
the PHPStan RFC draft
([20260812-issue-draft-effect-labels-spec.md](https://github.com/zonuexe/phpstan-notes/blob/master/generated-report/20260812-issue-draft-effect-labels-spec.md)),
and the repository facts gathered on 2026-08-16 (design note § 14) — chiefly that Rigor has no
method-level call graph, that `rigor:v1:pure` is spec'd but unimplemented, and that the
2026-07-15 PHPStan-rules re-survey rejected inferred-purity rules as high-FP
([`docs/notes/20260715-phpstan-rules-survey-rigor-reevaluation.md`](../notes/20260715-phpstan-rules-survey-rigor-reevaluation.md)).

## Context

A type says what a method returns; it does not say whether the method reads a database,
consults the clock, sends an HTTP request or enqueues a job. Steins infers that second dimension
for PHP as hierarchical **effect labels** (`io.db`, `io.net.http`, `nondet.time`), propagated over
the call graph and checked against author-declared upper bounds ("effect envelopes"); the same
model is drafted as an opt-in parameter of PHPStan's `@phpstan-impure`. The rigortype organisation
runs both analyzers, so a shared vocabulary and shared diagnostic identifiers are a goal in
themselves.

Ruby adds two motivations. The engine already wants the information — `StatementEvaluator` resets
every narrowed ivar across a self-call because "we cannot prove purity without an effect system",
the purity policy of [control-flow-analysis.md](../type-specification/control-flow-analysis.md) is
impure-by-default with a `rigor:v1:pure` no code reads, and the constant-folding tier gates on a
hand-picked allow-list. And Ruby's culture puts effects in conventions Rigor cannot see —
`sort`/`sort!`, "presenters do not query", "no `Time.now` in a model" — enforced by eye.

The intent this ADR serves: **make the effect footprint of existing Ruby code observable and
reviewable, opt-in, without requiring anything to be written in application code, and without
spending any of the false-positive budget** ([ADR-5](5-robustness-principle.md), AGENTS.md
"false positives outrank worst-case static reading"). The corpus's earlier verdict — inferred
purity is unknowable in Ruby (memoising ivar writes, monkey-patching, C implementations) — is
the constraint every decision below answers rather than contradicts.

## Decision

Adopt Steins' model unchanged, and add three Ruby-specific commitments. The discriminating
criterion, stated once:

> **A verdict may read only what the analyzer proved; what it could not prove is recorded, never
> judged; and validation defaults to observing the record, not to declaring a bound.**

The first clause is Steins' proven-lane rule and the repository's "as strict as proven"
([robustness-principle.md](../type-specification/robustness-principle.md)). The second is why an
unresolved call taints exhaustiveness and produces no finding, and why the effect footprint is a
report ([ADR-102](102-unused-code-reachability-report.md)'s line: precision bounded by knowledge
the analyzer cannot have belongs in a report). The third is the Ruby-specific turn: the primary
validation is a committed **effect snapshot** whose diff is reviewed and whose drift CI gates —
`db/schema.rb` for effects — and envelopes are the optional second step.

### WD1 — The model transfers verbatim

Dot-path labels checked by segment-aware prefix subsumption; an envelope is a declared upper
bound checked structurally against the method's *code* (block literals included, dead code
included); a summary carries a *proven* lane, a *declared* (`≤`) lane and an exhaustiveness bit
tainted by any unresolved or dynamic call; diagnostics read the proven lane only; an unknown
label makes the whole tag ⊤ (fail-open) with a separate opt-in vocabulary diagnostic; class-level
envelopes distribute nearest-wins; discharge by policy (`tolerated:`) obeys Steins ADR-0084's four
invariants. Diagnostic identifiers are Steins' — `effect.envelope-exceeded`,
`effect.liskov-widened`, `effect.unknown-label`. (Design note § 4.)

### WD2 — Vocabulary: shared registry, Ruby leaves, three layers on top

The registry is Steins' v1 set of 25 labels verbatim, plus Ruby's `mutate.self` /
`mutate.arg` / `mutate.static`. `io.output.buffer` / `io.output.header` stay registered but
unproduced. On top: shared core leaves to raise with Steins (`io.db.read` / `io.db.write` /
`io.db.transaction`), a small shared application-meaning set (`telemetry`, `email.send`,
`job.enqueue`, `cache.read` / `cache.write`), and framework roots owned by the plugin that models
the framework (`rails.*` for rigor-rails; a third-party plugin opens a root equal to its plugin
id; a project's config may open any root). (§ 11.1.)

### WD3 — Origins are catalogue rows and a small set of constructs; the fold catalogue is not one

Effects originate in a hand-audited effect catalogue (`data/effects/core.yml`) and in the few
constructs Ruby has (backticks, `$gvar` reads/writes, `@@cvar`, `@ivar` writes, `alias`/`undef`,
`define_method` with a literal name). Uncatalogued methods follow a per-class default posture —
value classes ∅, world-facing classes `io` — so the exhaustive bit stays meaningful. The generated
`data/builtins/ruby_core/*.yml` `purity:` facet is **not** an effect source: it answers
fold-safety in the C-dispatch sense (`Random#rand` is `leaf`, `Array#push` is `leaf`); its
`c_effects: mutate` / `block` markers, the per-class `mutating_selectors:` blocklists,
`NON_REPRODUCIBLE_SELECTORS`, `MutationWidening`'s mutator sets and `ClosureEscapeAnalyzer`'s
tables are seeds and evidence for the new catalogue, cited, never read as labels. (§ 5.1.)

### WD4 — Ruby deltas: ownership, closed world, containment, code-not-clock

`mutate.local` names a mutating call on a receiver the frame **owns** (fresh, unescaped),
tolerated by every envelope; `mutate.self` / `mutate.arg` / `mutate.static` / bare `mutate` follow
the receiver's ownership; `@x ||= …` under `pure` is a finding. Self-calls resolve against the
project as a **closed world** — the summary joins every project-known override — and reopenings
union; `send` with a non-literal, `method_missing`, `Dynamic` receivers and duck typing taint.
Block literals **always** join the enclosing method's summary (containment), whether invoked now,
later or never; opaque callables taint; effect polymorphism therefore needs no effect variables.
Deferred execution follows the code, not the clock: builders are pure, the enqueue is the effect,
there is no edge into a deferred body, in-process deferral is containment, and a project-declared
queue adapter may narrow the enqueue's transport. Exceptions are not labels; class bodies are out
of scope in v1. (§ 5, § 11.2 "Deferred execution".)

### WD5 — Declaration surfaces: no new grammar

In order of preference: (1) nothing — inference is the default; (2) envelopes by **convention** in
`.rigor.yml` (`effects.envelopes`, path- or namespace-scoped, the [ADR-28](28-path-scoped-protocol-contracts.md)
shape); (3) `%a{pure}` — the ecosystem's existing purity annotation, read as the empty envelope
and written back by `sig-gen`; (4) `%a{rigor:v1:effect …}` / `%a{rigor:v1:pure}` on RBS method
and class declarations, carried to the engine by a new `effects` slot on `Rigor::FlowContribution`
(which finally gives the bundle's producer-less `mutations` slot a producer); (5) the same
annotations in `.rb` through rbs-inline's `# @rbs %a{…}` — permitted, amending the handbook
sentence that says otherwise; (6) plugin RBS annotations, plugin `effect_attributions:` and a
project `effects.attribution:` table for gems, plus `effects.labels:` for vocabulary. Not a
surface: a runtime DSL, a new `# rigor:` directive, a file pragma, Sorbet `sig`, the bang
convention. (§ 6.)

### WD6 — Trust: discharge follows the existing authority ladder

The catalogue and project bodies are proven. Project-authored envelopes are the checked stratum —
contract-checked, Liskov-checked, and discharging the taint of the call sites they bound. Accepted
signatures (gem RBS, Rigor's bundled overlays) and plugin `signature_paths:` RBS discharge, as
their types already are trusted; a first-party bundled plugin's framework-derived attributions
and edges discharge (gated by `make check-plugins`, derived from the app's own declarations);
third-party manifest and YAML attribution never discharge — "declared this, and possibly more".
The declared lane's carrier is nominal (a base method's envelope at the ADR-57 N5 gate) until a
structural-interface carrier exists. (§ 7.)

### WD7 — The effect snapshot is the primary validation

`rigor effects --update` writes `.rigor-effects.yml`; `--check` recomputes, prints an explained
diff and exits non-zero on drift; `--diff` prints without gating; `--explain` prints the shortest
edge path behind a reach change. The file holds `methods:` as **direct** summaries (so a diff is
attributable to the PR's own lines; exhaustive-∅ entries omitted) and `reach:` as the transitive
footprint at entry points; its header carries the Rigor and vocabulary versions and a digest of
the `effects:` config. The gate is symmetric by default (a removal is news too), with
`gate: additions` as the ratchet option; the record is undischarged and `tolerated:` applies at
judgment time. It emits no diagnostic and never enters `rigor check`'s stream. Stable observations
may be promoted into envelopes (`--promote`). It ships in the first slice, ahead of any envelope
syntax. (§ 9.4.)

### WD8 — Diagnostics: family shape first, opt-in, cache-aware

Reserve `effect.*` in the diagnostic-policy taxonomy before any id ships ([ADR-100](100-static-diagnostic-family-and-void-origins.md)
discipline), add `effect` to `RULE_FAMILIES`. `effect.envelope-exceeded` is FP-safe by two
accepted constructions at once — opt-in by author directive, and as-strict-as-proven — and needs
no bleeding-edge gate for the *new* spellings; the `%a{pure}` interop reading is the semantic
migration and is gated by the effects opt-in. `effect.discarded-pure-result` (the non-bang footgun,
gated additionally by the catalogue's `raises` facet) ships `:off` in every profile pending a
corpus gate. Summary collection is a side-table with the `dynamic_origins` properties; the
diagnostics are a post-pool aggregation; the `effects:` config joins the ADR-45 run-cache
identity; the typing consumers of WD9 land as cache-identity-aware features. (§ 9.)

### WD9 — Engine consumers, in this order, each behind its own gate

B2.2 ivar-reset skip across self-calls whose proven summary lacks `mutate.self`; the purity
policy's computed purity (nothing outside `{mutate.local}` → results may be remembered;
`global.read`-only until an intervening `global.write` / `mutate.static`; `nondet.*` never);
label-keyed invalidation buckets; the constant-folding gate as a computed property; `sig-gen`
emission of `%a{pure}` / envelopes from exhaustive, undischarged summaries only. (§ 8.)

### WD10 — Rails: framework labels where transport is adapter-dependent, edges from the plugin, builders pure

rigor-rails colours transports and `rails.*` meanings per the table in § 11.2; Relation
**builders** are ∅ and **materializers** `io.db.read`; `Rails.env` and friends are `global.read`
(tolerated by policy); the plugin contributes **edges** the syntax lacks (callbacks, validators,
`perform_now`, mailer bodies) and none it must not (`perform_later` → `perform`); ActiveSupport
core_ext receives `%a{pure}` en masse; summaries keep **per-origin label bundles** so tolerating a
semantic label discharges only the transport that came with it. A `views: lenient | strict`
preset and an illustrative layer-convention stanza ship as documentation, never enforced by
default.

### WD11 — Views are effect units

Templates compile to methods; Rigor analyses them as such: the [ADR-16](16-macro-expansion.md)
Tier-D seam (removed by [ADR-60](60-pre-freeze-plugin-contract-consolidation.md) WD1 as
demand-gated) returns with a source transform and a line map ahead of parsing; ERB compiles
through Erubi when it resolves and stdlib `ERB` otherwise, never bundled ([ADR-93](93-default-rbs-inline-ingestion.md)
posture); `self` is a per-controller view class, locals come from render sites and strict-locals
comments, ivar seeds from the rendering actions' definite assignments; `render` becomes a real
edge; every unit appears in the snapshot as `view:…`; the N+1 shape is a `query-in-loop` report
until a preloading facet makes it a diagnostic. Jbuilder, ViewComponent sidecars, Haml and Slim
ride the same seam. HTML / escaping / XSS are out of scope. (§ 11.3.)

### WD12 — Where it lives

Summaries and edges are collected during per-file typing and persisted beside
`return_summaries`; propagation is a graph-only worklist over a finite lattice in the post-pool
aggregation slot; envelope diagnostics are recomputed every run from cached summaries and never
stored per file. The label language is normative in a new
`docs/type-specification/effect-labels.md`; collection and propagation in an internal-spec
section; "effect label", "effect summary", "effect envelope" are registered as trapped compounds
in `CONTEXT.md`, and "flow effect" keeps naming the existing bundle. (§ 3, § 10.)

### WD13 — Coexistence with `rigor check`: off is free, on is observational, one cache

The switch is `effects:` in `.rigor.yml` (or running `rigor effects`); annotations alone never
turn collection on and instead earn a `:info` residual. When off, the collector costs one integer
read on the dispatch hot path — the `DependencyRecorder` activation-count shape — and the origin
scan rides `ScopeIndexer`'s existing `def` walk behind the same flag; the gate is byte-identical
`rigor check` and wall-clock within noise on the corpus. When on, collection **records what the
typer already decided and never asks it to decide more** (no on-demand walks, no extra resolution,
no `Scope` mutation); the closure is the post-pool fixpoint; working budget ≤ ~5 % wall / RSS on
mastodon and ≤ 1 s of fixpoint at gitlab scale, measured as the corpus perf notes measure. There
is one cache with two identities: the diagnostics identity is today's and is valid whichever way
effects are set, because collection is observational; the effects identity adds the vocabulary and
catalogue versions and the `effects:` digest, and its summaries are a sidecar slot beside
`return_summaries` and in the whole-run entry, written when on, ignored when off, a miss for
effects consumers only when absent. Typing consumers (WD9) fork the identity as
`BleedingEdge`-style features and never as a side effect of collection. The collector is
fail-soft: an exception drops that file's summary as non-exhaustive and never fails a check.
Editor mode does not run effects in v1. (§ 10.1.)

### WD14 — Pre-implementation decisions (grilling session, 2026-08-17)

Settled before the first slice, because the first slices bake them in; each is a decision the
design note left to the owner and now closes.

- **Vocabulary.** The `mutate` leaves are Steins ADR-0055's: `mutate.self` (self's state),
  `mutate.instance` (a receiver that is neither self nor frame-owned — an argument, another
  object, a call result), `mutate.static`; `mutate.arg` is dropped; bare `mutate` only for an
  unclassifiable receiver. **Unknown ownership taints** (cause `unknown-ownership`) rather than
  producing a proven `mutate` — Ruby's ownership is a dataflow question, and a proven parent on a
  fresh-but-unproven receiver would put findings on correct code. Vocabulary version bumps only on
  rename / removal (with a retired-spelling table), never on leaf addition.
- **Purity spelling.** `%a{pure}` is the only purity annotation; `rigor:v1:pure` is not
  implemented and the purity-policy text is amended to name `%a{pure}`. It is checked whenever
  `effects.check` is on — the `effects:` block is the opt-in, so no separate interop gate.
- **Grammar.** `%a{rigor:v1:effect io.db, nondet.time}` — space-separated head (the
  `assert` / `conforms-to` family), comma-separated bare tokens, no parenthesised comment (RBS has
  real comments; the corpus rule is bare tokens). An empty list is malformed. A class-level
  annotation distributes to every method of the Ruby class discovery knows (reopenings, other
  files, synthesised `attr_*` / `define_method` included), never to subclasses; on a module, to the
  module's own methods only; per-method wins.
- **Identity.** Keys follow the existing symbol tables: `Class#m` / `Class.m`, top-level defs as
  `<toplevel>#m` (`ScopeIndexer::TOP_LEVEL_DEF_KEY`), reopenings union, `define_method(:lit)`
  under `Class#lit` (its block becomes the body — a discovery extension, since def-node tables skip
  it today), `attr_*` / `Struct` / `Data` accessors synthesised (reader ∅, writer `mutate.self`).
- **Origin** = `(callee-or-construct, colouring-source)`, line-free; sites are kept per run for the
  report only. Policy discharge is per origin: a bundle is discharged when **any** of its labels is
  tolerated (tolerating what the origin was *for* frees its transport). Taint causes are a closed
  enum in the type spec: `dynamic-receiver` (sub-caused by `DynamicOrigin` names), `dynamic-send`,
  `method-missing`, `unresolved-self-call`, `opaque-callable`, `unknown-ownership`,
  `plugin-attribution`, `template-not-analysed`, `collector-error`, `budget`.
- **Snapshot and CLI.** `.rigor-effects.yml`, YAML in a JSON-compatible subset; `methods:` shows
  the flat projected label list (origins are `explain`'s job); synthesised default summaries and
  exhaustive-∅ methods are omitted (`--full` lists all). Verbs, mirroring `rigor baseline`:
  `rigor effects [PATH]` (report), `rigor effects update` (always writes), `check` (text /
  `--format json`, `--baseline PATH`; exit `0` fresh, `1` drift, `64` usage — the documented
  convention), `diff`, `explain` (shortest edge path per reach change). `reach:` defaults to
  empty; presets are named by plugins (`effect_entry_points:`) and adopted by config; the
  `unused --entry-point` glob syntax is shared.
- **Config.** `effects:` present ⇒ collection on; `check: true` by default; `views: false`;
  keys `snapshot.{path,reach,gate}`, `labels`, `attribution`, `envelopes[]{match|namespace,
  effect}`, `tolerated`. Label *shape* is validated at load (tier 2); a label unknown to the
  registry after plugin load makes that envelope ⊤ and surfaces as `effect.unknown-label`
  positioned at `.rigor.yml` (the `rbs.coverage.quarantined-signature` precedent) — the config
  audit is not extended to nested values. `rigor effects` without an `effects:` block runs ad hoc
  under an implicit `effects: {}` and shares no cache with `rigor check`.
- **Diagnostics.** `effect.envelope-exceeded` is positioned at the Ruby `def` (where the fix goes
  and where `# rigor:disable` works — the `.rbs`-positioned `unsatisfied-conformance` precedent
  is deliberately not followed), naming the envelope's source in the message. Severities:
  `envelope-exceeded` / `liskov-widened` warning / warning / error across lenient / balanced /
  strict; `unknown-label` info / info / warning; `discarded-pure-result` off everywhere.
- **Ruby deltas.** `require` / `require_relative` / `load` / `autoload` = `io.fs.read` +
  `mutate.static`; `sleep`, `Queue#pop`, `ConditionVariable#wait` = `io`; `Thread.new`,
  `Fiber.new`, `Ractor.new`, `Mutex#synchronize` = ∅ + containment.
- **Spec status.** `docs/type-specification/effect-labels.md` is normative from #377 with
  per-section "as of this writing" markers naming the slice that implements each (ADR-92).

### WD15 — Default-on at v0.4.0 (owner ruling, 2026-08-17)

Collection and `effects.check` become **default-on at v0.4.0**: a `.rigor.yml` with no `effects:` key
behaves as `effects: {}`, and `effects: false` opts out. `effects-on-by-default` — a `:behaviour`
[bleeding-edge feature](50-release-engineering-and-stability-strategy.md) — is the preview: adopting it
today reaches the same default early. WD7's "graduates at a major" is read, for this feature and for the
0.x evaluation line specifically, as **"at v0.4.0"** rather than waiting for v1.0.0 — the same pre-1.0
rehearsal WD7 already describes for the general case (a `v0.2.x → v0.3.0` graduation), pinned to a
specific version by owner ruling rather than left to "whenever the next minor lands".

The flip is gated on clearing six preconditions first, none of which was closed when this ruling
was written; **WD16 resolves 1-4 and 6** (2026-08-22):

1. **Pooled backends carry the effect side-table.** Collecting runs are pinned to the fork pool today;
   without `fork` (Windows) a run degrades to sequential. The Ractor and thread backends must carry the
   effect side-table across the worker boundary before default-on, or Windows silently loses collection
   under default-on the day it flips.
2. **Vocabulary and `effect.*` diagnostic ids stabilise.** #378 (alignment with Steins' vocabulary) settles
   first — a default that ships and then renames its own ids is a worse migration than waiting.
3. **The WD13 cost budget is re-verified on the corpus at the release** — the ≤5% wall/RSS and ≤1s
   fixpoint figures were measured pre-default-on, when only opted-in projects paid the cost; universality
   changes the population the budget has to hold for.
4. **`effects.lsp` semantics are defined** for editor mode — WD13 deliberately left effects out of editor
   mode in v1, and a default-on flip should not silently leave that seat empty forever.
5. **A release-notes migration note** exists for a project already carrying `%a{pure}` or relying on
   `effect.annotations-unchecked` (WD14's interop gate) — both go from inert-by-default to load-bearing the
   moment collection turns on under them.
6. **The snapshot's taint-only rows are decided.** An open observation on redmine: 2,052 of 3,581
   `methods:` rows in the snapshot carry no proven label, only `unresolved:` — before `rigor init`
   recommends `effects update` to every project, whether that ratio is acceptable (and what, if anything,
   a project should be told about it) needs an answer.

### WD16 — The graduation preconditions, resolved (owner ruling, 2026-08-22)

WD15's list was written from the design, not from the code, and two of its premises do not hold.
This ruling records what replaces them. Preconditions 1-4 and 6 are resolved here; 5 is written at
the release itself.

**1 — Pooled backends: the sequential degrade IS the answer.** There is no thread backend and there
will not be one — `pool_backend` selects `:fork`, `:ractor` or `:sequential`, and a thread pool buys
no parallelism under the GVL while sharing RBS's C-extension state across workers. The Ractor
backend cannot analyse a single file under rbs 4.x: `RBS::Namespace.[]` interns every namespace
through a process-wide mutable flyweight held in module ivars, a non-main Ractor may not read one,
and pre-warming does not reach it because the trie is consulted while parsing the cached environment
back ([#414](https://github.com/rigortype/rigor/issues/414)). The precondition as written therefore
cannot be cleared by any work Rigor owns. It is replaced by the behaviour the code already has: with
no `fork`, a collecting run degrades to sequential **and says so** through the same
`pool_degraded_diagnostic` channel the fork path uses. That degrade is sound rather than merely safe
— the sequential path still collects, so the effect graph is complete either way, and Windows pays
wall-clock, never correctness. [#410](https://github.com/rigortype/rigor/issues/410) (carry the
side-table through the non-fork backends) closes with it: its stated premise, "the only new piece is
the message channel", is untrue while the backend it targets cannot analyse a file.

**2 — Vocabulary: vocabulary 1 ships as it stands.** Read against Steins on 2026-08-22, the three
items of [#378](https://github.com/rigortype/rigor/issues/378) resolve differently from how they were
filed. The `mutate.self` / `mutate.instance` / `mutate.static` spelling already agrees (WD14). The
`io.db.read` / `io.db.write` / `io.db.transaction` leaves are Rigor's alone — Steins' builtin set
stops at `io.db` — which the registry table already says, and a leaf addition can never change what a
recognised bound admits. The application-meaning roots are the real divergence, and it is
architectural rather than lexical: Steins holds that ecosystem labels (`io.redis`, `email.send`) are
**not builtin** and reach the registry through a plugin's own manifest, while Rigor ships
`telemetry`, `email.send`, `job.enqueue`, `cache.read` and `cache.write` as rows of the shared file.
Rigor keeps them: they are what `tolerated:` grips and what a policy actually names, and a project
should not need a plugin before it can write one. What changes is the claim — the spec's registry
table called that layer "shared" and its spelling agreement a MUST, which Steins does not today
support, so the row becomes Rigor-owned and proposed upstream. Alignment is therefore not a blocker
in either direction: a spelling Steins later insists on lands through `retired:` plus a vocabulary
bump, which is the mechanism that exists for exactly this, and #378 stays open as the upstream
conversation rather than as a gate.

**3 — The WD13 budget: the CI `effect-budget` job is the arbiter.** The 2026-08-19 local measurement
that reported the budget failing was retracted against a fuller, quieter measurement two days older;
what separated them was host contamination, not method. A go/no-go decided on a developer host will
keep reproducing that failure, so the advisory `effect-budget` job's band settles the mastodon half
and nothing else does. The gitlab half — `Propagator.propagate` at 1.34 s against a 1 s bound — is
unretracted and is the live figure, but it is a closure cost paid once per run at the largest scale
in the corpus, not a per-project tax: it becomes the optimisation target of
[#424](https://github.com/rigortype/rigor/issues/424) across the v0.3.5-v0.3.9 window and does **not**
gate the flip, provided the release notes disclose it.

**4 — `effects.lsp`: editor mode stays effect-free, and the config says so.** WD13's "editor mode
does not run effects in v1" becomes the standing answer rather than a v1 caveat, spelled as a real
key defaulting to `false`. A key that exists and is off is what keeps the seat from being silently
empty after the flip; a hover that reports a method's labels is a v0.4.x slice with its own
consumer, not a precondition. Nothing in `lib/rigor/language_server/` reads effects today, so the
work is the key, its documentation, and the guard that keeps a default-on project from paying
collection cost per keystroke.

**6 — Taint-only rows** were decided by [#411](https://github.com/rigortype/rigor/issues/411) and
shipped in [#415](https://github.com/rigortype/rigor/pull/415): a row carrying only its taint is
omitted by default and `--full` keeps it.

## Rejected and deferred alternatives

| Alternative | Why not |
| --- | --- |
| A runtime DSL (`Rigor.pure def …`) or a new `# rigor:effect` comment directive | [ADR-0](0-concept.md): application code MUST NOT require Rigor-specific annotations or DSLs; rbs-inline's `%a{}` already reaches the engine and is upstream grammar |
| Read effect labels off the generated `purity:` facet | It answers a different question (fold-safety); `Random#rand` and `Array#push` are `leaf` |
| Taint every self-call because nothing is `final` | The same closed-world posture Rigor takes for types is available and far more useful; unknown receivers still taint |
| Envelopes first, snapshot as a report (Steins' shape) | The owner's operating requirement is "nothing written in code"; a committed observation gives value on day one and needs only WD12's machinery |
| Transitive summaries for every method in the snapshot | A leaf change fans out into unattributable diffs; direct summaries stay attributable to the PR, and `reach:` shows blast radius where it matters |
| Additions-only gate by default | A removal is news (a job that stopped enqueueing); the ratchet remains an option |
| Steins-strict: no plugin ever discharges | Every Rails method is then non-exhaustive forever and the bit stops carrying information |
| Relation builders coloured `io.db.read` ("how developers think") | The catalogue never lies; the caller that materialises gets the read; value provenance is the eventual answer for "the query happens in the view" |
| `%a{pure}` interop checked on the quiet default surface | A pre-existing tag would start failing — the RFC's semantic-migration claim; gate it |
| Effect labels for exceptions, concurrency primitives, `nondet.time.system` | Out of scope (throws), no consumer yet, a lint RuboCop-Rails already owns |
| Structural-interface declared lane, `$stdout`-capture masking, complement bounds | Deferred until the carrier / a consumer exists |

## Open at Proposed

Items 1 and 2 of the original list (the `mutate` leaf names; `require` and the concurrency
primitives) were closed by WD14 on 2026-08-17. Two remain, both deferrable to the view slices:

1. Whether the view preset defaults to `lenient` or `strict`, and whether `nondet.time` in a
   template is tolerated by default (provisional: `lenient`, including `nondet.time` —
   `time_ago_in_words` is a view's daily vocabulary; `strict` excludes it).
2. Whether views enter `reach:` by default (provisional: `methods:` always, `reach:` opt-in).

## Consequences

Positive: the effect footprint of a Rails application becomes observable and reviewable with
zero annotations; envelopes are available where a team wants "never" rather than "as before"; the
engine gains a computed purity property it has been asking for; the vocabulary and diagnostic ids
read the same as Steins'.

Negative: in heavily untyped code the proven lane is small and most summaries are non-exhaustive
at first — the honest state, and the report says so; the snapshot churns on Rigor upgrades and
vocabulary changes (visible, header-dated); a new catalogue is a new hand-audited artefact to
maintain; views need a core seam (Tier D) that was removed once for lack of a consumer.

Carry-over: the `mutations` / `invalidations` slots of `FlowContribution` gain their first
producer; `ClosureEscapeAnalyzer`'s reserved "RBS-Extended call-timing effect" seat becomes
reachable; the survey corpus gains a longitudinal instrument (snapshots across Rigor versions).

## Re-evaluation triggers

- The corpus measurement of the first slice shows the proven lane too small to make `reach:`
  informative on mastodon / redmine / gitlab (working threshold: fewer than half of controller
  actions with any proven label) → revisit WD3's default posture and WD6's discharge policy.
- Snapshot churn on corpus PRs unrelated to effects exceeds what a reviewer skims → revisit WD7's
  layout (`methods:` direct vs transitive) before widening `reach:` presets.
- Steins retires or renames a shared label → the retired-spelling table and a vocabulary version
  bump; a divergence in the application-meaning roots → raise upstream before shipping ours.
- The structural-interface carrier lands → the declared lane through interfaces (WD6) is designed
  in its own slice.

## Relationship to other ADRs

[ADR-0](0-concept.md) / [ADR-5](5-robustness-principle.md) set the boundaries (no required
annotations; as strict as proven). [ADR-1](1-types.md) and
[control-flow-analysis.md](../type-specification/control-flow-analysis.md) own the purity policy
this implements. [ADR-2](2-extension-api.md) governs the `FlowContribution` slot addition.
[ADR-16](16-macro-expansion.md) / [ADR-60](60-pre-freeze-plugin-contract-consolidation.md) own the
Tier-D seam WD11 revives. [ADR-28](28-path-scoped-protocol-contracts.md) is the shape of
convention envelopes. [ADR-45](45-unchanged-project-fast-path.md) / [ADR-46](46-incremental-dependency-graph.md)
/ [ADR-84](84-cross-file-return-memo-scoping.md) carry the persisted summaries. [ADR-50](50-release-engineering-and-stability-strategy.md)
governs the opt-in posture, [ADR-93](93-default-rbs-inline-ingestion.md) the never-bundled
compiler posture, [ADR-100](100-static-diagnostic-family-and-void-origins.md) the family-shape
discipline, [ADR-102](102-unused-code-reachability-report.md) the report-versus-diagnostic line.
The design note remains the research; this ADR is the decision.
