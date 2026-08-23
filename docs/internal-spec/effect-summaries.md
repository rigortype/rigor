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

Each bundle of labels is keyed by an **origin**: the pair of what coloured it and which source did the colouring — `:catalogue` or `:construct` in the proven lane, `:attribution` or `:envelope` in the declared one. Origins are **line-free**, so a summary is stable under a line move and a snapshot diff shows a change of behaviour rather than of formatting. Call sites are kept per run for the report only, never in the summary.

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

### `super`

A `super` is a dispatch and contributes an **edge**, in every shape it takes — bare, `super()`, `super(args)`, and each of those inside a block or a rescue, both of which the containment walk descends into. The edge is the one thing the syntax settles about it: the enclosing unit's own class and selector, marked `super_call:`. Which definition sits above that class is a whole-project question, so it is resolved in § Propagation like any other edge and, unlike any other edge, taints when nothing answers.

`UnitScan#delegates_upward?` reads the same node for an unrelated question — whether a class that wrote a body for a selector has *replaced* the framework's implementation or wrapped it (§ Framework units) — and the two must not be conflated: that bit is about the class, the edge is about what the parent does.

### The receiver's class projection

The tracer records one receiver class per call site, projected from the type the typer computed: a `Nominal` / `Singleton` names itself, a `Tuple` is an `Array`, a `HashShape` a `Hash`, a `Constant` its value's class, and a `Dynamic` whatever its static facet projects to. A type that projects to nothing costs an edge; it never produces a wrong one.

A **union** projects to a class exactly when its non-`nil` arms all project to the same one. This is not a corner: [ADR-58](../adr/58-ivar-field-typing.md) contributes a declaration-sourced `nil` to every instance variable `initialize` does not write, so *every cross-method instance-variable read is a union*, as is every `find_by`-shaped return read through `&.`. Whether the `nil` arm means the call happens at all is `possible-nil-receiver`'s question and says nothing about what the call does when it does happen, which is the only question here.

Arms that disagree project to nothing, because the record has room for one receiver class and answering with either arm would state an effect no single execution need perform. Arms that *cannot be named* — a union carrying a `Dynamic` — are the same knowledge as a bare `Dynamic` receiver in a different shape, and MUST taint accordingly: a summary whose receiver was admittedly unknown may not read exhaustive.

### Taints

| Cause | When the tracer records it |
| --- | --- |
| `dynamic-receiver` | the typer's receiver type was `Dynamic`, **or a union one of whose arms is** (§ The receiver's class projection), and no envelope bounds the class its static facet named (§ The declared lane at call sites); the detail is the `DynamicOrigin` cause name, when one was recorded |
| `dynamic-send` | `send` / `public_send` / `__send__` with a non-literal selector (a literal one is an ordinary edge) |
| `opaque-callable` | `.call` on a receiver that is neither a lambda literal nor the unit's own block parameter and whose class is unknown or `Proc` / `Method`; or a `&expr` block argument that is neither a symbol nor the unit's block parameter |
| `unresolved-self-call` | an implicit-self call for which **every** dispatch tier declined, and whose selector the unit's own class carries no envelope for; the detail is the selector |
| `unresolved-super` | a `super` whose target the project's own ancestry does not define; the detail is the selector. Recorded by the **propagator**, not the tracer — only the merged ancestry can answer it (§ Propagation) |
| `unknown-ownership` | a mutating call whose receiver ownership is not classifiable |
| `collector-error` | the scan of that unit raised |

`method-missing`, `plugin-attribution`, `template-not-analysed` and `budget` are in the enum and have no producer in this slice.

Taint never produces a finding. A non-exhaustive summary reads "these effects, and possibly more".

### Known bounds of this slice

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
| `sql_verb` | the SQL statement's leading verb literal: `SELECT` reads, `INSERT` / `UPDATE` / DDL writes, `BEGIN` / `COMMIT` is a transaction | plugin rows for `connection.execute` / `exec_query` / `select_all` (#387) |

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

A **`super` edge** is resolved by the same walk with two differences, and each is load-bearing:

1. the walk starts *above* the enclosing class — its includes, then its superclass chain, with the class itself excluded, because a method never `super`s into itself. The includes are consulted for an instance-side `super` only: `include M` puts `M#m` where `super` looks, while `M.m` is a singleton method `include` never contributes;
2. **no closed-world override join.** `super` in `C#m` dispatches into `C`'s ancestors, and a subclass of `C` is never among them however the receiver was constructed, so joining `D#m` would put a proven label on `C#m` that no execution of `C#m` can produce. Ruby's lack of `final` is the argument for the join at an ordinary call site and says nothing here.

And a `super` edge that resolves to nothing **taints** `unresolved-super` where an ordinary one is dropped. The parent is then in a gem, in Ruby's core, or in a module prepended at run time: the call is not merely unresolved but unread, and a row that stayed exhaustive would assert a completeness it has not earned. The taint is applied to the fixpoint's seed rather than to the direct summary, so it reaches this method's callers exactly as a collected cause does — a snapshot's `methods:` table records direct summaries and does not show it; `reach:`, the report and the judgment read the closure and do.

Edge resolution is memoised on `(receiver class, kind, selector, super?)`, and the transitive subclass closure on the class name. Both are required, not incidental: one tuple is asked for once per call site, and a Rails root class's subclass forest is otherwise re-walked thousands of times.

**Fixpoint.** A worklist in sorted key order, to a true fixpoint:

- `proven(m) = direct(m) ∪ ⋃ proven(callee)`
- `undischarged(m) = undischarged_direct(m) ∪ ⋃ undischarged(callee)`
- `declared(m) = declared_direct(m) ∪ ⋃ declared(callee)`
- `exhaustive(m) = direct_exhaustive(m) ∧ ⋀ exhaustive(callee)`
- `causes(m) = direct_causes(m) ∪ ⋃ causes(callee)`

`undischarged_direct(m)` is the join of the direct summary's origin bundles that `effects.tolerated:` does **not** discharge (§ Discharge by policy). Carrying it as a second lane of the same fixpoint is what makes per-origin discharge cost nothing structurally: an origin belongs to exactly one unit's direct summary, so the transitive union of surviving bundles is the closure of the seeded ones, and no method ever has to materialise a set of transitive origins. With no `tolerated:` list the two lanes are seeded identically and the second costs one allocation-free join per edge visit.

The **declared lane is a lane of this fixpoint, not a per-method fact** ([`effect-labels.md`](../type-specification/effect-labels.md) § Effect summaries): it travels edges exactly as the proven one does, so a controller two hops above an attributed gem call reads the claim rather than only the taint that call left behind. It is joined into itself and never into `proven` — that separation is why a claim can never produce a finding, and it is a property of the fixpoint rather than of any consumer's care.

Every lane is a `LabelSet` join, which returns the receiver untouched when the source adds nothing, so a converged region costs a comparison per lane and no allocation.

The lattice is finite (label sets over a closed vocabulary × one bit × a closed cause enum) and every step is monotone, so a recursive or mutually recursive cycle converges on its own. **No recursion cap is used or wanted here** — unlike the return-type walk's Kleene iteration, there is no widening to force.

A key's closure moving can only move the closures of the methods that **call** it, so each pass re-visits exactly the callers of what changed in the previous one — never the whole table. Joining a lane along an edge MUST NOT allocate when it adds nothing, which is what makes a pass over a converged region free.

Sorted iteration order is what makes a pooled run and a sequential run produce the same table rather than merely equivalent ones. (The lattice is finite and every step monotone, so the least fixpoint is unique and visit order could not change it; the sorted pass makes the *work* reproducible too.)

The lanes on the table are **raw**. The rendering rule — a declared label the same row's proven set already admits is dropped, because the proven lane says strictly more — is applied where output is produced (`EffectTable::Entry#rendered_declared`, `Snapshot.entry_for`) and never to the table, since a further join has to see what was actually declared.

