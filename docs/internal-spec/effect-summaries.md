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
- An uncatalogued call on a receiver whose class the catalogue does not list contributes nothing and does not taint. A class the catalogue *does* list answers its posture — see § The catalogue below.
- Class bodies are not effect units. Their statements run at load time, which is a unit of its own that no slice models yet.

## The catalogue

`Rigor::Effects::Catalog` loads `data/effects/core.yml` — a hand-audited table of core and stdlib classes, memoised per process and inherited as-is across the fork pool. A missing or unreadable file degrades to an empty catalogue (fail-open, matching `Registry.load_file`); a file that is present but malformed raises, because that is a packaging bug rather than a choice.

**Rows are upper bounds.** An argument-blind row on a world-facing class MUST be the parent label: `IO#write` is `io`, not `io.fs.write`, because the channel is a socket as readily as a file. Precision returns only where the call's own arguments prove it.

Every row carries a one-line `why:`, and the loader rejects one that does not. The justification is the audit record: this file is data, and the reasoning that put a label on a row lives beside the row rather than in a commit message.

A row MAY be the empty label set, which is not the same as having no row: an explicit ∅ says the catalogue knows the call and knows it contributes nothing, which is what stops `Thread.new` from reading as unresolved while its block joins the enclosing method by containment.

### Postures

Ruby's core surface is far larger than any catalogue will finish, so a class carries a **posture** — what an uncatalogued method of it contributes — named from the file's own `defaults:` table. Three tiers matter:

| Class | Reading of an uncatalogued method |
| --- | --- |
| listed, `posture: value` | ∅ |
| listed, any world-facing posture (`world` → `io`, and the narrower `fs` / `net` / `http` / `ipc` / `process` / `signal` / `global` / `nondet` / the three standard streams) | that posture's labels |
| **not listed at all** | nothing, and no taint — the reading for every project and gem class |

The posture set is wider than "value ∅ / world `io`" because `io` is not an upper bound of `nondet.random`: a class whose unlisted methods are non-deterministic gets a `nondet` default rather than a wrong `io` one. A class with a genuinely mixed surface (`Time`, `Pathname`, `Random`, `Logger`) is `value` with its world-facing rows spelt out, because a blanket `io` over its path algebra and accessors would be a wrong label, and a wrong label is worse than a missing one ([ADR-5](../adr/5-robustness-principle.md)).

Two refinements keep a posture from putting a **wrong** label on an ordinary call:

- a **universal selector list** — the `Object`-level names that exist on every receiver and touch nothing (`class`, `respond_to?`, `frozen?`, `inspect`, `to_s`, `hash`, `tap`, …) — is consulted after a class's own rows and before its posture, so `socket.class` is ∅ rather than `io.net`. A class's own row still wins over the list.
- a class MAY carry `singleton_posture:` when its two sides differ. `Kernel` is the case: its instance side is the process boundary, but `Kernel.x` is the `module_function` copy and what is actually called that way is the pure conversion family (`Kernel.Float`), so its singleton side is `value`.

A posture MUST NOT answer in three places, each of which would swallow a more specific reading the tracer already had:

- an **implicit-self** (or `self.`) call. Every unqualified call in a project body spells `Kernel#name`, so the `world` default would colour the whole world.
- a **`Dynamic` receiver**. The class the typer projected to is a guess there, and `dynamic-receiver` is the truthful answer.
- **`send` / `public_send` / `__send__` / `call`**, whose own taints (`dynamic-send`, `opaque-callable`) are the more specific reading of the same site. An explicit ROW still wins, so `Fiddle::Function#call` is `ffi`.

### Rows, postures and the project edge

A **row** is authoritative about what its call does; `mutates: receiver` is how it asks for the ownership judgment (§ Ownership) on top. So `ENV["k"] = v` is `global.write` and deliberately not a receiver mutation, while `Time#localtime` is both. A **posture** states nothing about the selector, so the uncatalogued path's own mutation rule applies to it unchanged.

Two claimed shapes still contribute their **project edge**, and the summary is then the union of the catalogue's reading and the project definition's:

- an implicit-self call, because an unqualified name resolves against self's ancestry first and a project method of the same name wins at run time. `Kernel#format` is a real row and Redmine's `CustomField#format` is a real method; only the union reads both.
- a posture answer, because a core class the project reopens must still propagate its override's summary.

