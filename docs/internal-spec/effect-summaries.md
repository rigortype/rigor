# Effect summaries — collection and propagation

Status: **Draft.** This document specifies how Rigor *produces* effect summaries: when collection runs, what the collector may and may not observe, how a file's contribution is shaped and merged, how the whole-project closure is computed, and what happens when any of it fails. The label language it produces values in — the grammar, subsumption, the registry, the lanes and the taint-cause enum — is normative in [`docs/type-specification/effect-labels.md`](../type-specification/effect-labels.md) and binds whenever a description here would conflict with it. The rationale is [ADR-103](../adr/103-effect-labels.md); the research is [`docs/design/20260816-effect-labels.md`](../design/20260816-effect-labels.md).

"Effect label", "effect summary" and "effect envelope" are trapped compounds ([`CONTEXT.md`](../../CONTEXT.md)). Bare "effect" still names `Rigor::FlowContribution`'s flow-effect bundle.

## The discriminating property

Collection is **observational**. It records decisions the typer makes anyway and MUST NOT ask it to make more. Concretely, the collector MUST NOT:

- trigger an on-demand method walk that would not otherwise run;
- resolve a call the dispatcher declined;
- mutate a `Scope`, or write anything a later `type_of` could read back.

This is what makes the two settings of the switch interchangeable for `rigor check`: a per-file diagnostics result computed with collection on is valid with it off, and vice versa. The gate is a **byte-identical diagnostic stream** with the feature present and collection off, and again with collection on.

## Activation

Collection runs when, and only when, the loaded configuration carries an `effects:` block — **presence, not truthiness**; `effects: {}` and a bare `effects:` key both enable it. `rigor effects` enables it for its own run by loading the project's configuration and applying an implicit empty block when it has none (`Configuration#with_effects_enabled`).

Nothing else turns collection on. In particular an `%a{rigor:v1:effect …}` or `%a{pure}` annotation in a project's RBS MUST NOT: an annotation must not create a project-wide cost cliff. (The `:info` residual that surfaces such an annotation as unread is [#384](https://github.com/rigortype/rigor/issues/384).)

`Runner`, `WorkerSession` and `PoolCoordinator` each derive activation from the configuration they already hold, so no flag can drift between a worker and its parent.

### Cost when off

The recorder follows the `Analysis::DependencyRecorder` shape: a module-level activation count, so `Effects::Collector.active?` is a plain integer read rather than a `Thread.current` lookup, and a per-thread accumulator that isolates the recording itself.

There are three recording sites, and only one of them is on the per-dispatch hot path:

| Site | What it records | Guard |
| --- | --- | --- |
| `ExpressionTyper#call_type_for`, after the receiver type is computed | the receiver's class projection, whether it was `Dynamic`, and the `DynamicOrigin` cause behind it | `Collector.active?` — the integer read |
| `ExpressionTyper#unresolved_call_result` | that every dispatch tier declined | `Collector.active?` |
| `Runner#analyze_file_body` / `WorkerSession#analyze_body`, after a successful parse | the file's AST root | inside the recorder — a per-file site, where one `Thread.current` read is already nothing |

## Identity

Effect units are keyed by the existing symbol tables:

| Unit | Key |
| --- | --- |
| instance method | `Class#method` |
| singleton method (`def self.x`, a `class << self` body) | `Class.method` |
| `def` outside any class body | `<toplevel>#method` (`ScopeIndexer::TOP_LEVEL_DEF_KEY`) |
| `define_method(:literal) { … }` | `Class#literal`, the block as its body |
| `attr_reader` / `attr_accessor` reader | `Class#name`, synthesised ∅ |
| `attr_writer` / `attr_accessor` writer | `Class#name=`, synthesised `mutate.self` |

Reopenings **union**: every `def` of one key, in any file, joins into one summary. Runtime last-wins is unknowable at analysis time, so the union is the sound reading.

A `define_method` with a literal name is a discovery extension made in the effects scanner, not in `ScopeIndexer`: the def-node tables skip it, and nothing outside effects needs it yet.

## What a unit's scan records

The scan walks one method body. Two rules shape it:

- **Containment.** A block literal's origins always join the enclosing method's summary — whether the callee invokes the block now, later, or never — because an envelope is a contract about the method's *code*. The walk therefore descends into block literals and stops only at a nested `def` or at a `define_method` with a literal name, each of which is a unit of its own.
- **Observation.** Everything the scan knows about a receiver is what the typer recorded at that call node.

### Origins

Each bundle of labels is keyed by an **origin**: the pair of what coloured it and which source did the colouring, `:catalogue` or `:construct`. Origins are **line-free**, so a summary is stable under a line move and a snapshot diff shows a change of behaviour rather than of formatting. Call sites are kept per run for the report only, never in the summary.

