# Effect labels — an opt-in effect system for Rigor

**Status:** Draft (design under consideration, 2026-08-16). Nothing implemented. If ratified it
graduates into an ADR (rationale), a normative `docs/type-specification/effect-labels.md` (labels,
subsumption, envelopes, lanes) and an internal-spec section (summary collection, propagation,
diagnostics), plus a `CONTEXT.md` glossary entry. Until then nothing here binds.

**In one paragraph.** [Steins](https://github.com/rigortype/steins) infers a *second dimension*
beside types — hierarchical side-effect labels (`io.db`, `io.net.http`, `nondet.time`) propagated
over the call graph to a fixpoint, checked against author-declared upper bounds ("effect
envelopes") — and the same model is drafted as an opt-in extension of PHPStan's purity tags
(`@phpstan-impure io.db`). This note asks what the model looks like when the host language is
Ruby, and answers: **the model transfers unchanged; what changes is where effects originate, how
dispatch and blocks are handled, and — the interesting part — where a declaration is spelled.**
The Ruby-ish answer to the last question is *inference does the work, `%a{pure}` is the
ecosystem's existing purity spelling, and envelopes are attached by convention (namespace / path)
rather than per method*. Mandatory per-method annotation is a stated non-goal. On top of the
shared registry, a **framework vocabulary** (`rails.*`, § 11.2) names what Rails facilities *mean*
where their transport is adapter-dependent and statically unknowable.

Sources: Steins' [Why effects?](https://github.com/rigortype/steins/blob/master/docs/why-effects.md),
[effects.md](https://github.com/rigortype/steins/blob/master/docs/type-specification/effects.md),
[phpdoc-effects-interop.md](https://github.com/rigortype/steins/blob/master/docs/type-specification/phpdoc-effects-interop.md);
the PHPStan RFC draft
[20260812-issue-draft-effect-labels-spec.md](https://github.com/zonuexe/phpstan-notes/blob/master/generated-report/20260812-issue-draft-effect-labels-spec.md)
and its origin note
[20260703-effect-system-design.md](https://github.com/zonuexe/phpstan-notes/blob/master/generated-report/20260703-effect-system-design.md).

## 1. Why, in Ruby

The PHP motivation carries over verbatim: a controller can acquire a database, network or clock
dependency through three layers of services without any parameter or return type changing, and
tests still pass. Ruby adds two motivations of its own.

- **The engine already wants it.** `Rigor::Inference::StatementEvaluator` resets every narrowed
  ivar across an implicit-self call because "we cannot prove purity without an effect system"
  ([statement_evaluator.rb:1420](../../lib/rigor/inference/statement_evaluator.rb:1420)); the
  purity policy in [control-flow-analysis.md § Purity policy](../type-specification/control-flow-analysis.md)
  is impure-by-default with a spec'd-but-unimplemented `rigor:v1:pure`; the constant-folding
  tier gates on a hand-picked purity allow-list; the built-in mutation summaries the spec promises
  do not exist as a unified structure. Every one of those is a consumer of "what does this call
  do", and today each carries its own partial table.
- **Ruby's culture puts effects in conventions Rigor cannot see.** Bang/non-bang pairs
  (`sort`/`sort!`), `save` vs `save!`, "presenters and policies do not query", "value objects are
  frozen", "`Time.now` in a model is a code smell" — reviewers enforce these by eye. A label
  system makes them machine-checkable where the project chooses to declare them, and reportable
  everywhere else.

The rigortype organisation runs both analyzers, so a shared label vocabulary and shared diagnostic
identifiers are a goal in themselves: a policy written for a PHP service (`io.db` must not reach
presenters) should read the same against a Rails app.

## 2. Goals and non-goals

Goals:

- **Opt-in, inference-first.** Every method gets an *inferred* effect summary; nothing is
  checked unless the author declared a bound. Declaration is per method where wanted, but the
  primary attachment surfaces are coarser (§ 6).
- **Never a false positive from an unknown.** Diagnostics read only *proven* effects; unresolved
  dispatch taints exhaustiveness and produces no finding ([ADR-5](../adr/5-robustness-principle.md),
  AGENTS.md "false positives outrank worst-case static reading").
- **Pay for itself without annotations** — engine consumers (§ 8) and a review surface (§ 9.3)
  that need no declaration at all.
- **Vocabulary and identifiers aligned with Steins / the PHPStan RFC** unless Ruby genuinely
  differs.

Non-goals (verbatim from Steins' "What Steins is not", all still true here): no algebraic effects,
no `perform`/`handle`, no runtime mediation, no effect rows or effect variables, no compiler
optimisation. Ruby-specific non-goals: **no runtime DSL** (`Rigor.pure def …` would violate
[ADR-0](../adr/0-concept.md)'s "application code MUST NOT require Rigor-specific annotations or
DSLs"); no exception tracking (`raise` is not a label — the throw dimension stays out of scope as it
does in Steins and the RFC); no class-body / load-time effects in v1 (method bodies only).

## 3. Terms — a clash to settle first

"Effect" is already spent inside Rigor, and `CONTEXT.md` has no glossary entry for it:

| Existing term | Where | Meaning today |
| --- | --- | --- |
| **effect model** | [implementation-expectations.md](../internal-spec/implementation-expectations.md) § engine surface; handbook [appendix-type-theory § Effect systems](../handbook/appendix-type-theory.md) | engine-internal mutation / non-local-exit / closure-escape / invalidation facts, "not part of an authored signature" |
| **flow effect**, **flow-effect bundle** | [rbs-extended.md § Flow effects](../type-specification/rbs-extended.md), `Rigor::FlowContribution` | narrowing facts (predicate / assert) plus the mutation / invalidation / exceptional slots |
| **envelope** | `CONTEXT.md` (`Dynamic[T]` "believed within envelope `T`"), ADR-100 "FP envelope", dependency-source "implementation envelope" | three unrelated senses already |

Proposal: the new concepts are always the compounds **effect label**, **effect summary**, and
**effect envelope** (never bare "effect" or bare "envelope"), and the existing bundle keeps
**flow effect**. The handbook already reserves the space this note fills: "Surfacing effects to
the user (annotation grammar; pure-function marker …) is a future direction tracked in the spec
corpus" ([appendix-type-theory.md:1361-1373](../handbook/appendix-type-theory.md)). Registering
the three compounds as trapped terms in `CONTEXT.md` is the first mechanical step of any slice.

## 4. What transfers unchanged

Everything below is Steins' implemented model / the RFC's semantics, adopted as-is. It is listed so
the Ruby sections can be read as *deltas*.

- **Labels are dot-paths checked by segment-aware prefix subsumption** — `io` admits
  `io.net.http`, rejects `iota`. Adding a leaf never changes a recognised bound; moving or removing
  a node is breaking and degrades fail-open (RFC "Vocabulary evolution").
- **An envelope is a declared upper bound**, checked structurally against the method's *code*
  ("an `echo` in dead code is still an origin"; blocks count — § 5.4). `pure` = the empty
  envelope, tolerating `mutate.local` only. Envelopes on a supertype's method bind overrides
  (Liskov inclusion: implementations may be purer, never less pure).
- **Two lanes plus an exhaustiveness bit.** A summary carries a *proven* set (catalogued origins,
  language constructs, project bodies, transitively), a *declared* set (`≤` bounds imported at
  call sites whose concrete callee is unknown), and an exhaustiveness bit tainted by any
  unresolved or dynamic call. **Diagnostics read the proven lane only; taint never produces a
  finding** and renders as "these effects, and possibly more".
- **Unknown label ⇒ the whole tag reads as ⊤** (fail-open, never the recognised subset), paired
  with a separate opt-in vocabulary diagnostic that fires only where label intent is evident.
- **Class-level envelope distributes over the class's own methods, nearest-wins** (method tag
  overrides class tag; no `-except` syntax needed).
- **Discharge by policy** (Steins ADR-0084): a project-wide `tolerated` label set consulted at
  judgment time, never at inference; four invariants — the catalogue never lies, the concealment
  is one auditable place, an audit switch reproduces the unconcealed world, emission never writes a
  tag from a discharged set.
- **Argument-dependent narrowing**: an argument-blind catalogue row is a *sound* upper bound
  (`io`); a proven literal argument narrows it (`'https://…'` → `io.net.http`).
- **Diagnostic identifiers** `effect.envelope-exceeded`, `effect.liskov-widened`,
  `effect.unknown-label` — reused verbatim so a finding reads the same in both tools.

## 5. What Ruby changes

### 5.1 Origins: almost nothing is syntax

PHP has `echo`, `exit`, inline HTML. Ruby's effectful *syntax* is small; nearly every origin is a
method on `Kernel` or a core class, so the catalogue does most of the work. Language-construct
origins, by Prism node:

| Construct | Label |
| --- | --- |
| `` `cmd` ``, `%x(cmd)` (`XStringNode`, `InterpolatedXStringNode`) | `io.process` |
| `$g` read (`GlobalVariableReadNode`) — except the frame-local specials `$~ $1..$9 $& $_` etc. | `global.read` |
| `$g = …`, `$g ||= …`, `$g += …`, multi-target `$g` | `global.write` |
| `@@cv` read / write | `global.read` / `mutate.static` |
| `@iv` write in an instance-method body | `mutate.self` |
| `@iv` write in a singleton-method body (`def self.x`, `class << self`) | `mutate.static` |
| `alias` / `undef` inside a method body | `mutate.static` |
| `a[i] = v`, `obj.x = v` (index / attribute write) | a mutating call — classified by receiver ownership, § 5.2 |
| block literal, `-> {}`, `proc {}`, `lambda {}` | *containment*: the body's origins join the enclosing method's summary (§ 5.4) |
| `define_method(:lit) { … }` on the lexical class | the block becomes `lit`'s body; the call itself is `mutate.static` |
| `yield`, `blk.call` on a block parameter | ∅ — the block's effects are accounted at the caller's literal |
| `send` / `public_send` / `__send__` with a literal symbol | an ordinary edge; non-literal → taint |
| `super` | an edge to the ancestor's definition (discovery tables); unresolvable → taint |
| `eval`, `instance_eval(String)`, `class_eval(String)`, `binding` | taint |
| `raise`, `throw`, `retry` | not a label (stays in the flow-effect bundle's `exceptional` slot) |
| `BEGIN` / `END` / `__END__` / class-body statements | out of scope in v1 |

Catalogued origins (representative seed; the full table is a WD1 artefact). The rule Steins states
for wrapper-capable stream APIs applies with equal force to Ruby: **an argument-blind row on a
world-facing class is the parent label, and precision returns only at proven sites.**

| Ruby | Label | Note |
| --- | --- | --- |
| `puts print p pp printf putc display`; `$stdout.*` / `STDOUT.*` | `io.output.stdout` (+ `global.read` for `$stdout`) | Ruby has no output-buffer layer; `.buffer` / `.header` stay in the registry, unproduced |
| `warn`; `$stderr.*` / `STDERR.*` | `io.output.stderr` | |
| `IO#write / puts / read …` on an IO whose channel is unknown | `io` | file, socket or terminal — the parent is the sound row |
| `gets readline readlines`, `$stdin` / `STDIN` / `ARGF` reads | `io.input` | |
| `exit exit! abort`, `Process.exit` | `exit` | `at_exit { }` is containment |
| `system spawn exec fork`, `IO.popen`, `Open3.*`, `Process.*`, `PTY` | `io.process` | |
| `trap`, `Signal.trap`, `Process.kill` | `io.signal` | |
| `File.read / readlines / exist? / stat / open(path, "r")`, `Dir.glob / entries`, `Pathname#read`, `IO.read` | `io.fs.read` | mode literal narrows `File.open`; unknown mode → `io.fs` |
| `File.write / delete / rename / chmod`, `Dir.mkdir`, `FileUtils.*`, `Tempfile.new` | `io.fs.write` | |
| `Kernel#open(x)` | literal path → `io.fs.*`; literal `"|cmd"` → `io.process`; unknown → `io` | the classic pipe-injection footgun becomes visible in the summary |
| `URI.open` (open-uri), `Net::HTTP.*` | literal `http(s)://` → `io.net.http`; unknown → `io` / `io.net` | |
| `TCPSocket Socket UDPSocket OpenSSL::SSL::SSLSocket Resolv Addrinfo` | `io.net` | |
| `UNIXSocket`, `IO.pipe` | `io.ipc` | |
| `rand srand`, `Random.rand`, `Random.new` (no seed), `Random.new_seed`, `SecureRandom.*`, `Array#shuffle / shuffle! / sample` | `nondet.random` (`srand` also `global.write`) | note the Ruby-flavoured origins on `Array` |
| `Time.now`, `Time.new` **with no arguments**, `Date.today`, `DateTime.now`, `Process.clock_gettime` | `nondet.time` | `Time.new(2020, 1, 1)`, `Time.at(x)` are ∅ — arity-dependent narrowing |
| `Time#getlocal`, `Time.zone` (plugin) | `global.read` | the "host-dependence" axis the fold catalogue already isolates; `Time#localtime` / `utc` additionally mutate the receiver |
| `ENV[] / fetch / key?`, `Dir.pwd`, `Thread.current[]`, `$LOAD_PATH` read, `ObjectSpace.*`, `GC.stat` | `global.read` | |
| `ENV[]= / delete`, `Dir.chdir`, `Thread.current[]=`, `$stdout = …`, `Warning[]=`, `Encoding.default_external=`, `GC.disable` | `global.write` | |
| `require require_relative load autoload` | `io.fs.read` (+ `mutate.static`, open question § 13) | lazy `require` inside a method is a real Ruby idiom |
| `Module#define_method / alias_method / include / prepend / extend / attr_* / const_set / remove_const / private / module_function / refine` in a method body | `mutate.static` | |
| `Object#instance_variable_set` | on `self` → `mutate.self`; otherwise by ownership | |
| `Fiddle::Function#call`, `FFI::Library` attached functions (rigor-ffi) | `ffi` | |
| `Logger#info / debug / …` | `io` (destination unknown) + a semantic `telemetry` label | the tolerated-policy poster child; `Rails.logger`, `ActiveSupport::Notifications.instrument` via rigor-rails |
| `Kernel#sleep`, `Queue#pop`, `Mutex#lock`, `Thread.new`, `Ractor.new`, `Fiber` | **open** (§ 13) | blocks join by containment; the primitives carry no label in v1 |

Two default postures the catalogue needs, because Ruby's core surface is far larger than Steins'
frequency-seeded PHP set: **value classes** (`Array Hash String Symbol Integer Float Range Struct
Data Set Comparable Enumerable …`) default to ∅ for uncatalogued methods, with mutators and the
nondeterministic few catalogued explicitly; **world-facing classes** (`Kernel IO File Dir Process
Socket Net::* ENV Signal Random Time`) default to `io` (or taint) for uncatalogued methods, with
rows narrowing. That is the same "sound upper bound by class family" move Steins makes per row,
lifted to a per-class default so the exhaustive bit stays meaningful in ordinary Ruby.

**What the existing catalogues can and cannot seed.** `data/builtins/ruby_core/*.yml` carries a
per-method `purity` and `c_effects` facet extracted from CRuby's C bodies — but that axis is
*fold-safety in the C-dispatch sense*, not effect freedom: `Random#rand` is `purity: leaf`,
`Array#push` is `leaf` with `c_effects: []` (`rb_ary_modify` is a macro the classifier does not
see), `Array#sort` reads `mutates_self` because it `rb_check_frozen`s its own copy. So **effect
labels cannot be read off `purity:`**. What can seed the effect catalogue: the `c_effects: mutate`
and `block` markers (candidate mutators / block-dependent rows), the hand-audited
`mutating_selectors:` blocklists in `lib/rigor/inference/builtins/*_catalog.rb`
(`random_catalog.rb` already separates mutation from nondeterminism from purity in prose),
`MethodCatalog::NON_REPRODUCIBLE_SELECTORS` (`hash`, `object_id`, `__id__` — the existing
`nondet` concept), `MutationWidening::ARRAY_MUTATORS` / `HASH_MUTATORS`, and
`ClosureEscapeAnalyzer`'s non-escaping / escaping tables. The effect catalogue is a **new,
hand-audited artefact** (proposed `data/effects/core.yml`) that cites those as evidence; it is not
a re-reading of the generated files.

### 5.2 Mutation: no by-ref, so `mutate.local` means ownership

PHP's `mutate.local` names a by-ref out-parameter write into a frame-private binding. Ruby has no
by-ref parameters; what it has instead is pervasive receiver mutation (`<<`, `[]=`, bang methods,
`@x =`). The same envelope question — *can a caller observe it?* — is answered by **who owns the
receiver**, and Rigor already lists the proof obligations
([control-flow-analysis.md § Proof obligations](../type-specification/control-flow-analysis.md):
freshly allocated, not escaped, not passed to a call that may store it):

| Receiver of a mutating call / write | Label |
| --- | --- |
| a frame-owned object: freshly allocated in this body, never escaped (`rows = rows.dup; rows.sort!`, `buf = +""; buf << x`) | `mutate.local` — tolerated by every envelope, `pure` included |
| `self`'s state: `@iv = …`, `@list << x`, `self.x = …`, `attr_writer` on self | `mutate.self` |
| an object that arrived as an argument (`params[:x] = …`, `list << x` where `list` is a parameter) | `mutate.arg` |
| class-level state: `@@cv`, ivars in singleton context, `const_set`, `define_method`, object-model calls | `mutate.static` |
| anything else — a call result, an ivar of another object, unclassifiable | `mutate` (bare, conservative parent) |

`mutate.self` / `mutate.arg` / `mutate.static` are Ruby's proposed leaves; Steins ADR-0055 reserves
`mutate.self` / `mutate.instance` / `mutate.static`, so the names should be reconciled before
either ships (§ 13). They earn their place twice over: `pure` needs only the `mutate.local`
carve-out, but the fact store's invalidation buckets (local-binding, object-content,
global-storage — control-flow-analysis.md § Scope snapshots) map one-to-one onto them, which is
the § 8 "invalidation keys" consumer. Rigor already computes the `mutate.arg` half per method
(`content_mutated_parameter_positions`, ADR-89 WD2, persisted in the incremental snapshot); the
`mutate.self` half is a syntactic scan of ivar writes; the ownership judgment for `mutate.local` is
the freshness / escape proof obligation the spec already states, with
[ADR-76](../adr/76-effect-modeling-freeze-dup-shape-preservation.md)'s `dup` / `clone` handling
as the allocation witness.

Ruby-specific tension: the **memoization idiom** `@x ||= compute` is `mutate.self`, so a
`pure`-declared memoized reader is a finding. That is the truthful answer (the write is observable
through `instance_variable_get`, `inspect`, and thread interleavings) and it matches Steins, which
tolerates only constructor own-property initialisation. A memoized method declares
`%a{rigor:v1:effect mutate.self}` — or the project tolerates `mutate.self` by policy — rather than
the checker guessing. Open for the owner (§ 13).

### 5.3 Dispatch: no `final`, so self-calls are not authoritative

Steins draws `$this->` edges under a final/private guard. Ruby has no `final`; every method is
overridable, every class re-openable. Three consequences:

- **Self-calls resolve against the project as a closed world.** `Rigor::Inference::ScopeIndexer`'s
  discovery tables know every project definition and every subclass; the ADR-57 N5 gate already
  degrades a base body whose subclass redefines the method. For effect edges the recommendation
  is to **join every project-known override** (the caller's summary is the union over
  the base body and each override in the project) rather than taint — the same closed-world
  posture Rigor takes for types. A receiver whose class is unknown still taints.
- **Reopening**: multiple `def`s of one `Class#method` in the project → union of their summaries
  (statically sound; runtime last-wins is unknowable at analysis time). A *gem* monkey-patching a
  core method is invisible, exactly as it is for types — an accepted risk of the same class.
- **`send` with a non-literal, `method_missing` on the receiver's class, `Dynamic[top]`
  receivers, `respond_to?`-guarded duck typing → taint.** In heavily untyped code the proven
  lane will be small at first; that is the honest state, and it is precisely why the report
  (§ 9.3) says "and possibly more" instead of "pure". The proven lane grows with dispatch quality
  and plugin coverage — the ADR-102 criterion for a *diagnostic* (precision is a function of
  analysis quality) is met.

`rigor trace`'s `resolved:` per-call-site bit and the `dynamic_origins` side-table (`Rigor::
Inference::DynamicOrigin` — `external_gem_without_rbs`, `framework_dsl_boundary`, …) already name
*why* a call is unresolved; the taint should carry the same cause so the report can say "possibly
more — because `user.save` on a receiver from `activerecord` without RBS".

### 5.4 Blocks: effect polymorphism is nearly free

`array_map`'s callback problem drove the PHP work. Ruby's answer is structural: the callback is
almost always a **block literal at the call site**, so the higher-order call's effect is the
catalogue row's effect ∪ the literal block body's effect, with no effect variables. The rule that
makes the bookkeeping trivial and keeps the "code contains" contract honest: **a block literal's
origins always join the enclosing method's summary, whether the callee invokes it now, later, or
never** (an envelope is a contract about the method's code). Consequences:

- `xs.map { |x| x * 2 }` — ∅. `xs.map { |x| Model.create!(x) }` — `io.db`. `cache.fetch(k) {
  Model.find(k) }` — `io.db` (proven: the code contains it).
- A callee that `yield`s or forwards `&block` contributes ∅ for the yield; its own summary is
  what it is. No `block_dependent` state is needed in *user* summaries; the catalogue's
  `block_dependent` rows are simply "∅ from the row, containment from the literal".
- Opaque callables taint: `Proc#call` on an ivar / a hash of lambdas / a `Method` object,
  `&callable` where the callable is not a literal, `&:sym` where the element type is unknown.
  `&:sym` on a known element type is an ordinary edge.
- `define_method(:name) { … }` with a literal name attaches the block to `name`'s summary
  (§ 5.1). `Thread.new { }`, `at_exit { }`, `Ractor.new { }` are containment.

`ClosureEscapeAnalyzer` (non-escaping vs escaping vs unknown) is left untouched by this: it
answers a *fact-retention* question, not a "does the code contain" question. Its file already
reserves the "RBS-Extended call-timing effect" seat for the day the catalogue moves into RBS.

### 5.5 Class bodies, exceptions, concurrency

- Class-body statements (`has_many :posts`, `validates …`, `require` at file top) execute at load
  time; v1 summarises `def` / `define_method` bodies only. Load-time effects are a later, separate
  unit ("file-level code" in Steins' terms).
- Exceptions are not labels (§ 2). Where the throw set matters — the discard rule (§ 8.4) — the
  catalogue's `raises` facet is the stand-in.
- Concurrency primitives carry no label in v1; blocks join by containment. A `concurrent` root
  is deliberately not proposed until a consumer needs it.

## 6. Declaration surfaces — the Ruby-ish answer

The premise: **no new grammar.** Rigor already reads four author surfaces; effect envelopes ride
them, in a fixed order of preference from "no declaration" to "per method".

### 6.1 Nothing — inference is the default

Every method gets a summary. The report (§ 9.3) and the engine consumers (§ 8) need no
declaration. This is the surface most methods live on, and the design's answer to the non-goal
"comment every class/method".

### 6.2 Convention: envelopes by namespace / path (`.rigor.yml`)

Rails-style convention over configuration is the Ruby way to say "presenters do not query":

```yaml
effects:
  envelopes:
    - match: "app/presenters/**/*.rb"     # File.fnmatch, project-relative — the ADR-28 shape
      effect: []                            # pure
    - namespace: "Policies::*"
      effect: [mutate.local]
    - namespace: "App::Models::*"
      effect: [io.db, nondet.time, mutate]
    - match: "app/jobs/**/*.rb"
      effect: [io]
```

An entry attaches an envelope to every method of every class it matches, distributing exactly as a
class-level annotation does (nearest-wins: a per-method annotation overrides it). This is the
existing [ADR-28](../adr/28-path-scoped-protocol-contracts.md) path-scoped contract shape —
`ProtocolContract` already binds a per-method contract with a severity to classes by `path_glob` —
lifted from a plugin-manifest field to a project config key. It is also the one surface that
gives *value on day one* to a project that writes no RBS: one stanza checks a whole architectural
layer.

Config keys are subject to [ADR-99](../adr/99-config-schema-authority.md)'s two-source-of-truth
rule (`Configuration::DEFAULTS` + `schemas/rigor-config.schema.json`) and the reserve pipeline in
[config.md](../internal-spec/config.md); the `effects:` block would join the ADR-45 run-cache
identity (§ 10).

### 6.3 `%a{pure}` — the ecosystem's existing purity spelling

RBS already has a purity annotation in the wild: **`%a{pure}`**. Steep treats a method so
annotated as a *pure method* whose call expressions can be narrowed and remembered
([Steep doc/narrowing.md § Type environment](https://github.com/soutaro/steep/blob/master/doc/narrowing.md));
rbs core carries it (`Regexp#timeout`), and both rbs' and Steep's own `sig/` use it. Rigor already
honours one rbs-native annotation (`%a{implicitly-returns-nil}`). So `%a{pure}` is to Ruby what
`@phpstan-pure` is to PHP — the interop spelling — and Rigor should:

- **read** `%a{pure}` as the empty envelope (`{mutate.local}`), the exact reading Steins gives a
  bare `@phpstan-pure`; and
- **write** it back through `rigor sig-gen` from exhaustive proven inference (§ 12 WD6), which
  hands Steep users better narrowing for free — a cross-tool return the PHP side does not have.

Because `%a{pure}` pre-exists, adopting it is a *semantic migration* for projects that already
carry it (the RFC's "Backward compatibility — two claims"): its *checking* ships behind the
effect opt-in, never on the quiet default surface.

### 6.4 `%a{rigor:v1:effect …}` and `%a{rigor:v1:pure}` — the labelled spelling in RBS

Rigor's checked spelling lives where its other directives do, on RBS method and class
declarations:

```rbs
class UserRepository
  %a{rigor:v1:effect io.db}
  def find: (Integer) -> User

  %a{rigor:v1:pure}
  def slug: (String) -> String
end

%a{rigor:v1:effect io.net.http, telemetry}      # class-level: distributes, nearest-wins
class MailerGateway
  # …
end
```

Grammar as the RFC's `label-list` (`label { "," label }`, `segment = [a-z][a-z0-9]*`), with the
`rigor:v1:` head; `rigor:v1:pure` takes no labels (the spec'd directive in control-flow-analysis.md
finally implemented). Mechanically it is a fourth regex/reader pair in `Rigor::RbsExtended`
(there is no directive registry — [rbs_extended.rb](../../lib/rigor/rbs_extended.rb)), a
class-level reader through `RbsLoader#each_class_decl_annotation_with_name` (the `conforms-to` /
HKT path), and a new **`effects`** slot on `Rigor::FlowContribution` so plugins and annotations
attribute labels at a call edge through the one merger that already orders provenance
(`builtin > rbs_extended = generated > plugin`); the bundle's `mutations` slot — declared, doc'd
as "conflicts with `pure`-style declarations are diagnostics", and **fed by no producer today** —
finally gets its producer. Adding a slot is an ADR-2 public-API expansion
([flow-contribution.md § Stability](../internal-spec/flow-contribution.md)).

`pure` + `effect` on one declaration is contradictory: `pure` wins (Steins) and the existing
`RbsExtended::Reporter` conflict channel reports it.

### 6.5 The same annotations in `.rb` files, via rbs-inline

`# @rbs %a{…}` is a first-class rbs-inline annotation form (ADR-32's grammar list), and the path
into `RbsExtended` is unbroken end to end: rbs-inline's writer emits `%a{}` on the generated
member, `Environment.collect_virtual_rbs` merges the text, and method annotations reach
`RBS::Definition::Method#annotations` — the same object every method directive reads. Since
[ADR-93](../adr/93-default-rbs-inline-ingestion.md) ingests inline comments by default, this
already works today, undocumented and untested:

```ruby
# @rbs %a{pure}
def slug(s) = s.strip.downcase.tr(" ", "-")

# @rbs %a{rigor:v1:effect io.db}
def find(id) = User.find(id)
```

Two facts pull against each other and the owner must pick (§ 13): the handbook states "you cannot
put `%a{rigor:v1:…}` directives inside a `.rb` file — that is a design choice"
([07-rbs-and-extended.md](../handbook/07-rbs-and-extended.md)), echoing ADR-0's "application code
stays free of Rigor-only annotation syntax"; against that, `%a{}` is *rbs-inline's* upstream
grammar, Steep tolerates unknown annotations, and ADR-0's binding sentence forbids *requiring*
annotations, not permitting them. Recommendation: allow `%a{pure}` in `.rb` unconditionally
(ecosystem-neutral) and allow `%a{rigor:v1:effect …}` there too, amending the handbook sentence —
because forbidding it would push authors toward inventing a `# rigor:effect` comment dialect,
which is strictly worse. What is **not** proposed: a new `# rigor:` directive (that family stays
suppression-only: `disable` / `disable-file`), a file-level magic comment, or any runtime DSL.

### 6.6 Third-party attribution: plugins and the project

Gem methods have no bodies Rigor analyses, so someone must colour them. Two channels, differing in
trust (§ 7):

- **A plugin ships RBS annotations** in its `signature_paths:` — a plugin's `.rbs` already loads
  into the same environment and may carry `%a{rigor:v1:…}` (rigor-typescript-utility-types does
  exactly this for `return:`). rigor-rails colours `find` `io.db.read`, `save` `io.db.write`,
  `deliver_now` `io` + `rails.actionmailer.deliver` + `email.send`, `Rails.logger` `io` +
  `telemetry`, `Time.current` `nondet.time`, `perform_later` `io` + `rails.activejob.enqueue` +
  `job.enqueue` — the full table is § 11.2. Enters at authority tier 1.
- **A plugin manifest field `effect_attributions:`** (a `ProtocolContract`-shaped Ruby value:
  receiver, method, labels) or the project's own **`effects.attribution:`** YAML table for gems
  nobody has written a plugin for. Both are unchecked claims about code Rigor did not analyse.
  Framework plugins also need this channel for methods RBS cannot name per app — association
  readers, `find_by_*`, callback edges — where the knowledge is derived from the app's own class
  bodies (§ 11.2 "Framework edges").
- **Vocabulary registration**: `effects.labels: [email.send, telemetry]` in config; a plugin's
  manifest registers labels under a root it owns (Steins ADR-0068 root ownership: descend from a
  core root, or open a root equal to the plugin id) — the project's own config may open any root
  (the owner's listing is the vouching act).

### 6.7 What is deliberately not a surface

Sorbet `sig {}` (no purity there), YARD tags, a runtime `Rigor.pure def …` decorator, a
`# frozen_string_literal`-style file pragma, `Data.define`/`Struct` membership as an implicit
purity claim, and the bang convention as a *declaration* (`save!` and `save` both hit the
database; the convention says "raises" or "mutates in place", not "effect-free"). The bang
convention does reappear as a *message* aid in § 8.4.

## 7. Trust and lanes

Rigor already ranks fact sources — `FlowContribution::Merger`'s authority tiers
(`builtin(0) > rbs_extended(1) = generated(1) > plugin(2) > other(3)`), ADR-10's dispatcher order
(`core RBS > RBS::Extended > plugins > dependency-source inference`), and the purity-policy
sentence naming its authoritative sources ("core Ruby and stdlib RBS distributed with Rigor,
accepted ordinary RBS files, or explicit `rigor:v1:pure`"). Effect envelopes reuse that ladder
rather than a new "stratum" concept:

| Source of the labels | Lane at a call site | Discharges the site's taint? | Contract-checked at the declaration? | Liskov across overrides? |
| --- | --- | --- | --- | --- |
| Rigor's effect catalogue (`data/effects/*.yml`), language constructs | proven | — (it *is* the proof) | — | — |
| project body, transitively | proven | — | — | — |
| project `%a{rigor:v1:effect}` / `%a{rigor:v1:pure}` / `%a{pure}` (RBS or inline), config `envelopes:` — **checked stratum** | declared (`≤`) where the concrete callee is unknown | **yes** — the body is analysed and `effect.envelope-exceeded` holds it to the bound | yes | yes (`effect.liskov-widened`) |
| gem-shipped RBS or Rigor's bundled overlays (`data/gem_overlay`, `data/vendored_gem_sigs`) carrying `%a{}` — accepted signatures | declared | yes — the same trust already extended to their *types* and to their purity by ADR-1:430 | no body to check | no |
| plugin `signature_paths:` RBS annotations (first-party plugins live here) | declared | yes (tier 1) | no | no |
| a **first-party bundled** plugin's `effect_attributions:` / framework edges derived from the app's own class bodies (rigor-rails, § 11.2) | declared / proven edges | yes — audited by the repo's own `make check-plugins` gate, and the knowledge is the project's declarations, not a third party's claim (a decision, § 13) | no | no |
| third-party plugin `effect_attributions:` / project `effects.attribution:` | declared | **no** — nothing checks a claim about un-analysed code (Steins ADR-0068 §1); reads "declared this, and possibly more" | no | no |

The RFC's dichotomy ("contract with substitutability" vs "hint without proof") lands as: Ruby's
one project-authored spelling is the checked stratum with substitutability, and everything about
code Rigor cannot analyse is a hint — with the pragmatic exception that accepted signatures
discharge, because otherwise every Rails app method is non-exhaustive forever and the bit stops
carrying information. A plugin author chooses their stratum by choosing RBS annotations over a
manifest table.

The declared lane's *carrier* is where Ruby is genuinely behind: RBS interface types erase to
`Dynamic[top]` today (`rbs_type_translator.rb`) and there is no structural-interface carrier, so
"a call through an interface-typed receiver imports the interface's bound" has nowhere to attach.
The Ruby-native DI shape is nominal instead — `class PgRepo < Repo`, `ApplicationService#call`,
`ApplicationJob#perform` — and the ADR-57 N5 overridable-method gate is *exactly* the point where a
base method that has an envelope should contribute `≤ bound` instead of shrugging. Interfaces
join when the structural carrier lands ([structural-interfaces-and-object-shapes.md](../type-specification/structural-interfaces-and-object-shapes.md)).

## 8. Engine consumers — why it pays without a single annotation

The corpus has already ruled once on purity: the PHPStan-rules re-survey
([20260715-phpstan-rules-survey-rigor-reevaluation.md](../notes/20260715-phpstan-rules-survey-rigor-reevaluation.md))
rejected *inferred-purity* no-effect-statement rules as high-FP ("Ruby purity is essentially
statically unknowable: memoising ivar writes, monkey-patching, C implementations") and admitted
only annotation-gated must-use and a "fold-catalogue-limited narrow fragment". The two-lane model
is the answer to each objection rather than a contradiction of the verdict: memoising ivar writes
are `mutate.self` and visible; project monkey-patches are project bodies; C implementations are
catalogue rows or taint; and every judgment below reads the proven lane and, where it matters,
the exhaustive bit.

1. **Ivar-narrowing survival across self-calls (B2.2).** `return unless @user; audit!;
   @user.name` — today the `audit!` call resets `@user`'s non-nil narrowing. With `audit!`'s
   proven summary lacking `mutate.self` and exhaustive, the reset can be skipped: fewer spurious
   `call.possible-nil-receiver` firings, no annotation. This is a *typing* consumer, so it changes
   `rigor check` output and must respect the bleeding-edge cache-identity constraint (§ 9.2).
2. **The purity policy's "computed purity property"** — control-flow-analysis.md § Purity policy
   trusts only declared purity for remembering call results across re-invocation (`if x.foo &&
   x.foo.bar`); GitLab adjudication recorded the cost ("no receiver-purity/memoization tracking
   across repeated calls", [20260708-gitlab-diagnostic-adjudication.md:52](../notes/20260708-gitlab-diagnostic-adjudication.md)).
   A proven, exhaustive summary with nothing outside `{mutate.local}` is a computed purity fact
   for a user method without RBS: its results may be remembered across re-invocation. A
   `global.read`-only summary may be remembered until an intervening `global.write` /
   `mutate.static`; a `nondet.*` summary never. And the invalidation *buckets* become
   label-keyed: a call whose proven labels exclude `mutate.self` cannot have touched the
   receiver's object-content bucket; one that excludes `mutate.static` / `global.write` cannot
   have touched global storage — the RFC's "invalidation keys".
3. **Constant-folding permission as a computed property** rather than the hand-picked
   `FOLDABLE_PURITIES` gate (Steins ADR-0008 "folding is gated on effects") — a later slice; the
   allow-list stays until the catalogue is audited to the same bar.
4. **The discarded-pure-result rule** — Ruby's non-bang footgun: `str.strip`, `arr.sort`,
   `hash.merge(x: 1)`, `params.merge!`-vs-`merge`, `list.map { … }` used as `each`. Derivable
   with no annotation: proven effects inside the read-shaped set (`global.read`, `nondet.*`,
   `io.fs.read`), exhaustive, result unused. Two Ruby-specific gates
   keep it honest: (a) the *raise-as-validation* idiom (`hash.fetch(:k)`, `Integer(x)`,
   `JSON.parse(x)` discarded on purpose) — Rigor tracks no throw set, so the catalogue's `raises`
   facet / the folding tier's totality criterion must gate it; (b) a `map` whose block is
   effectful is not dead (containment handles it). The message can name the bang sibling when
   one exists. Ships `:off` pending a corpus FP gate (the `call.self-undefined-method` template) —
   this is the "narrow fragment" the 2026-07-15 note left a slot for, now with a principled
   boundary instead of a hand list.
5. **`rigor sig-gen` write-back** of `%a{pure}` / `%a{rigor:v1:effect …}` from exhaustive proven
   summaries only — never for non-exhaustive methods, never from a policy-discharged set
   (Steins' four invariants; ADR-10 WD7's "opportunistic shapes never round-trip" is the same
   rule). ADR-14 explicitly reserves the annotation-emission slot.

## 9. Diagnostics and reports

### 9.1 What is a diagnostic and what is a report

[ADR-102](../adr/102-unused-code-reachability-report.md)'s line: a signal whose precision is
bounded by knowledge the analyzer cannot have belongs in a report; one whose precision is a
function of analysis quality may be a diagnostic. The **effect footprint** (proven + declared +
exhaustive bit) is a report — its unknowns are the world's. **`effect.envelope-exceeded`** is a
diagnostic — it fires only on a proven origin the author's own bound excludes, and it is FP-safe
by two of the corpus's accepted constructions at once: *opt-in by author directive* (the envelope
is the directive; the finding is never unsolicited — the `rbs_extended.unsatisfied-conformance`
construction) and *as strict as proven* ([robustness-principle.md:47](../type-specification/robustness-principle.md)).
`effect.liskov-widened` is both-sides-authored in the ADR-35 sense (an authored envelope on the
ancestor, proven effects in the override). `effect.unknown-label` reports vocabulary drift at the
declaration only when label intent is evident, and never changes a bound.

### 9.2 Family shape and opt-in mechanics

- Reserve **`effect.*`** in [diagnostic-policy.md](../type-specification/diagnostic-policy.md)'s
  taxonomy with the "as of this writing" marker before any id ships (ADR-100's discipline: fix
  the family shape first). Add `effect` to `RULE_FAMILIES` (so a typo in `disable:` warns) and
  entries to `RuleCatalog` and all three severity-profile tables.
- Severities: `effect.envelope-exceeded` authored `:warning` (`:error` under `strict`) — never
  unsolicited, so it needs no bleeding-edge gate for the *new* spellings; the **`%a{pure}` interop
  reading is the semantic migration** and is gated by the effects opt-in. `effect.unknown-label`
  `:info`, opt-in with enforcement. `effect.discarded-pure-result` `:off` in every profile pending
  the corpus gate.
- **Cache identity.** `BleedingEdge` documents that a `:behaviour` feature must not change
  `rigor check`'s analysis output unless folded into the analysis-cache identity. Summary
  *collection* is a side-table with the `dynamic_origins` properties (node-keyed, excluded from
  `Scope#==`, not read back into typing) and is safe; the *diagnostics* are a post-pool aggregation
  computed from summaries; the `effects:` config block enters the ADR-45 run-cache identity; the
  typing consumers of § 8 (1)–(3) are the ones that must land as cache-identity-aware features.
- Baseline absorbs the family like any other, but under [ADR-50](../adr/50-release-engineering-and-stability-strategy.md)
  WD1 a check on pre-existing `%a{pure}` is a new discipline and ships opt-in.

### 9.3 The report and the review surface

`rigor effects PATH…` — per method: proven labels, declared (`≤`) labels, exhaustive bit, and the
taint *causes* (dynamic-origin reasons), `--format text|json`; the same three-file
`*_command` / `*_report` / `*_renderer` shape as `type-scan`. `rigor effects --set-baseline` /
`--diff` — Steins' `effect-diff`: one line per changed method (`+ io.net.http` on
`OrdersController#create`), always exit 0, functions present on both sides only, a vanished label
claimed only when the current summary is exhaustive, declared→proven as a *materialisation* event.
`rigor effects --at FILE:LINE:COL` — the `type-of` twin, for editor hover later.
`rigor effects --follow-enqueues` — the causal closure through deferred jobs and mailers, report
only (§ 11.2 "Deferred execution"). And `rigor check --no-tolerated-effects` — the audit switch
of § 4.

## 10. Architecture inside Rigor

There is no method-level call graph in Rigor today (the `unused` report is constants-only; the
ADR-46 dependency graph is file→file with symbol tags), but every piece a fixpoint needs exists
and has a house pattern:

| Need | Existing piece to reuse |
| --- | --- |
| syntactic origins per `def` | a pure Prism walk in the shape of `StructFoldSafety` / `ScopeIndexer.build_method_assign_effects` (which is already a per-file, same-class-transitive, cycle-guarded effect table — the closest structural analogue) |
| resolved call edges | the one place dispatch is decided — `ExpressionTyper#call_type_for` → `resolve_user_def_with_owner` (`[def_node, owner_class]`), `MethodDispatcher` tiers for catalogue rows; taint causes from `DynamicOrigin` |
| per-method summary storage | `Runner#return_summaries` — a persisted `{[path, "Class#method"] => {returns:, effects:}}` table already in the incremental snapshot (ADR-84 / ADR-89 WD2); the effect summary is a sibling payload (schema bump) |
| whole-project fixpoint | `ParameterInferenceCollector` for the round / merge determinism discipline (associative, order-preserving merges so pooled = sequential); but effect propagation is graph-only over a **finite lattice** (labels ∪ exhaustive bit), so it is a plain worklist to a true fixpoint — no cap-3 needed |
| where it runs | collection inside the per-file typing in the fork pool (`PoolCoordinator#analyze_files`, marshalled back with the file result); propagation + envelope checks in the post-pool aggregation slot beside `conforms_to_diagnostics` (`Runner#assemble_run_diagnostics`); attribution of a finding to `discovered_def_sources[class][method]` (`path:line`) |
| incremental runs | changed files re-collect; unchanged files' summaries come from the snapshot; the fixpoint always re-runs (cheap) — envelope diagnostics are therefore never stored per file |
| on-demand summaries during typing (§ 8 consumers) | the same recursion-guarded on-demand walk `infer_user_method_return` uses (ADR-55 Kleene iteration, `RECURSION_FIXPOINT_CAP = 3`, `context_tainted?` memo gate): a callee's effect summary is a by-product of the walk that yields its return type; a cycle reads ⊤-with-taint until the post-pool fixpoint refines it |

The vocabulary and the label algebra (`subsumes?`, join, ⊤/∅, registry) are one small pure module
(`Rigor::Effects::Label`), a `Rigor::Effects::Summary` value (`bundles: {origin => labels}`,
`declared: Set`, `exhaustive: Bool`, `causes:` — the flat `proven` set is a projection of the
bundles, kept per origin so policy discharge can be origin-precise, § 11.2), a hand-audited
`data/effects/core.yml` catalogue with a loader mirroring `Builtins::MethodCatalog`, and the config
schema additions of § 6.2 / 6.6.

## 11. Vocabulary v1

### 11.1 The shared registry

The registry is Steins' v1 set verbatim — `exit ffi global.read global.write io io.db io.fs
io.fs.read io.fs.write io.input io.ipc io.net io.net.http io.output io.output.buffer
io.output.header io.output.stdout io.output.stderr io.process io.signal mutate mutate.local nondet
nondet.random nondet.time` — plus Ruby's proposed leaves `mutate.self mutate.arg mutate.static`.
`io.output.buffer` / `io.output.header` stay registered but unproduced (Ruby has no output-buffer
layer; the nearest analogue, `$stdout` reassignment, is a future masking question).

Three layers sit on top of it, following Steins' "transport facts and semantic facts" (`io.net.http`
records the mechanism, `sendgrid.mail.send` the provider operation, `email.send` the application
meaning — "these labels coexist"):

- **Core leaves worth proposing to Steins as shared additions**, because both ecosystems can
  produce them and a policy that names them should transfer: `io.db.read`, `io.db.write`,
  `io.db.transaction` (a `SELECT` through PDO / ActiveRecord is a read whichever language issued
  it; a migration or `INSERT` is a write; `BEGIN`/`COMMIT` is neither). Adding leaves is
  evolution-safe by the § 4 rule — a declared `io.db` admits all three.
- **Application-meaning roots, small and shared**: `telemetry` (loggers, error reporters,
  instrumentation), `email.send`, `job.enqueue`, `cache.read` / `cache.write`. These are the
  labels a policy actually names ("presenters do not enqueue jobs") and the ones the discharge
  policy grips (`tolerated: [telemetry]`), so they must spell the same in Steins and Rigor. Today
  Steins treats `email.send` as an example of a *project* label; promoting a handful to the shared
  registry is a proposal to raise there.
- **Framework roots, owned by the plugin that models the framework**: `rails.*` for rigor-rails,
  by the Steins ADR-0068 root-ownership rule adapted to Rigor's plugin ids (a first-party plugin
  opens the root of the framework it models; a third-party plugin opens a root equal to its
  plugin id; a project's config may open any root). Projects still open their own (`acme.cache`).

### 11.2 A Rails vocabulary

Rails is the reason the framework layer earns its place: **for most Rails facilities the
transport is adapter-dependent and therefore statically unknowable, while the framework operation
is fixed.** `perform_later` is a Redis write under Sidekiq, an in-process thread under `:async`,
nothing under `:test`; `Rails.cache` is memory, Redis, or the filesystem; `deliver_now` is SMTP or
a test double; ActiveStorage is disk or S3. The sound transport row for each is bare `io` — true
and useless for policy. `rails.activejob.enqueue` says what a reviewer means. Both labels are
attributed; the transport keeps the summary honest, the framework label makes it actionable.

Proposed rows (rigor-rails owns `rails.*`; transport labels ride the shared registry; every row is
an upper bound):

| Rails facility | Transport | Framework / meaning |
| --- | --- | --- |
| AR immediate reads — `find`, `find_by`, `first`, `last`, `take`, `exists?`, `count`, `sum`, `pluck`, `pick`, `find_each`, `load`, `to_a`, `each`, `reload`; `belongs_to` / `has_one` readers; `find_by_sql` | `io.db.read` (+ `mutate.self` for `reload`) | — |
| AR writes — `save`, `save!`, `create`, `update`, `update!`, `destroy`, `delete`, `touch`, `increment!`, `insert_all`, `upsert_all`, `update_all`, `delete_all`, `update_columns`; `has_many` `<<` / `create` / `destroy` | `io.db.write` | — |
| `transaction { }`, `with_lock` | `io.db.transaction` + containment | — |
| `connection.execute(sql)`, `exec_query`, `select_all` | literal SQL verb narrows: `SELECT` → `io.db.read`, `INSERT` / `UPDATE` / `DELETE` / DDL → `io.db.write`; unknown → `io.db` | the argument-dependent narrowing of § 4, for SQL |
| Migration DSL in `change` / `up` / `down` (`create_table`, `add_column`, …) | `io.db.write` | `rails.schema.write` |
| Relation **builders** — `where`, `joins`, `includes`, `preload`, `order`, `select`, `limit`, `scope` bodies, `has_many` readers, `association.build` | ∅ — lazy, nothing is issued | see the laziness note below |
| `Rails.cache.read` / `fetch` / `exist?`; `.write` / `delete` / `increment` / `clear` | `io` | `cache.read` / `cache.write` (+ containment for the `fetch` block) |
| `perform_later`, `set(wait:).perform_later`, `perform_all_later`, `enqueue` | `io` | `rails.activejob.enqueue`, `job.enqueue` |
| `perform_now` | an **edge** to the job's `perform` | — |
| `UserMailer.welcome(u)` → `deliver_now` / `deliver_later` | `io` (+ enqueue for `later`) | `rails.actionmailer.deliver`, `email.send`; the mailer method body is an edge |
| ActiveStorage `attach`, `upload`, `download`, `purge`, `open` | `io` + `io.db.write` for the attachment records | `rails.activestorage.write` / `.read` |
| ActionCable `broadcast_to`, `ActionCable.server.broadcast`, Turbo `broadcast_*` | `io` | `rails.actioncable.broadcast` |
| `Rails.logger.*`, `logger.*`, `Rails.error.report` / `handle`, `ActiveSupport::Notifications.instrument` | `io` (destination unknown) | `telemetry`; `instrument` keeps its taint — subscribers are arbitrary |
| Controller response — `render`, `render_to_string`, `redirect_to`, `head`, `send_data`, `send_file`, `response.headers[]=` | `mutate.self` (`send_file` also `io.fs.read`); `render` keeps a taint — the template is not analysed | `rails.response.write` |
| `session[]=`, `reset_session`; `session[]` read | `mutate` / `io` (the store may be a cache or the database) | `rails.session.write` / `.read` |
| `cookies[]=`, `cookies.encrypted[]=`, `flash[]=`, `flash.now[]=` | `mutate` | `rails.cookie.write`, `rails.flash.write` |
| `Current.attr` read / write (`ActiveSupport::CurrentAttributes`) | `global.read` / `global.write` (fiber-local storage) | `rails.current.read` / `.write` |
| `Rails.env`, `Rails.configuration.*`, `Rails.application.config.*`, `Rails.root` | `global.read` (mutable process state — `Rails.env = "test"` is a thing) | `rails.config.read` |
| `Rails.application.credentials.*`, `secrets` | `io.fs.read` (first access) + `global.read` | `rails.credentials.read` |
| `I18n.t` / `l`, `I18n.locale=` | `global.read` (locale, lazy backend load) / `global.write` | `rails.i18n.translate` |
| `Time.current`, `Date.current`, `Time.zone.now`, `n.days.ago` / `from_now`, `Time.zone` | `nondet.time` (+ `global.read` for the zone) | — (an optional `nondet.time.system` leaf for zone-blind `Time.now` / `Date.today` is possible but is a lint, and RuboCop-Rails' `Rails/TimeZone` already owns it) |
| ActiveSupport core_ext — `blank?`, `present?`, `presence`, `try`, `to_json` / `as_json`, `deep_dup`, `deep_merge`, inflections, `in?`, `squish`, … | ∅ — `%a{pure}` en masse in rigor-activesupport-core-ext's shipped RBS | the single cheapest purity win in a Rails app: these are the predicates narrowing sees most |
| `establish_connection`, `Rails.application.reload_routes!`, `Rails.autoloaders.main.reload` | `global.write` / `mutate.static` | — |
| Route helpers (`*_path`, `*_url`, `url_for`) | ∅ (a pure function of the route set; `_url` reads `default_url_options` → `global.read`) | — |

**Laziness.** `where` builds a `Relation` and issues nothing; the query fires at a materializer.
Two readings are possible: colour builders `io.db.read` because that is how Rails developers
*think* ("`where` hits the DB"), or colour builders ∅ and the materializers `io.db.read`, which is
what the code does. Recommendation: the truthful reading — a presenter that builds and returns a
scope has pure *code*, and the caller that materialises it gets the read; the catalogue never lies
(§ 4). The Enumerable delegations that materialise (`map`, `each`, `any?`, `empty?`, `size`,
`present?`, `blank?`, `to_json`) are catalogued as materializers on `Relation` receivers, which
Rigor already types (ADR-26). A returned `Relation` carrying a *value-provenance* label that
becomes `io.db.read` wherever it is consumed is Steins' "connection-provenance effects" future
mechanism, and the right eventual answer to "the query happens in the view".

**Framework edges.** rigor-rails knows things the syntax does not: `save` runs the class body's
`before_save :normalize` / `validate :check` / `after_commit` callbacks and validators
(`validates :email, uniqueness: true` is an `io.db.read` inside `valid?` and `save`),
`perform_now` runs `perform`, `UserMailer.welcome(u)` runs `welcome`. A plugin therefore
contributes **edges**, not only labels — the same discovery it already performs for typing. What
it must not do is edge `perform_later` to `perform` (another process; the enqueue is the effect)
or `render` to a template (not Ruby; taint stays).

**Deferred execution.** ActiveJob's `set(wait: 1.hour)` / `set(wait_until:)`, ActionMailer's
`deliver_later`, `perform_all_later`, `enqueue_after_transaction_commit` (on by default from
`load_defaults "8.2"`), `after_commit`, delayed_job's / the `delayed` gem's `object.delay.method`
proxy and `handle_asynchronously`, Sidekiq's `perform_async` / `perform_in`, and in-process
deferral (`Thread.new`, `Concurrent::Future`, `Async { }`) are one family, and one rule covers it:
**attribution follows the code, not the clock.** Four consequences —

- *Builders are pure, the enqueue is the effect.* `set(…)` returns a `ConfiguredJob`,
  `UserMailer.welcome(u)` a lazy `MessageDelivery`, `x.delay` a `DelayProxy`: ∅, exactly like a
  Relation builder. The `.perform_later` / `.deliver_later` / proxied method call on them is the
  `job.enqueue` (+ `rails.activejob.enqueue`) origin. Deferring the enqueue itself to after commit
  changes *when*, not *whose code* — the caller's summary is unchanged.
- *No edge into the deferred body.* `perform`, the mailer method under `deliver_later`, the
  proxied method under `.delay` run in another process on another stack; the caller's code does
  not contain them. `perform_now` / `deliver_now` / `foo_without_delay` are ordinary edges.
- *In-process deferral is containment.* A `Thread.new { }` or `Concurrent::Future.execute { }`
  block is this method's code (§ 5.4); its origins join as proven, whenever the thread runs.
- *The transport is a project fact, and it can narrow.* Argument-blind, `perform_later` is `io`
  (§ 11.2). But the queue adapter is declared once in the app (`config.active_job.queue_adapter`),
  and rigor-rails can read it — the configuration-level twin of argument-dependent narrowing:
  Solid Queue (Rails 8's default) → **`io.db.write`** (an `INSERT` into `solid_queue_jobs`; a
  "no database on this path" envelope is right to object), Sidekiq / Resque → `io.net`
  (Redis), `:async` → ∅ transport, `:inline` → an edge to `perform` after all. Unread or
  per-environment adapters keep the `io` row. The `delayed_job` gem is database-backed
  (`io.db.write`) whichever way it is reached.

The question reviewers also ask — "what happens *because of* this request, jobs included?" — is a
different relation, a **causal closure**, and belongs in the report, never in the envelope
check: `rigor effects --follow-enqueues` adds `perform_later → perform` and `deliver_later →
mailer` edges for the footprint only, so a controller action can be read as "eventually sends an
email" while its envelope still describes only its own code.

**Conventions preset.** rigor-rails can ship an *illustrative* `effects.envelopes` stanza — never
enforced by default — matching Rails' layer conventions: `app/presenters/**`, `app/serializers/**`,
`app/decorators/**` → `[mutate.local, rails.config.read, rails.i18n.translate]`; `app/policies/**`
→ `[io.db.read, rails.config.read]`; `app/models/**` → `[io.db, mutate, nondet, telemetry,
rails.activejob.enqueue, email.send]` (so a model that starts calling `Net::HTTP` reports);
`app/jobs/**` → `[io]`; `app/controllers/**` unbounded; `db/migrate/**` → `[io.db]`;
`spec/**` / `test/**` excluded. Whether a project adopts any of it is the project's call; the
`tolerated:` set (`[telemetry, rails.config.read]` is the plausible default a project writes) is
what keeps such stanzas from being honest-and-unactionable.

**Precision the framework layer needs from the engine.** Tolerating `rails.config.read` must
discharge the `global.read` that *came from* `Rails.env`, not a `global.read` from `$foo` in the
same body — Steins' "tolerate semantic labels, not transport labels … requires the judgment to
know how an effect arrived". So a summary keeps **per-origin label bundles** (site → labels), and
the flat proven set is a projection (§ 10); a bundle whose semantic label is tolerated is
discharged whole, and a transport label that also arrived through an untolerated origin stays.

## 12. Slice plan

| Slice | Lands | Gate |
| --- | --- | --- |
| **WD0** | `CONTEXT.md` terms; ADR + `docs/type-specification/effect-labels.md` (labels, subsumption, envelope grammar, lanes, unknown-label rule) + internal-spec section; `effect.*` reserved in diagnostic-policy.md | docs gate |
| **WD1** | label algebra + registry; `data/effects/core.yml` seed (Kernel / IO / File / Dir / Process / Time / Random / ENV / globals / backticks) with per-class default posture; syntactic origin scan; edge collection at dispatch; per-method summaries persisted; post-pool fixpoint; `rigor effects` report (text/json). **No diagnostics.** | corpus measurement: exhaustive ratio and proven-label distribution on mastodon / redmine / gitlab; byte-identical `check` output |
| **WD2** | `%a{rigor:v1:effect}` / `%a{rigor:v1:pure}` (RBS + inline, method + class); `%a{pure}` interop reading behind the opt-in; `FlowContribution#effects` slot; `effect.envelope-exceeded`, `effect.unknown-label`; rule-catalog / severity-table wiring | opt-in only; zero firings with the feature off |
| **WD3** | declared lane through nominal supertypes at the ADR-57 N5 gate; `effect.liskov-widened` over project subclass overrides | both-sides-authored |
| **WD4** | `effects.envelopes` (path / namespace conventions), `effects.attribution`, `effects.labels`, `effects.tolerated` + `--no-tolerated-effects`; plugin `effect_attributions:` + framework edges; the Rails vocabulary of § 11.2 in rigor-rails (RBS colouring, `rails.*` root, laziness rows, callback edges) and `%a{pure}` across rigor-activesupport-core-ext | Rails corpus: a `Presenters::*`-pure stanza reports only genuine queries; the `io.db.read` / `io.db.write` / application-meaning roots raised with Steins as shared additions |
| **WD5** | engine consumers: B2.2 ivar-reset skip, purity-policy computed purity, `effect.discarded-pure-result` (`:off`) — each cache-identity-aware | corpus FP gates per consumer |
| **WD6** | `rigor sig-gen` `%a{pure}` / envelope emission from exhaustive summaries; `rigor effects --diff` baseline; `--at` probe | round-trip: emitted tags re-check clean |
| later | structural-interface carriers, `$stdout`-capture masking, complement bounds, concurrency labels, semantic-label path memory for precise policy, load-time (class-body) units | — |

## 13. Decisions for the owner

1. **Vocabulary alignment** — adopt Steins' 25 verbatim as the shared registry; reconcile the
   Ruby leaves `mutate.self / arg / static` with Steins ADR-0055's reserved
   `mutate.self / instance / static` before either ships.
2. **`.rb`-side spelling** — permit `# @rbs %a{rigor:v1:effect …}` (reverses the handbook's
   stated design choice) or restrict `.rb` to `%a{pure}` + config conventions? Recommendation in
   § 6.5: permit, amend the handbook.
3. **`%a{pure}` interop** — read as `{mutate.local}` (Steep-compatible) and write it back from
   `sig-gen`? Recommendation: yes to both, checking gated by the opt-in.
4. **Discharge policy** — accepted signatures and plugin RBS discharge taint; manifest / YAML
   attribution never (§ 7). The alternative (Steins-strict: only project bodies and the catalogue
   discharge) keeps every Rails method non-exhaustive.
5. **Self-calls in open classes** — closed-world join over project-known overrides (recommended)
   vs taint.
6. **`require` family** — colour `io.fs.read` (+ `mutate.static`?), and does Rigor ship any
   default `tolerated:` set (recommendation: ship none; document the stanza)? Also `sleep` /
   `Queue#pop` / concurrency primitives.
7. **Memoization** — `@x ||= …` under `pure` is a finding (recommended, matches Steins) vs a
   dedicated `mutate.self.memo` leaf tolerated by `pure`.
8. **Where the discard rule lives** — `effect.discarded-pure-result` (derived from labels) vs a
   `flow.*` / `static.*` home.
9. **Spec home** — `docs/type-specification/effect-labels.md` (the label language is type-model
   behaviour) + an internal-spec section for collection / propagation, or one internal-spec
   document only.
10. **Naming** — "effect label / effect summary / effect envelope" as trapped compounds, "flow
    effect" retained for the bundle; or rename the bundle's vocabulary instead.
11. **Shared additions to raise with Steins** — `io.db.read` / `io.db.write` / `io.db.transaction`
    as core leaves, and a small application-meaning set (`telemetry`, `email.send`, `job.enqueue`,
    `cache.read` / `cache.write`) in the shared registry rather than per-project (§ 11.1).
12. **First-party plugin trust** — do rigor-rails' framework-derived attributions and edges
    discharge taint (recommended: yes, they are gated by `make check-plugins` and derived from the
    app's own declarations) or stay in the never-discharging plugin row (Steins-strict)?
13. **Relation laziness** — builders ∅ / materializers `io.db.read` (recommended, truthful) vs
    builders `io.db.read` (how developers think); and whether `Rails.env` / `Rails.root` reads are
    `global.read` (recommended — mutable process state, tolerate by policy) or ∅.

## 14. Repo facts this note rests on

Gathered 2026-08-16 against master `03dcc73b`; verify before acting.

- No method-level call graph; `rigor unused` is constants-only, method reachability deferred to
  #351 (`docs/adr/102-unused-code-reachability-report.md`). ADR-46 edges are file→file with
  `"Class#method"` symbol tags (`lib/rigor/analysis/dependency_recorder.rb`).
- Return summaries persisted per `[path, "Class#method"]` with an `effects:` (mutated-parameter
  positions) field: `lib/rigor/analysis/runner.rb` `#return_summaries`,
  `lib/rigor/cache/incremental_snapshot.rb`.
- Whole-project fixpoint template: `lib/rigor/inference/parameter_inference_collector.rb`
  (`DEFAULT_ROUNDS = 3`, associative merge, `resolve_callee`). Generic lattice fixpoint:
  `lib/rigor/inference/body_fixpoint.rb`. Recursion-guarded on-demand return inference:
  `lib/rigor/inference/expression_typer.rb` `#infer_user_method_return`.
- Run phases: `Runner#assemble_run_diagnostics` (pre-passes → pool → post-pass aggregations);
  pool partitioning in `lib/rigor/analysis/runner/pool_coordinator.rb`.
- `RbsExtended` directives (nine, no registry): `lib/rigor/rbs_extended.rb`; `rigor:v1:pure`
  spec'd, unimplemented. `FlowContribution` slots: `return_type truthy_facts falsey_facts
  post_return_facts mutations invalidations exceptional role_conformance` — `mutations` /
  `invalidations` / `role_conformance` have no producer.
- rbs-inline `# @rbs %a{}` reaches `RbsExtended` end to end (`plugins/rigor-rbs-inline`,
  `Environment.collect_virtual_rbs`); no spec exercises it; the handbook says it is unsupported.
- `# rigor:` directives are `disable` / `disable-file` only (`lib/rigor/analysis/check_rules.rb`).
- Config: no per-method table exists; `severity_overrides` is the only open-keyed map;
  `ProtocolContract` (`lib/rigor/plugin/protocol_contract.rb`) is the path-scoped per-method
  precedent. Authority tiers: `lib/rigor/flow_contribution/merger.rb`.
- Diagnostic family mechanics: `lib/rigor/analysis/check_rules/rule_ids.rb` (`RULE_FAMILIES`),
  `lib/rigor/analysis/rule_catalog.rb`, `lib/rigor/configuration/severity_profile.rb`,
  `lib/rigor/bleeding_edge.rb` (cache-identity constraint), `spec/docs/manual_drift_spec.rb`
  (taxonomy drift). Opt-in template `call.self-undefined-method`; new-family template ADR-100.
- Purity data: `data/builtins/ruby_core/*.yml` (`purity` = fold-safety, not effects),
  `lib/rigor/inference/builtins/method_catalog.rb` (`FOLDABLE_PURITIES`,
  `NON_REPRODUCIBLE_SELECTORS`), `*_catalog.rb` `mutating_selectors:`,
  `lib/rigor/inference/mutation_widening.rb`, `lib/rigor/inference/closure_escape_analyzer.rb`.
- Corpus prior art: no mention of Steins / Flix; Koka named as the surface prior art
  (handbook appendix); the 2026-07-15 PHPStan-rules re-survey's purity verdicts (§ 8);
  ADR-30 names "an engine-side effect analysis" as the future home for FFI resource tracking.