An edge that reaches no project definition is dropped by the propagator, so keeping one costs nothing and dropping one costs a callee.

### Mutator sets, by reference

A value class names `mutators: array | hash | string` and the loader resolves it to `MutationWidening::ARRAY_MUTATORS` / `HASH_MUTATORS` / `MutationClassifier::STRING_MUTATORS`. The data file MUST NOT re-spell a selector list; a spec pins the agreement in both directions.

### Argument-dependent narrowing

A row's `narrow:` names a handler in `Rigor::Effects::Narrowing`, which reads **the call's own argument literals and nothing else**. No dataflow: the scan is observational, and a narrowing that consulted inference would make the catalogue's answer a function of analysis quality rather than of the source in front of it. Every handler is total and degrades to the row's own `effects:` — its unnarrowed upper bound — rather than guessing.

| Handler | Reads | Rows |
| --- | --- | --- |
| `kernel_open` | a literal leading `\|` is a subprocess; otherwise a path whose mode literal decides the direction | `Kernel#open` |
| `file_open` | the mode literal at argument 1, or `mode:` | `File.open` |
| `pathname_open` | the same one argument to the left, the receiver being the path | `Pathname#open` |
| `time_new` | positional arity: none is `Time.now`, any constructs | `Time.new` |
| `random_new` | positional arity: a seed makes the generator reproducible | `Random.new` |
| `uri_open` | the scheme literal: `http(s)://`, `file://` or a bare path | `URI.open`, `OpenURI.open_uri` |

Two readings the handlers fix. An **absent** mode argument is not an unknown one — Ruby's default is `"r"`, so it reads, where a computed mode or an integer flag answers the subsystem parent. And the target tests read the **literal head** of an interpolated string, because `open("|#{cmd}")` writes the part that decides the subsystem even when the rest is computed.

### What is deliberately not a row

`eval` / `instance_eval` / `class_eval` / `module_eval` with a positional argument, and a bare `binding`, taint `opaque-callable`: there is no upper bound to state for code the analyzer will not read. The block forms are containment and do not taint.

### The `purity:` prohibition

The generated `data/builtins/ruby_core/*.yml` `purity:` facet is **not** an effect source, and the loader MUST NOT open `data/builtins` at all. That facet answers fold-safety in the C-dispatch sense — `Random#rand` is `leaf`, `Array#push` is `leaf` — and reading it as effect freedom would be wrong in both directions (ADR-103 WD3). What the existing catalogues DO contribute is evidence, cited per row: the `c_effects: mutate` / `block` markers, the hand-audited `mutating_selectors:` blocklists in `lib/rigor/inference/builtins/*_catalog.rb`, `MethodCatalog::NON_REPRODUCIBLE_SELECTORS`, `MutationWidening`'s mutator sets and `ClosureEscapeAnalyzer`'s escape tables.

## Per-file shape and merging

A file contributes a `FileCollection`: its units' direct summaries, the calls it recorded as unresolved edges, and the ancestry (`superclasses`, `includes`) the propagator needs. Every field is Marshal-clean — frozen Hashes of Strings, `LabelSet`s over frozen Arrays, and `Data` edges — because the fork pool marshals a worker's collections back with the file's diagnostics.

Merging is **associative and commutative** in every table: summaries join per key, edge lists union, ancestry merges. Folding a run's files in pool-completion order therefore yields exactly the table sequential analysis yields.

A run's collections MUST be folded in **one pass** (`FileCollection.merge_all`), not by a `reduce` over pairwise `#merge`. Each pairwise merge rebuilds and re-freezes the whole accumulated table, so a per-file fold costs O(files × methods) — which is what put collection at +50 % wall on mastodon and +230 % on gitlab before it was measured ([`docs/notes/20260817-effect-collection-perf.md`](../notes/20260817-effect-collection-perf.md)). This is a cost contract, not a semantic one: both spellings produce the same table.

An ancestry name is recorded **as written** (`class Loud < Base` inside `module Tracer` names `Base`), so the collection carries the candidate list Ruby's own lexical lookup would try, most-qualified first, and the propagator picks the one the merged project defines.

## Propagation