Language constructs, by origin name:

| Construct | Origin | Labels |
| --- | --- | --- |
| `` `cmd` ``, `%x(cmd)` | `xstring` | `io.process` |
| `$g` read (excluding the frame-local specials `$~ $_ $& $` $' $+ $!`) | `gvar-read` | `global.read` |
| `$g = …` and its operator forms | `gvar-write` | `global.write` |
| `@@cv` read | `cvar-read` | `global.read` |
| `@@cv` write | `cvar-write` | `mutate.static` |
| `@iv` write in an instance-method body | `ivar-write` | `mutate.self` |
| `@iv` write in a singleton-method body | `ivar-write` | `mutate.static` |
| `alias` / `undef` in a body | `alias` / `undef` | `mutate.static` |
| `define_method` in a body | `define-method` | `mutate.static` |
| a mutating call, by receiver ownership | `receiver-mutation` | `mutate.self` / `mutate.instance` / `mutate.local` / `mutate.static` |
| an `attr_writer`'s synthesised body | `attr-writer` | `mutate.self` |

Catalogued origins are keyed by the callee key the row matched (`catalogue:Kernel#puts`, `catalogue:Time.now`).

### Ownership

A mutating call is claimed only when the selector settles it: `[]=` and an attribute writer on any receiver, and the per-class mutator sets (`MutationWidening::ARRAY_MUTATORS` / `HASH_MUTATORS`, and String's) when the typer named the receiver's class. `<<` on an unnamed class is deliberately **not** claimed — it is `Integer`'s bit shift and `IO`'s write as readily as `Array`'s append.

The label then follows the receiver's ownership, which is a syntactic question:

| Receiver | Label |
| --- | --- |
| `self`, an `@ivar`, or an implicit receiver | `mutate.self` (`mutate.static` in singleton context) |
| a `@@cvar` | `mutate.static` |
| a parameter | `mutate.instance` |
| a local whose every assignment allocates and which never escapes the body | `mutate.local` |
| anything else | **nothing** — the `unknown-ownership` taint |

`mutate.local` requires the local to be freshly allocated (`[]`, `{}`, `""`, `+""`, `.new`, `.dup`, `.clone`, a lambda) and never to escape. The escape analysis is flow-insensitive and whole-body: a local that escapes anywhere disqualifies, even after the mutation. That is strictly more conservative than "escaped before the mutating call", which is the direction the false-positive budget runs ([ADR-5](../adr/5-robustness-principle.md)).

An unprovable ownership MUST taint rather than produce a proven bare `mutate`.

### Taints

| Cause | When the tracer records it |
| --- | --- |
| `dynamic-receiver` | the typer's receiver type was `Dynamic`; the detail is the `DynamicOrigin` cause name, when one was recorded |
| `dynamic-send` | `send` / `public_send` / `__send__` with a non-literal selector (a literal one is an ordinary edge) |
| `opaque-callable` | `.call` on a receiver that is neither a lambda literal nor the unit's own block parameter and whose class is unknown or `Proc` / `Method`; or a `&expr` block argument that is neither a symbol nor the unit's block parameter |
| `unresolved-self-call` | an implicit-self call for which **every** dispatch tier declined; the detail is the selector |
| `unknown-ownership` | a mutating call whose receiver ownership is not classifiable |
| `collector-error` | the scan of that unit raised |

`method-missing`, `plugin-attribution`, `template-not-analysed` and `budget` are in the enum and have no producer in this slice.

Taint never produces a finding. A non-exhaustive summary reads "these effects, and possibly more".

### Known bounds of this slice

- `super` is neither an edge nor a taint. Resolving it needs the ancestor *above* the enclosing class, which the propagator could supply; it is left out to keep the tracer thin.
- An implicit-self call the dispatcher resolves optimistically through the user-class ancestor fallback does **not** taint, even when the project defines no such method. That shape is exactly what `call.self-undefined-method` covers, and it is off by default on false-positive grounds ([ADR-24](../adr/24-self-method-call-resolution.md) slice 4).
- An uncatalogued call on a *known* receiver contributes nothing and does not taint. The per-class default postures that make the exhaustiveness bit meaningful over Ruby's whole core surface — value classes ∅, world-facing classes `io` — arrive with the hand-audited catalogue in [#380](https://github.com/rigortype/rigor/issues/380).
- Class bodies are not effect units. Their statements run at load time, which is a unit of its own that no slice models yet.

## The catalogue

`Rigor::Effects::Catalog` is a small in-code table keyed `Owner#method` / `Owner.method`, standing in for the hand-audited `data/effects/core.yml` of [#380](https://github.com/rigortype/rigor/issues/380). A row MAY be the empty label set, which is not the same as having no row: an explicit ∅ says the catalogue knows the call and knows it contributes nothing, which is what stops `Thread.new` from reading as unresolved while its block joins the enclosing method by containment.

The generated `data/builtins/ruby_core/*.yml` `purity:` facet is **not** an effect source. It answers fold-safety in the C-dispatch sense — `Random#rand` is `leaf`, `Array#push` is `leaf` — and reading it as effect freedom would be wrong in both directions (ADR-103 WD3).

## Per-file shape and merging

A file contributes a `FileCollection`: its units' direct summaries, the calls it recorded as unresolved edges, and the ancestry (`superclasses`, `includes`) the propagator needs. Every field is Marshal-clean — frozen Hashes of Strings, `LabelSet`s over frozen Arrays, and `Data` edges — because the fork pool marshals a worker's collections back with the file's diagnostics.

Merging is **associative and commutative** in every table: summaries join per key, edge lists union, ancestry merges. Folding a run's files in pool-completion order therefore yields exactly the table sequential analysis yields.

An ancestry name is recorded **as written** (`class Loud < Base` inside `module Tracer` names `Base`), so the collection carries the candidate list Ruby's own lexical lookup would try, most-qualified first, and the propagator picks the one the merged project defines.

## Propagation

Propagation runs in the post-pool aggregation slot of `Runner#assemble_run_diagnostics`, beside `conforms_to_diagnostics`, and only when collection ran. It has two steps.

**Edge resolution.** For a recorded `(receiver class, kind, selector)`:

1. resolve the definition through the receiver's own class, then its includes, then its superclass chain, recursively and cycle-guarded;
2. **join every project-known override** of the same selector in a project subclass of the receiver's class. Ruby has no `final`, and the analyzer already takes this closed-world posture for types (ADR-103 WD4).

The subclass index resolves each as-written superclass to a single parent — the most-qualified candidate the project defines — so two same-named classes in different namespaces cannot share overrides.

An edge that reaches no project definition is **dropped**, not tainted: most such calls are ordinary inherited ones the catalogue has no row for, and tainting them would make the bit carry no information.

**Fixpoint.** A round-robin worklist in sorted key order, to a true fixpoint:

- `proven(m) = direct(m) ∪ ⋃ proven(callee)`
- `exhaustive(m) = direct_exhaustive(m) ∧ ⋀ exhaustive(callee)`
- `causes(m) = direct_causes(m) ∪ ⋃ causes(callee)`

The lattice is finite (label sets over a closed vocabulary × one bit × a closed cause enum) and every step is monotone, so a recursive or mutually recursive cycle converges on its own. **No recursion cap is used or wanted here** — unlike the return-type walk's Kleene iteration, there is no widening to force.

Sorted iteration order is what makes a pooled run and a sequential run produce the same table rather than merely equivalent ones.

The result is a `Rigor::Effects::EffectTable` on the runner (`Runner#effect_table`), with the merged direct collections available separately (`Runner#effect_collection`). **It is not a diagnostic**: it never enters `rigor check`'s stream, and the run's exit code is identical whether or not it was computed ([ADR-102](../adr/102-unused-code-reachability-report.md)'s report-versus-diagnostic line).

## Failure isolation

The collector and the propagator are fail-soft at three levels, and none of them may alter or fail a check:

| Level | On an exception |
| --- | --- |
| one unit's scan | that method is recorded non-exhaustive with `collector-error`; its siblings are unaffected |
| one file's scan | the file contributes an empty collection marked `failed?`; other files are unaffected |
| propagation | the table is empty |

## Caching

Collection is not persisted in this slice. Because a cache-served run collects nothing, a run with collection on declines the ADR-45 whole-run **result** cache (`Runner#run_result_cacheable?`) — the same exclusion, for the same reason, that a `record_dependencies` run takes. The store still serves the RBS-environment and plugin-producer tiers.

The sidecar that lifts this — summaries stored beside `return_summaries`, under an effects cache identity of its own (the diagnostics identity plus the vocabulary version, the catalogue version and the `effects:` digest) — is [#382](https://github.com/rigortype/rigor/issues/382). Until it lands, the `effects:` block is deliberately **absent** from `Configuration#to_h`, so enabling the feature does not invalidate any existing project's caches.

## Parallelism

A collecting run is pinned to the fork backend when `fork` is available, for the same reason a `record_dependencies` run is: only the fork path marshals per-worker side tables back, and the Ractor messages carry no side-table channel. Without `fork` it degrades to sequential, which collects correctly through the runner's own `analyze_file`.