The result is a `Rigor::Effects::EffectTable` on the runner (`Runner#effect_table`), with the merged direct collections available separately (`Runner#effect_collection`). **It is not a diagnostic**: it never enters `rigor check`'s stream, and the run's exit code is identical whether or not it was computed ([ADR-102](../adr/102-unused-code-reachability-report.md)'s report-versus-diagnostic line).

## Envelopes: reading and checking

The label language of an envelope, and what the bound means, are normative in [`effect-labels.md`](../type-specification/effect-labels.md) § Effect envelopes. What is analyzer-internal is *where* the envelopes come from and *when* the check runs.

### The reader parses, it does not read the built environment

`RbsExtended::EnvelopeScanner` parses the project's own signature sources directly — every `.rbs` under the configured `signature_paths:` (or the `sig/` default), plus the loader's `virtual_rbs` entries, which is how rbs-inline's `# @rbs %a{…}` comments and a plugin's `source_rbs` synthesis arrive. It does **not** walk `RbsLoader`'s built environment, which is the obvious route and the one `ConformanceChecker` takes.

Two reasons, and both are binding:

- **The env cache destroys locations.** `Cache::RbsEnvironmentMarshalPatch` dumps every `RBS::Location` to a zero-range `<cached>` sentinel, so a warm run cannot say which file a declaration came from, let alone which line. The diagnostic has to name where the bound was written, and a check that silently stopped firing on the second run of the day would be worse than one that never fired.
- **It enforces the trust rule structurally.** ADR-103 WD6 makes project-authored envelopes the checked stratum. Reading only the project's own sources means a `%a{pure}` in rbs core or in a gem's shipped RBS cannot bound a project method that happens to share its key — no path filter to get wrong.

The cost is one parse of a tree the run already globs, paid only when `effects.check` is on.

**A synthesized buffer is re-anchored where the envelope is built, not where it is rendered.** A `virtual:rbs-inline:…rb` buffer is `RBS::Inline::Writer`'s output — a fresh document, with the bodies gone and every annotation re-emitted above the *signature* it belongs to — so its line numbers describe something nobody has, while the buffer name still says `.rb`. `Effects::InlineAnchor` maps one back onto the Ruby source, and `RbsExtended.render_annotation_location` applies it before the `path:line` string ever reaches an `Envelope`. Correcting the value at construction is what makes every consumer agree — the two check diagnostics, `effect.unknown-label`, `rigor explain`, the JSON formatter, LSP hover — instead of each learning the mapping and drifting ([#432](https://github.com/rigortype/rigor/issues/432)).

There is no line table to consult: upstream's writer keeps no mapping, and the synthesized text is what the RBS parser saw. What the two documents share is the annotation's own spelling, which reaches the buffer verbatim, and their order, because members are emitted in source order — so the k-th `%a{pure}` of the buffer is the k-th `%a{pure}` of the `.rb`. Matching on that ordinal is what a plain text search cannot do: a file with several identically-bounded methods would point all of them at the first one, which is the same class of wrong answer as the synthesized line. Two filters make the lists comparable — in the buffer only a line that *is* the annotation counts, because the writer also echoes the author's `# @rbs %a{…}` comment above it, and in the `.rb` only a comment line counts, so a `%a{…}` inside a string is never mistaken for a declaration. Every step degrades to the buffer line: an unreadable `.rb`, an unmatched spelling, or a future writer that stops preserving order costs a position, never an exception on a run that had a finding to report.

The reader is fail-soft at every level: an unparseable signature contributes no envelope (the loader already quarantines it and reports `rbs.coverage.quarantined-signature`), a malformed payload and a `pure`/`effect` contradiction are recorded on a `RbsExtended::Reporter` the scan owns, and an unrecognised label rides out on `Effects::Envelope#unknown_labels` — with the tag's full token list beside it on `#declared_labels`, which is what lets the diagnostic ask whether the list as a whole was written in this vocabulary. A malformed payload and an unrecognised label are different conditions with different handling and must not be merged: the first violated the grammar, the second obeyed it.

### Unknown labels and the residual

Two `:info` diagnostics read the seams the envelope reader leaves. Both are computed where they are because of the same cache rule as the envelope check, and each is gated to the run the OTHER one cannot happen in.

**`effect.unknown-label`** rides the envelope pass, its `effects.check` gate and its single walk of the project's signatures. Grouping it with enforcement is the point: it reports that a declaration STOPPED enforcing, so the switch that turns enforcement on is the right switch for the diagnostic that keeps enforcement honest.

- `Effects::LabelIntent.evident?` is the FP gate — the four signals of [`effect-labels.md`](../type-specification/effect-labels.md) § Unknown labels. It is a pure predicate over `(token, registry, siblings)`, so the config-side and declaration-side producers cannot drift apart.
- `Effects::UnknownLabelReport` renders; `Effects::UnknownLabelCheck` walks. The check answers value objects, never diagnostics and never the filesystem, and takes the `subject` / `consequence` phrasing from its caller — which is what lets the four `.rigor.yml` label surfaces (`tolerated:`, `labels:`, `envelopes[].effect`, `attribution:` values) each name the place a reader has to edit, through one walker.
- Findings are deduplicated by **where they were written** (`[location, spelling, token]`), not by the method key they bound: a `def self?.x` member declares two keys off one annotation, and there is one typo to fix.
- Positioning is the declaration, and `Runner::DeclarationPosition` only splits the `Envelope`'s `location` into `[path, line]`: the re-anchoring already happened in the reader (§ The reader parses…), so `.rbs` and rbs-inline arrive equally usable. It used to happen here too, and being downstream of the value is what made it wrong — with only a spelling to go on it took the first `%a{…}` in the file, so two identically-bounded methods reported one line. A config value has no location at all and lands at `.rigor.yml:1:1`, the `rbs.coverage.quarantined-signature` precedent.
- Suppression comments are read only out of `.rb` files. Parsing an `.rbs` or a `.rigor.yml` as Ruby to look for a `# rigor:disable` would be a lie dressed as a feature; those positions are suppressible through `disable:` and the baseline.

**`effect.annotations-unchecked`** is `Runner::EffectAnnotationResidualPass`, and its gate is the exact complement — no `effects:` block at all — so exactly one of the two passes can ever produce anything. It runs on the surface that must stay free, which fixes its budget:

- It reuses `Effects::SignatureSources`, the same stratum rule the envelope check uses, so the residual can never disagree with the check about what counts as the project's own signatures.
- Detection is `SignatureSources::ANNOTATION_HINT` line by line — a routing regex over the `.rbs` text, no RBS parse and no analysis. A project with no signature tree costs a `Dir.glob` that matches nothing.
- It takes the virtual RBS the run **already** resolved and never builds an environment. An environment build on the effects-off path is a cost the project did not ask for. What "already resolved" means is the whole of issue #441: `Runner#@run_environment` is assigned only by the ADR-45 result-cacheable path, so for three releases a `--no-cache`, `--workers N` or `--incremental` run reported a `.rbs` annotation and stayed silent about the identical one written as an rbs-inline comment, while a default run reported both — the lane decided, not the annotation. Every analysis path now carries the stratum out as `RunSnapshots#effect_annotation_carrier`, reduced by `SignatureSources.annotated_carrier` to at most ONE synthesized buffer (all a one-`:info`-per-run pass can spend) and skipped entirely when collection is on, where `EffectEnvelopePass` reads the loader directly. The runner prefers `@run_environment` and falls back to the snapshot, so the cacheable path is byte-identical.
- What remains unreported is a run that analyses **no file**: a warm `--incremental` null recheck, and the engine-free `RunCacheProbe` hit — which an rbs-inline project cannot reach anyway, because virtual RBS is exactly what makes its probe key miss. Those have no environment to take the stratum from, and building one for an `:info` is the cost WD13 refused. The `.rbs` stratum is a glob and survives either way. Under-reporting an advisory `:info` is the fail-quiet direction, and nothing else depends on this pass. Both cache identities key on `Rigor::VERSION`, so the first run after any upgrade is a cold analysing one — which is what makes this pass usable as a migration notice.
- It is positioned at the first annotation, not at `.rigor.yml`: the fix is a config edit, but the inert thing is what the author wrote. When that annotation came from a synthesized buffer it goes through the same `Effects::InlineAnchor` the reader uses, so the advisory and the check can never name two different lines for one annotation.

### Envelopes written in `.rigor.yml`

`effects.envelopes:` is the second envelope stratum — the same `Effects::Envelope` value, reached without an annotation ([`effect-labels.md`](../type-specification/effect-labels.md) § Envelopes by convention). `Effects::ConfigEnvelopes` owns it, in two steps that are kept apart on purpose:

- **`.build`** resolves each entry's `effect:` list against the run's registry once, producing the entry's bound — `LabelSet::TOP` when any member is unrecognised, which is the same fail-open degradation an annotation takes — and the `unknown_labels` the `effect.unknown-label` producer reads.
- **`.for_classes`** decides which classes each entry selects, over the class names the effect table actually carries. A `namespace:` glob matches the fully-qualified name segment by segment; a `match:` glob matches any file that defines one of the class's methods, from `Runner#effect_sources`, relativised against the project root and compared with `File.fnmatch?` + `FNM_PATHNAME` — the `unused --entry-point` and `effects.snapshot.reach:` semantics, spelled once. The **first** entry that selects a class wins.

The result is a class-keyed envelope map, and `Effects::EnvelopeCheck.distribute` applies the three strata in one place: a per-method annotation wins over a class-level annotation, which wins over a configured entry. A configured envelope is the only one whose `#rebind` keeps its own `source`, because distribution is what it *is* — the fact worth naming in the message is the stanza (`.rigor.yml effects.envelopes[2]`), not the class it was distributed to.

The configured stratum does **not** depend on the RBS walk. A project with no signature tree gets its conventions judged: the annotation scan is skipped when there is no loader or it finds nothing, and the pass proceeds on the config entries alone. That is the surface's whole point — one stanza checks an architectural layer on day one, before any RBS exists.

### Discharge by policy

`effects.tolerated:` is applied by `Effects::Discharge`, at judgment time and nowhere else. The rule is per origin: **a bundle is discharged when any of its labels is tolerated**, because an origin is one callee or one construct and tolerating what it was *for* frees the transport it came with. Two consumers, one policy object:

- the **envelope check**, through the propagator's `undischarged` lane above. `EnvelopeCheck.run(apply_tolerated: false)` reads `proven` instead, which is `--no-tolerated-effects`.
- the **snapshot diff**, through `Snapshot.undischarged_index` — `{table => {symbol => [label]}}` for the current side, built beside the snapshot and never stored in it. An *added* label is then tolerated exactly when every origin introducing it is discharged; a *removal* has no current-side origin left to consult and stays judged by label. Without the index (a caller with no table) both fall back to the label reading.

The record on disk stays undischarged in both directions, and the collector attributes undischarged labels: policy is a lens over facts, never a filter on them.

### The declared lane at call sites: `EnvelopeIndex`

`Effects::EnvelopeIndex` answers the other question about an envelope. `EnvelopeScanner` and `EnvelopeCheck` ask "what bounds THIS method's body?", and answer it from the project's own sources alone, because that is the stratum a contract can be checked against. The index asks "what does the thing I am calling promise?" ([`effect-labels.md`](../type-specification/effect-labels.md) § The declared lane at call sites), and so reads one stratum more.

**Where the import happens.** In `Effects::UnitScan#import_envelope`, beside `#attribute` and on the same `(owner, selector)` the catalogue is looked up under — with one difference, which is the whole reason the method exists: a receiver-less call is spelled `Kernel#name` for the catalogue, and the envelope carrier for it is the enclosing unit's own class, so the scan is handed `owner_class:`. What it produces is a bundle in `Summary#declared_bundles` under an `Origin` of source `:envelope` named for the callee key. It runs beside the catalogue rather than instead of it and never claims the call.

**Exhaustive by envelope.** The returned envelope is also what tells the uncatalogued path the site is bounded rather than unknown, and that is the discharge of [ADR-103](../adr/103-effect-labels.md) WD6:

- a `Dynamic` receiver whose static facet still names a class contributes **no** `dynamic-receiver` taint when that class's method carries an envelope, and does contribute its project edge — so the closed world's proven lane still travels through the overrides the project defines, and only the unknowable remainder is answered by the bound;
- an implicit-self call every dispatch tier declined contributes no `unresolved-self-call` taint when the unit's own class carries an envelope for that selector, because the project has declared both the method and its bound.

A ⊤ envelope is not an envelope: `EnvelopeIndex#[]` returns nil for one, so a tag degraded by an unknown label can neither import nor discharge.

**The second envelope source, and why it is read-only.** The accepted stratum comes from `Environment::RbsLoader#each_annotated_method_member` — a walk of the **built** `RBS::Environment` yielding every method member that carries an annotation — through `RbsExtended::EnvelopeScanner.from_loader`. Three properties make it safe to read RBS the project did not write:

- It cannot reach a contract check. `EnvelopeCheck` and `LiskovCheck` are handed `EnvelopeScanner.scan`'s project-source tables and never this one, so the exclusion is structural rather than a filter to get wrong.
- It carries no `location`, because the ADR-54 env cache dumps every `RBS::Location` to a `<cached>` sentinel. A diagnostic could not name where such a bound was written even if one wanted to — which is the same fact that made the project-side reader parse rather than walk the env, read from the other end.
- There is no body to check. A gem method is un-analysed by definition; WD6 trusts its declaration for the same reason ADR-1 already trusts its types.

The project's own signatures are in the built environment too, so they appear in the accepted table as well. That is harmless: the project strata are consulted first, and both discharge. Class-level annotations are deliberately not read from the environment — distribution needs "every method of the class discovery knows", which is a project fact.

The index is built **per process**, once, off the first environment the analysis resolves (`Runner#effect_envelope_index`, `WorkerSession#effect_envelope_index`), and carried on the collection window exactly as the attribution table is (`Collector.collect_for(path, attribution:, envelopes:)`). A worker derives it from the same configuration and the same signature content as the parent, so the two agree without a channel to keep in sync. It participates in the effects cache identity through the `effects:` digest and, for the RBS strata, through the signature files the diagnostics identity already covers.

### Liskov inclusion: `LiskovCheck`

`Effects::LiskovCheck` decides `effect.liskov-widened`, and it rides `EffectEnvelopePass`'s single resolution of the strata and single force of the discovery tables — the two contracts differ in *which* bound they hold a method to, not in where bounds come from or where a finding is positioned.

- The envelopes it resolves are `EnvelopeCheck.distribute`'s, over a base of the raw per-method annotations. The base matters for one shape: a base class whose method exists only in `.rbs` — an abstract `def find: (Integer) -> User` with no Ruby body — has no key in the effect table and therefore no distributed entry, and its bound is exactly the one an override inherits.
- The ancestry is `FileCollection#superclasses`, the collector's own as-written candidate lists, resolved here the way `Propagator::Index#build_descendants` resolves them: the most-qualified candidate the project defines wins, so `A::Base` and `B::Base` cannot share the bare spelling `Base`. Reading the same table as the closed-world override join is what stops the Liskov relation and the proven lane from disagreeing about who inherits from whom.
- Positions come from `EnvelopeCheck::Positions#for`, which is where "the Ruby `def`, falling back to the class's file" is spelled once for both rules.

### The plugin stratum: framework attribution and framework edges

**Status: normative as of #387.** A plugin that models a framework contributes three things the project's own source cannot supply, all through frozen manifest fields (`docs/internal-spec/plugin.md` § Effect contributions): **labels** (`effect_labels:`), which join the run's vocabulary through `Registry.for_configuration(configuration, plugin_facts:)`; **attributions** (`effect_attributions:`), which colour calls into the framework; and **edges** (`effect_edges:`), which are the calls the framework makes that no syntax at the call site contains.

The compiled form is `Effects::PluginFacts`, built once per process behind `configuration.effects_enabled?` and carried on the collection window (`Collector.collect_for(path, plugin_facts:)`) exactly as the attribution table and the envelope index are, and for the same reason: a fork-pool worker MUST scan under the same tables the parent does. `Plugin::Registry#effect_contributions` is lazy, because a plugin MAY derive its rows from project facts — rigor-activejob reads `config.active_job.queue_adapter` through its `IoBoundary` — and a run with collection off must not pay that read.

#### Attribution

Consulted in `UnitScan#attribute_plugin`, beside the catalogue and beside `effects.attribution:`, on the same call. Three receiver shapes are tried, nearest-syntax first, and **every** shape is tried rather than the first that applies: a class name matched through the project's own superclass chain (`ActiveRecord::Base#save` reaching `user.save` on a `User < ApplicationRecord < ActiveRecord::Base`), a receiver path matched as written (`Rails.cache` + `read`), a self path scoped by `within:` (`self.session` + `[]=` inside a controller), and a `on_result:` row matched on the class that produced the receiver (`UserMailer.welcome(u).deliver_now`). The ancestry walked is the cross-file pre-pass's `discovered_superclasses`, capped and cycle-guarded; the RBS ancestor chain is deliberately not consulted.

The labels land in `Summary#declared_bundles` under an `Origin` of source `:plugin`. Whether the site is **tainted** is what separates the two authorities:

| Contributor | Taint | Reading |
| --- | --- | --- |
| first-party bundled plugin, `discharge: true` | none | "this is what it does" — the accepted-signature standing of ADR-103 WD6 |
| anyone else | `plugin-attribution` | "declared this, and possibly more" — identical to `effects.attribution:` |

A discharging row additionally **bounds the site**, exactly as an imported envelope does: it suppresses the `dynamic-receiver` taint (a Rails app with no Rails RBS types `Rails` as `Dynamic`, and a taint no annotation could ever clear is noise), the `unresolved-self-call` taint (an implicit-self `render` rightly does not resolve — the definition is in Action Pack), and the ownership judgment on a receiver mutation (`session[:user_id] = id` writes an object nothing types, and the row's `mutate` is both more precise than `unknown-ownership` and already trusted). A row MAY still carry an explicit `taint:` of `template-not-analysed` or `opaque-callable`, which states the one thing the framework model genuinely cannot see.

#### Edges

`effect_edges:` names a **closed engine-side strategy enum**; the plugin supplies only the base class. The strategies materialise as **synthetic effect units on the framework class itself** (`Effects::FrameworkUnits`), harvested by the scanner from the class body during the same walk:

| Strategy | Synthesised on a project class whose ancestry reaches the base |
| --- | --- |
| `:activerecord_callbacks` | `Klass#save` / `#save!` / `#update` / `#touch` / `.create` / `.create!` edged to the class body's `before_save :sym`, `validate :sym`, `after_commit :sym`, …; `Klass#destroy` to the destroy callbacks; `Klass#valid?` to the validation ones. `validates … uniqueness: true` adds an `io.db.read` bundle to the same units. A trigger with no callbacks and no uniqueness validator is not synthesised. |
| `:perform_now` | `Klass.perform_now` edged to `Klass#perform`. |
| `:mailer_body` | `Klass.<action>` edged to `Klass#<action>`, one per instance method the class defines. |

Synthesising on the class rather than at the call site is what makes this work at all: the call site is in another file, and a per-file collection window sees one file. The propagator then resolves an ordinary `(User, :instance, "save")` edge to the synthetic unit through the same ancestry and closed-world override join every other edge takes, so a subclass picks up its own callbacks for free and a project that defines `User#save` itself joins with the synthetic unit.

A synthesised unit stands for the **whole** of the selector, not for the callbacks alone, so it MUST also carry the loaded plugins' own attribution row for that `(class, singleton, selector)` — the same `class_row` lookup a call site performs, with the same origin (`plugin:ActiveRecord::Base#save`), the same `taint:`, and the same `plugin-attribution` cause when the contributing plugin does not discharge. A row carrying a `narrow:` is skipped: narrowing reads an argument at a call site, and a synthesised unit has none. Without this the write was attributed at every *call site* and never on the row that names the method, and `AuthSource#save: ≤ io.db.read` — "save does not write to the database" — was what a Rails reviewer read. This enriches units that the rule above already creates; it does **not** create new ones, because a `Klass#save` row for every model in the project is precisely the noise that rule exists to prevent.

The one exemption: when the class body itself defines the selector and that body never reaches `super`, the plugin's claim is dropped for that selector. Such a body has replaced the framework's implementation, and `def save = false` must keep reporting that it persists nothing. The exemption is per selector — the siblings the class did not override keep the claim — and a body that does reach `super` keeps it, since an override that delegates upward still runs whatever the superclass does. `Effects::UnitScan#delegates_upward?` is the bit, and it is the *only* thing this exemption reads: the edge the same `super` contributes (§ `super`) answers what the parent does, which is a different question from whether the framework's claim about the selector still holds.

The enum has **no `perform_later` → `perform`**, which is the mechanical enforcement of ADR-103 WD4's "attribution follows the code, not the clock". The one edge that looks like it — `target: :perform_now, method: :perform_later` — is emitted only by a plugin that has read the project's own `queue_adapter = :inline`, where Rails genuinely runs the job on the caller's stack.

#### Entry-point presets

`effect_entry_points:` names `effects.snapshot.reach:` presets, registered into `Effects::EntryPoints` when `PluginFacts` is compiled. Because presets are named by plugins and plugins load *from* the configuration being validated, `Configuration` validates only the SHAPE of a `reach:` entry; `Snapshot.expand_reach` performs the existence check and raises there.

### Attribution: the declared lane's second producer

`effects.attribution:` is consulted in `Effects::UnitScan`, on the same `(owner, selector)` the catalogue is looked up under — the owner the syntax names for a constant-path receiver, and the class the typer projected the receiver to otherwise. It runs **beside** the catalogue rather than instead of it and never claims the call: a catalogued row states what Ruby's own surface proves, an attribution states what the project claims about a body Rigor never read, and a call that is both honestly reads as both.

What it produces is a bundle in `Summary#declared_bundles` under an `Origin` of source `:attribution`, plus a `plugin-attribution` taint at the site. Never a proven label, never a discharged taint (ADR-103 WD6). Two consequences fall out and both are load-bearing: an envelope can never fire because of an attribution, and a method whose only colour is attributed reads "∅, and possibly more" rather than "clean". The claim then propagates, because `declared` is a lane of the fixpoint above: every caller that reaches the attributed call carries it.

The table is built once per run from the configuration and carried on the collection window (`Collector.collect_for(path, attribution:)`), so a fork-pool worker scans under exactly the claims the parent does. It participates in the effects cache identity through the `effects:` digest, so editing the table re-collects rather than reusing summaries coloured under the old one.

### Where the check runs

`Runner::EffectEnvelopePass`, in `#run_analysis`, **outside** `#compute_run_diagnostics` — deliberately, and not beside `conforms_to_diagnostics` where the other project-level streams sit.

The reason is the cache. `assemble_run_diagnostics`' result is what the ADR-45 whole-run diagnostics slot stores, and the `effects:` block is deliberately absent from that slot's identity (§ Caching) — which is what lets a project turn collection on without invalidating its check. An envelope finding written into that entry would therefore outlive the configuration that produced it: flipping `effects.check: false` would not move the key, and the warm entry would keep serving the finding. Running the pass over whatever table the run ended up with — warm or cold — is ADR-103 WD12's "recomputed every run, never stored", and it also means the warm path, which never assembles at all, still emits.

The pass is ordered so a project pays for what it uses: it reads the envelopes first and stops there when there are none, and only a project that declared one forces the cross-file discovery tables (`ensure_project_discovery`) that map a method key to its Ruby `def`, or merges the run's collections for the superclass table `effect.liskov-widened` reads. Positions come from `discovered_def_sources` / `discovered_singleton_def_sources`, falling back to `discovered_class_sources` for a synthesized accessor, which has no `def` of its own. Both contracts — a method against its own bound, and an override against the one it inherits — ride that single resolution.

Findings run through `CheckRules.filter_suppressed` per file before they leave the pass, with that file's comments and the project's `disable:` list, so `# rigor:disable effect.envelope-exceeded` on the `def` line behaves exactly as it does for a per-file rule. Everything downstream — severity resolution, the baseline, `--format json` — applies because the diagnostics join the ordinary stream before `apply_severity_profile`.

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

Per row: `effects:` is the proven lane, `declared:` the `≤` lane, `exhaustive:` the bit, and `unresolved:` why it is false. Both label lanes are read at **that table's** reading — `methods:` records the direct declared set, `reach:` the transitive one — and the rendering rule drops a declared label the row's own `effects:` already admits. A field the reader can default is omitted — `declared:` when empty, `exhaustive:` when true, `unresolved:` when there is nothing to say.

`unresolved:` carries the **taint causes**, rendered `cause` or `cause(detail)`, not call names: the collector keeps causes, and for the causes that have a detail the detail already is the call name (`unresolved-self-call(save!)`).

### Direct and reach

| Table | Summary | Membership |
| --- | --- | --- |
| `methods:` | **direct** — the unit's own body, block literals and catalogued / attributed callees; never a project callee, which is an edge | every unit the run collected |
| `reach:` | **transitive** — the closure the propagator computed, in both label lanes | every unit defined in a file matching `effects.snapshot.reach:` |

Direct is what keeps a diff attributable: an entry moves only when its own lines, the catalogue or an attribution moved. Reach is where a leaf change is *supposed* to fan out, and the fan-out is the information.

A `reach:` entry is either a file glob — anything carrying a path or glob character, matched project-relative through `File.fnmatch?` with `File::FNM_PATHNAME`, the `unused --entry-point` semantics — or the bare name of a preset registered on `Rigor::Effects::EntryPoints`. Presets are contributed by the plugin that models a framework; **none ships in this slice**, and an unknown name is a tier-2 configuration error rather than a glob that silently matches nothing. Because an entry-point glob selects a *file*, every unit written in it is an entry point.

### Omission

`--full` records everything. Otherwise a row is omitted when

- its summary is exhaustive, proven ⊆ `{mutate.local}` — the reading of `%a{pure}`, which every envelope tolerates — and its declared lane survives the rendering rule empty (`Summary#trivial?` for `methods:`, `EffectTable::Entry#trivial?` for `reach:`). A surviving `≤` bound makes the row non-trivial: `≤ io.db` is what a reviewer reads a diff for, and omitting the row would say "clean" about a method that claims otherwise; or
- it is **taint-only**: it carries no label in either lane, so the row says nothing but `exhaustive: false` and its `unresolved:` causes. That is a question `rigor effects` and `rigor effects explain` answer against the live graph, not a fact a reviewer ratchets a committed record against, and on a Rails application it is the majority of the table (2,021 of redmine's 3,581 `methods:` rows at the time of the decision — 660 KB down to 296 KB). An exhaustiveness transition stays visible for every row that carries a label or a declared bound; one whose labels all disappear reads as a removed symbol rather than an `exhaustive-lost` event, and still gates. A method that later proves a label arrives as an added symbol; or
- its direct summary is a **synthesised default**: every origin is a synthesised accessor construct (`construct:attr-writer` today; the `Struct` / `Data` accessors join it when discovery synthesises them). Such a row restates the `attr_accessor` line. A hand-written `def name=` keeps its row, because its origins are not the synthesised construct.

The file lists the interesting, so a method that *becomes* impure arrives as an added key.

### Header and determinism

The header carries `schema` (this document's shape), `rigor` (`Rigor::VERSION`), `vocabulary` (`Registry#vocabulary_version`) and `config_digest` — the SHA-256 of the canonicalised `effects:` block, keys sorted at every depth and rendered as JSON, so the digest does not depend on the order the block was written in. A mismatch on any of the four is a **regeneration event**: the record was written under different rules and the two sides are not comparable.

Output is deterministic by construction: keys and labels sorted, no timestamps, and every rendering derived from the sorted `EffectTable`. Two `update`s over one tree, and a pooled run against a sequential one, are byte-identical.

### Judgment

The record is **undischarged**. `effects.tolerated:` and the gate apply in `Effects::SnapshotDiff`, never while writing, so `update --no-tolerated-effects` and `update` write the same bytes and a policy change diffs the config rather than the record.

Event categories, per symbol and table: `label-added` / `label-removed`, `declared-added` / `declared-removed`, `materialised` (a declared label became proven — one event, never a removal plus an addition), `exhaustive-lost` / `exhaustive-gained`, `symbol-added` / `symbol-removed`, plus `regeneration` and `missing-snapshot`. A removal whose current side is non-exhaustive is **hedged**: "possibly more" cannot prove an absence. A symbol carrying nothing produces no event (it exists only under `--full`) but is still counted in the footer, so a rename balances as one addition and one removal.

The gate reads those categories. `symmetric` (default) fails on any event; `additions` fails only on `symbol-added`, `label-added`, `declared-added`, `exhaustive-lost`, `regeneration` and `missing-snapshot` — the last two under both gates, because an incomparable record is not something to ratchet against. An event is **tolerated** when the policy discharges every label it carries (a symbol event carries the symbol's whole set); a tolerated event is reported under its own heading and does not gate unless `--strict-tolerated`. `--no-tolerated-effects` judges as if the list were empty. An event carrying no label — an exhaustiveness transition, a regeneration — can never be tolerated. Additions are judged per origin when the caller supplies the current side's undischarged index (§ Discharge by policy); everything else is judged by label.

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

The **effects identity** is the diagnostics identity plus the four inputs that change what a summary *means* without moving one analyzed byte: the vocabulary version (`Registry#vocabulary_version`), the catalogue identity (`Catalog#identity` — its schema and a content digest of `data/effects/core.yml`), the digest of the `effects:` block, and the **plugin fact digest** (`PluginFacts#digest` — every compiled label, attribution, edge and preset with the plugin that contributed it, #387; a plugin upgrade that re-colours `perform_later` re-colours summaries the source never moved). `Rigor::Effects::Identity` is the one place it is computed, in two spellings of the same three inputs: `.digest` (a hex string, for a store with no descriptor of its own) and `.descriptor` (the run's key descriptor composed with one `configs:` entry carrying that digest). `Snapshot.config_digest` — the snapshot header's `config_digest` — is the same method, so the committed record and the cache key can never disagree about which `effects:` block produced it.

The unit of persistence is the **per-file `FileCollection`**, never the propagated table. A leaf's summary reaches every caller, so a stored table would have to be invalidated by every file in the project; the fixpoint is instead re-run over the merged whole on every run, which is the cheap half and the half that makes per-file reuse sound.

Two slots carry it:

| Store | Slot | Keyed by |
| --- | --- | --- |
| ADR-45 whole-run cache | producer `analysis.run-effects`, one entry per run | `Effects::Identity.descriptor` — the `analysis.run-diagnostics` key descriptor plus the effects entry |
| ADR-46 incremental snapshot | `Payload#effect_collections` + `Payload#effects_identity` (`SCHEMA` 12) | the snapshot's own global fingerprint, then the identity compared on restore |

A run with collection **on** is no longer excluded from the whole-run result cache. It consults the effects slot first, because that is the slot that can force work: a hit adopts the collections and runs the fixpoint, a miss re-analyzes (collection is observational, so the only way to collect is to analyze) and writes the slot. Either way the diagnostics slot decides for itself — an effects miss whose diagnostics entry is warm serves the warm diagnostics, and the effects entry's validation uses the same post-run dependency descriptor, so exactly the file set that invalidates diagnostics invalidates summaries.

An entry whose effects slot is missing, differently identified, or corrupt is a miss **for effects consumers only**. A run with collection **off** never reads or writes the slot: `rigor check` is byte-identical, its cache key is unchanged, and the ADR-87 boot-slim probe still serves it from `analysis.run-diagnostics` without loading the engine.

### The boot-slim probe and the two out-of-band passes

The envelope judgment and the annotations-unchecked residual are recomputed every run and never stored (§ *Where the pass runs*, and its mirror in `EffectAnnotationResidualPass`), so `analysis.run-diagnostics` is exactly the slot that does **not** carry them. `rigor check`'s ADR-87 WD4 probe serves that slot without loading the engine, which is the code that would have appended them — so for its first three releases it dropped every `effect.envelope-exceeded` a project could earn on every warm run, and only on a warm run (issue #428). Silence read as success, and the manual's recommended CI setup — cache `.rigor/cache` between builds — is precisely the configuration in which the check never ran after the first build.

A probe that serves a slot answers for what the slot omits, and the two passes get opposite answers because they were built to opposite budgets:

| Pass | On an engine-free hit | Why |
| --- | --- | --- |
| `effect.annotations-unchecked` | **reproduced** by the probe, with no loader | It is a glob and a regex over `signature_paths:` by construction. The dropped virtual-RBS stratum is that pass's own documented fail-quiet direction, and is the stratum a run with no environment never had. |
| `effect.envelope-exceeded` / `effect.liskov-widened` / `effect.unknown-label` | the probe **declines** the whole run | They read the propagated table and the cross-file discovery tables. Nothing engine-free can recompute them, and serving the slot without them is the false negative above. |

The decline is measured off the **declarations** — the four `effects:` policy lists, and whether the signature tree carries an `ANNOTATION_HINT` match at all — never off what they would judge to, because the judgment is the thing the probe cannot reach. Over-declining costs a fast lane for a run the full path still serves out of its two warm slots — measured on redmine (347 files, one `app/helpers/**/*.rb` stanza, 343 findings), a warm run goes 0.25 s → 0.93 s against 8 s cold — and under-declining is the bug. A project with `effects:` on and no declaration anywhere keeps the fast path unchanged, which is also the shape [#409](https://github.com/rigortype/rigor/issues/409)'s default-on flip lands in. Reproducing the residual costs the signature walk on every hit instead: unmeasurable at 200 `.rbs` files, about 40 ms at 2,000.

Consequently `rigor effects` and the snapshot verbs go through the same cache `rigor check` does: after a `rigor check` under a configured `effects:` block, `rigor effects check` in the same job is a warm hit plus the fixpoint, and never re-collects.

The `--incremental` snapshot's identity is deliberately **plugin-blind** (`IncrementalSession#current_effects_identity` omits `plugin_facts:`), because its two sides sit on opposite sides of the run: the restore asks before any plugin is loaded and the save after, so a sighted digest would never match a blind one and the reuse would be dead. The bound is that a plugin upgrade does not invalidate an `--incremental` snapshot's effect collections; the whole-run slot, which is the primary path, has no such hole, and `--incremental` is opt-in.

An ADR-46 recheck re-collects only the changed closure and serves every other file's collection from the snapshot; the fixpoint runs over the merged whole, so a leaf edit moves the reach of a caller in a file the recheck never opened. A restored snapshot whose `effects_identity` differs from this run's — a vocabulary bump, a re-audited catalogue row, an `effects:` edit, or a snapshot written with collection off — declines reuse and takes a full baseline: a recheck re-collects only the closure, so a partial re-collection could not be closed into a whole-project fixpoint. That is the incremental spelling of "an effects miss recomputes effects", and it is never paid by a run with collection off.

Typing consumers (WD9) fork the identity as `BleedingEdge`-style features with their id in the analysis-cache key. Collection being on must never fork it.

## Parallelism

A collecting run is pinned to the fork backend when `fork` is available, for the same reason a `record_dependencies` run is: only the fork path marshals per-worker side tables back, and the Ractor messages carry no side-table channel. Without `fork` it degrades to sequential, which collects correctly through the runner's own `analyze_file`.