Propagation runs in the post-pool aggregation slot of `Runner#assemble_run_diagnostics`, beside `conforms_to_diagnostics`, and only when collection ran. It has two steps.

**Edge resolution.** For a recorded `(receiver class, kind, selector)`:

1. resolve the definition through the receiver's own class, then its includes, then its superclass chain, recursively and cycle-guarded;
2. **join every project-known override** of the same selector in a project subclass of the receiver's class. Ruby has no `final`, and the analyzer already takes this closed-world posture for types (ADR-103 WD4).

The subclass index resolves each as-written superclass to a single parent — the most-qualified candidate the project defines — so two same-named classes in different namespaces cannot share overrides.

An edge that reaches no project definition is **dropped**, not tainted: most such calls are ordinary inherited ones the catalogue has no row for, and tainting them would make the bit carry no information.

Edge resolution is memoised on `(receiver class, kind, selector)`, and the transitive subclass closure on the class name. Both are required, not incidental: one triple is asked for once per call site, and a Rails root class's subclass forest is otherwise re-walked thousands of times.

**Fixpoint.** A worklist in sorted key order, to a true fixpoint:

- `proven(m) = direct(m) ∪ ⋃ proven(callee)`
- `exhaustive(m) = direct_exhaustive(m) ∧ ⋀ exhaustive(callee)`
- `causes(m) = direct_causes(m) ∪ ⋃ causes(callee)`

The lattice is finite (label sets over a closed vocabulary × one bit × a closed cause enum) and every step is monotone, so a recursive or mutually recursive cycle converges on its own. **No recursion cap is used or wanted here** — unlike the return-type walk's Kleene iteration, there is no widening to force.

A key's closure moving can only move the closures of the methods that **call** it, so each pass re-visits exactly the callers of what changed in the previous one — never the whole table. Joining a lane along an edge MUST NOT allocate when it adds nothing, which is what makes a pass over a converged region free.

Sorted iteration order is what makes a pooled run and a sequential run produce the same table rather than merely equivalent ones. (The lattice is finite and every step monotone, so the least fixpoint is unique and visit order could not change it; the sorted pass makes the *work* reproducible too.)

The result is a `Rigor::Effects::EffectTable` on the runner (`Runner#effect_table`), with the merged direct collections available separately (`Runner#effect_collection`). **It is not a diagnostic**: it never enters `rigor check`'s stream, and the run's exit code is identical whether or not it was computed ([ADR-102](../adr/102-unused-code-reachability-report.md)'s report-versus-diagnostic line).

## The snapshot document

The committed effect snapshot is the primary validation mode ([ADR-103](../adr/103-effect-labels.md) WD7). Its label language is normative in [`effect-labels.md`](../type-specification/effect-labels.md); its file contract is here.

### Layout

The file is written in a **JSON-compatible YAML subset** — string keys, JSON scalars, flow sequences, no anchors, no tags, no timestamps — so `YAML.safe_load` of it round-trips through `JSON` unchanged and a sibling implementation reads it without a YAML resolver. It is rendered by a hand-rolled writer rather than `YAML.dump` precisely because that guarantee, the leading comment and the key order are all part of the contract.

```yaml
# .rigor-effects.yml — generated by `rigor effects update`. Commit it; review its diff.
schema: 1
rigor: "0.3.3"
vocabulary: 1
config_digest: "9ec82bfc…"
methods:
  "PaymentGateway#charge":
    effects: ["io.net.http", "telemetry"]
  "Reports::Nightly#perform":
    effects: ["io.db.read"]
    exhaustive: false
    unresolved: ["dynamic-send"]
reach:
  "OrdersController#create":
    effects: ["io.db.read", "io.net.http", "job.enqueue"]
```

Per row: `effects:` is the proven lane, `declared:` the `≤` lane (always empty until [#386](https://github.com/rigortype/rigor/issues/386)), `exhaustive:` the bit, and `unresolved:` why it is false. A field the reader can default is omitted — `declared:` when empty, `exhaustive:` when true, `unresolved:` when there is nothing to say.

`unresolved:` carries the **taint causes**, rendered `cause` or `cause(detail)`, not call names: the collector keeps causes, and for the causes that have a detail the detail already is the call name (`unresolved-self-call(save!)`).

### Direct and reach

| Table | Summary | Membership |
| --- | --- | --- |
| `methods:` | **direct** — the unit's own body, block literals and catalogued / attributed callees; never a project callee, which is an edge | every unit the run collected |
| `reach:` | **transitive** — the closure the propagator computed | every unit defined in a file matching `effects.snapshot.reach:` |

Direct is what keeps a diff attributable: an entry moves only when its own lines, the catalogue or an attribution moved. Reach is where a leaf change is *supposed* to fan out, and the fan-out is the information.

A `reach:` entry is either a file glob — anything carrying a path or glob character, matched project-relative through `File.fnmatch?` with `File::FNM_PATHNAME`, the `unused --entry-point` semantics — or the bare name of a preset registered on `Rigor::Effects::EntryPoints`. Presets are contributed by the plugin that models a framework; **none ships in this slice**, and an unknown name is a tier-2 configuration error rather than a glob that silently matches nothing. Because an entry-point glob selects a *file*, every unit written in it is an entry point.

### Omission

`--full` records everything. Otherwise a row is omitted when

- its summary is exhaustive and proven ⊆ `{mutate.local}` (`Summary#trivial?` for `methods:`, `EffectTable::Entry#trivial?` for `reach:`) — the reading of `%a{pure}`, which every envelope tolerates; or
- its direct summary is a **synthesised default**: every origin is a synthesised accessor construct (`construct:attr-writer` today; the `Struct` / `Data` accessors join it when discovery synthesises them). Such a row restates the `attr_accessor` line. A hand-written `def name=` keeps its row, because its origins are not the synthesised construct.

The file lists the interesting, so a method that *becomes* impure arrives as an added key.

### Header and determinism

The header carries `schema` (this document's shape), `rigor` (`Rigor::VERSION`), `vocabulary` (`Registry#vocabulary_version`) and `config_digest` — the SHA-256 of the canonicalised `effects:` block, keys sorted at every depth and rendered as JSON, so the digest does not depend on the order the block was written in. A mismatch on any of the four is a **regeneration event**: the record was written under different rules and the two sides are not comparable.

Output is deterministic by construction: keys and labels sorted, no timestamps, and every rendering derived from the sorted `EffectTable`. Two `update`s over one tree, and a pooled run against a sequential one, are byte-identical.

### Judgment

The record is **undischarged**. `effects.tolerated:` and the gate apply in `Effects::SnapshotDiff`, never while writing, so `update --no-tolerated-effects` and `update` write the same bytes and a policy change diffs the config rather than the record.

Event categories, per symbol and table: `label-added` / `label-removed`, `declared-added` / `declared-removed`, `materialised` (a declared label became proven — one event, never a removal plus an addition), `exhaustive-lost` / `exhaustive-gained`, `symbol-added` / `symbol-removed`, plus `regeneration` and `missing-snapshot`. A removal whose current side is non-exhaustive is **hedged**: "possibly more" cannot prove an absence. A symbol carrying nothing produces no event (it exists only under `--full`) but is still counted in the footer, so a rename balances as one addition and one removal.

The gate reads those categories. `symmetric` (default) fails on any event; `additions` fails only on `symbol-added`, `label-added`, `declared-added`, `exhaustive-lost`, `regeneration` and `missing-snapshot` — the last two under both gates, because an incomparable record is not something to ratchet against. An event is **tolerated** when `effects.tolerated:` admits every label it carries (a symbol event carries the symbol's whole set); a tolerated event is reported under its own heading and does not gate unless `--strict-tolerated`. `--no-tolerated-effects` judges as if the list were empty. An event carrying no label — an exhaustiveness transition, a regeneration — can never be tolerated.

`rigor effects explain` answers the reach half from the same graph: a breadth-first walk over `EffectTable::Entry#edges` to the first method whose *direct* summary proves the label, ending at that method's origin (`Rigor::Effects::PathFinder`). Shortest, so a reviewer gets the tightest explanation available. A `methods:` change has no path — the label came from the unit's own body — so what explains it is the origin itself.

The snapshot commands run the same analysis the report runs, and neither emits a diagnostic nor enters `rigor check`'s stream.

## Failure isolation

The collector and the propagator are fail-soft at three levels, and none of them may alter or fail a check:

| Level | On an exception |
| --- | --- |
| one unit's scan | that method is recorded non-exhaustive with `collector-error`; its siblings are unaffected |
| one file's scan | the file contributes an empty collection marked `failed?`; other files are unaffected |
| propagation | the table is empty |

## Caching

One cache, two identities, one extra slot (ADR-103 WD13). There is no second store: both existing stores already digest the whole resolved configuration, so a project that adds `effects:` invalidates nothing — the block is deliberately **absent** from `Configuration#to_h`, and that absence is what makes the two identities independent rather than a redundancy to be tidied away.

The **diagnostics identity** is the ordinary one. Collection is observational, so a diagnostics entry computed with collection on is valid for a run with it off and vice versa, and nothing in this section may invalidate, rewrite or reshape that entry.

The **effects identity** is the diagnostics identity plus the three inputs that change what a summary *means* without moving one analyzed byte: the vocabulary version (`Registry#vocabulary_version`), the catalogue identity (`Catalog#identity` — its schema and a content digest of `data/effects/core.yml`), and the digest of the `effects:` block. `Rigor::Effects::Identity` is the one place it is computed, in two spellings of the same three inputs: `.digest` (a hex string, for a store with no descriptor of its own) and `.descriptor` (the run's key descriptor composed with one `configs:` entry carrying that digest). `Snapshot.config_digest` — the snapshot header's `config_digest` — is the same method, so the committed record and the cache key can never disagree about which `effects:` block produced it.

The unit of persistence is the **per-file `FileCollection`**, never the propagated table. A leaf's summary reaches every caller, so a stored table would have to be invalidated by every file in the project; the fixpoint is instead re-run over the merged whole on every run, which is the cheap half and the half that makes per-file reuse sound.

Two slots carry it:

| Store | Slot | Keyed by |
| --- | --- | --- |
| ADR-45 whole-run cache | producer `analysis.run-effects`, one entry per run | `Effects::Identity.descriptor` — the `analysis.run-diagnostics` key descriptor plus the effects entry |
| ADR-46 incremental snapshot | `Payload#effect_collections` + `Payload#effects_identity` (`SCHEMA` 12) | the snapshot's own global fingerprint, then the identity compared on restore |

A run with collection **on** is no longer excluded from the whole-run result cache. It consults the effects slot first, because that is the slot that can force work: a hit adopts the collections and runs the fixpoint, a miss re-analyzes (collection is observational, so the only way to collect is to analyze) and writes the slot. Either way the diagnostics slot decides for itself — an effects miss whose diagnostics entry is warm serves the warm diagnostics, and the effects entry's validation uses the same post-run dependency descriptor, so exactly the file set that invalidates diagnostics invalidates summaries.

An entry whose effects slot is missing, differently identified, or corrupt is a miss **for effects consumers only**. A run with collection **off** never reads or writes the slot: `rigor check` is byte-identical, its cache key is unchanged, and the ADR-87 boot-slim probe still serves it from `analysis.run-diagnostics` without loading the engine.

Consequently `rigor effects` and the snapshot verbs go through the same cache `rigor check` does: after a `rigor check` under a configured `effects:` block, `rigor effects check` in the same job is a warm hit plus the fixpoint, and never re-collects.

An ADR-46 recheck re-collects only the changed closure and serves every other file's collection from the snapshot; the fixpoint runs over the merged whole, so a leaf edit moves the reach of a caller in a file the recheck never opened. A restored snapshot whose `effects_identity` differs from this run's — a vocabulary bump, a re-audited catalogue row, an `effects:` edit, or a snapshot written with collection off — declines reuse and takes a full baseline: a recheck re-collects only the closure, so a partial re-collection could not be closed into a whole-project fixpoint. That is the incremental spelling of "an effects miss recomputes effects", and it is never paid by a run with collection off.

Typing consumers (WD9) fork the identity as `BleedingEdge`-style features with their id in the analysis-cache key. Collection being on must never fork it.

## Parallelism

A collecting run is pinned to the fork backend when `fork` is available, for the same reason a `record_dependencies` run is: only the fork path marshals per-worker side tables back, and the Ractor messages carry no side-table channel. Without `fork` it degrades to sequential, which collects correctly through the runner's own `analyze_file`.
