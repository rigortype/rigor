# Effect Labels

Effect labels are Rigor's second dimension beside types: what a method *does*, as opposed to what it returns. This document is normative for the label language — the grammar, the subsumption relation, the registry that recognises spellings, the envelope syntax that bounds them, and the shape of an effect summary. Collection, propagation and the effect snapshot's file contract are analyzer-internal and are specified in [`effect-summaries.md`](../internal-spec/effect-summaries.md); the rationale is [ADR-103](../adr/103-effect-labels.md), and the research behind it is [`docs/design/20260816-effect-labels.md`](../design/20260816-effect-labels.md).

The whole feature is **opt-in**: nothing here has any effect on a project whose `.rigor.yml` carries no `effects:` block.

The vocabulary is shared with [Steins](https://github.com/rigortype/steins), the sibling PHP analyzer, so that a policy naming `io.db` reads the same against a PHP service and a Rails application.

The compounds are trapped terms ([`CONTEXT.md`](../../CONTEXT.md)): **effect label**, **effect summary**, **effect envelope**. Bare "effect" still names `Rigor::FlowContribution`'s flow-effect bundle and MUST NOT be used for this feature.

## Labels

A label is a dot-path of lowercase segments.

```
label   = segment { "." segment }
segment = [a-z] [a-z0-9]*
```

The grammar is deliberately narrow. A label MUST NOT contain uppercase letters, underscores, hyphens, an empty segment, or a leading or trailing separator, and a segment MUST NOT begin with a digit. `io`, `io.net.http`, `nondet.time` and `job.enqueue` are labels; `IO`, `io_net`, `io-net`, `io.`, `.io` and `io..net` are not.

A label's **root** is its outermost segment. Its **ancestors** are its proper dot-path prefixes, outermost first (`io.net.http` has `io` and `io.net`). Ancestry is a property of the spelling; it does not require the ancestor to be a registered row.

The grammar is a syntactic gate only. A well-formed label the registry does not recognise is *unknown*, which is a different condition with different handling (§ Unknown labels).

## Subsumption

The ordering over labels is **segment-aware prefix subsumption**. A label `B` subsumes a label `L` when `L` equals `B`, or when `L` begins with `B` followed by a separator.

- `io` subsumes `io`, `io.net` and `io.net.http`.
- `io` does **not** subsume `iota`, and `mutate.self` does not subsume `mutate.selfish`: the relation is over segments, never over characters. An implementation MUST NOT use a bare string-prefix test.
- Subsumption never runs upwards: `io.net.http` does not subsume `io.net`.

Subsumption is reflexive, antisymmetric and transitive, so labels form a forest ordered by it.

### Label sets, ∅ and ⊤

A **label set** is a finite, unordered, de-duplicated set of labels. Rendering is sorted so a snapshot diff is stable.

- **Join** is set union.
- A set `S` is **subsumed by** a bound `B` when every member of `S` is subsumed by some member of `B`. `{io.net.http, io.db.read}` is subsumed by `{io}`.
- **∅**, the empty set, is the bottom: no effects. It is subsumed by every bound.
- **⊤** is the unbounded reading — "any effect, or an effect we cannot name". ⊤ subsumes every label, absorbs every join, and is subsumed only by ⊤. ⊤ is **not** the set of all registered labels and is not enumerable; it is what a tag degrades to when its meaning cannot be established (§ Unknown labels).

## The registry

The **registry** is the closed list of recognised label spellings, plus the retired-spelling table and the roots ownership rules. It ships as data — `data/effects/registry.yml` — so plugins and project configuration extend the vocabulary without changing Ruby.

A label is **known** when the registry declares it as a row, or when it is an ancestor of a declared row. A declared `io.net` therefore makes `io.net`'s ancestor `io` known even if `io` had no row of its own, so a bound may name an interior node the data file never spells out. The converse does not hold: a *descendant* of a declared row is not known merely because its ancestor is, even though a declared bound admits it by subsumption.

The shipped registry is the shared base plus three layers:

| Layer | Contents | Who owns it |
| --- | --- | --- |
| Shared base | Steins' v1 set: `exit`, `ffi`, `global.read`, `global.write`, `io`, `io.db`, `io.fs`, `io.fs.read`, `io.fs.write`, `io.input`, `io.ipc`, `io.net`, `io.net.http`, `io.output`, `io.output.buffer`, `io.output.header`, `io.output.stdout`, `io.output.stderr`, `io.process`, `io.signal`, `mutate`, `mutate.local`, `nondet`, `nondet.random`, `nondet.time` | Steins and Rigor jointly; a divergence is raised upstream before it ships |
| Steins-side, unproduced here | `failure`, `failure.environment`, `failure.input`, `failure.resource` | Steins (its ADR-0042); registered here so a policy written against Steins parses |
| Ruby leaves | `mutate.self` (self's state), `mutate.instance` (a receiver that is neither self nor frame-owned), `mutate.static` | Rigor |
| Proposed shared core leaves | `io.db.read`, `io.db.write`, `io.db.transaction` | Rigor, pending adoption by Steins |
| Application meaning | `telemetry`, `email.send`, `job.enqueue`, `cache.read`, `cache.write` | Rigor, proposed to Steins ([ADR-103](../adr/103-effect-labels.md) WD16). These are the labels a policy names and a `tolerated:` set grips, so a project must not need a plugin before it can write one — but Steins holds ecosystem labels outside its builtin set and supplies them through a plugin manifest, so the shared spelling is an intent, not yet an agreement |

`io.output.buffer`, `io.output.header` and the `failure.*` family are registered but unproduced in Ruby: they exist so a policy written against Steins parses here. `failure.*` is the odd one — in Steins it names a failure arm's *value provenance* rather than an effect, and it shares the registry only so prefix subsumption reaches it. Rigor produces no `failure.*` label and MUST NOT infer one; a bound that names it is satisfied vacuously.

Framework roots (`rails.*`) are contributed by the plugin that models the framework and are not part of the shipped file.

### Root ownership

A registry extension names an **owner**: a plugin id, the framework root a first-party plugin models, or nothing at all for the project's own configuration. Each added label MUST satisfy one of:

- its root is already known to the registry being extended — the extension is a leaf under an existing root; or
- its root equals the owner — the extension opens the owner's own root; or
- the owner is the project, which MAY open any root.

An added label that satisfies none of these is an error at extension time, not a diagnostic: an extender that cannot own the root it is opening has no honest way to proceed. An added label MUST also satisfy the label grammar.

A project extends the vocabulary with `effects.labels:` in `.rigor.yml`. Listing a label there is the vouching act — which is why the project alone may open any root — and it makes the spelling known everywhere a label is judged: `effect.unknown-label`, envelope bounds, attribution values and `tolerated:` alike. Its SHAPE is validated when the configuration loads; nothing else about it is.

A plugin extends it with `effect_labels:` in its manifest, under the owner its `effect_root:` names. The plugin layer is folded in **before** the project's, so a project may name a plugin-opened label in an envelope or in `tolerated:` without re-declaring the framework's vocabulary. A refusal drops only the refusing plugin's labels and surfaces as a warning on the effects report — one plugin overreaching MUST NOT un-name another's.

> **Implemented as of this writing** ([#387](https://github.com/rigortype/rigor/issues/387)): the plugin stratum. Whether a plugin may open the root it names is decided by `Rigor::Plugin::FirstParty` — is this a plugin the engine itself bundles — and a plugin that may not keeps the root named after its own id, with a warning. The manifest fields are specified in [`plugin.md`](../internal-spec/plugin.md) § Effect contributions.

### Vocabulary evolution

The registry carries a `vocabulary` version, and the rules that govern it follow from subsumption:

- **Adding a leaf is always safe and MUST NOT bump the version.** A recognised bound admits every descendant of its members, so a new `io.db.upsert` is already inside a declared `io.db`. No previously-accepted program becomes rejected.
- **Renaming or removing a label is breaking and MUST bump the version**, and the old spelling MUST be recorded in the registry's `retired` table with its replacement labels. A reader encountering a retired spelling knows what it became; a reader encountering an unrecognised spelling does not.
- A retired spelling is not known. It reads as an unknown label (§ Unknown labels) and degrades fail-open, with the retired table available to explain the degradation.
- The vocabulary version is part of the identity of any persisted effect record, so a version bump invalidates it rather than silently reinterpreting it.

## Effect summaries

> **Partly implemented as of this writing.** The proven lane, the exhaustiveness bit and the taint causes are computed by the collector of [#379](https://github.com/rigortype/rigor/issues/379) whenever the `effects:` block is present, and `rigor effects` prints them; how they are produced is [`effect-summaries.md`](../internal-spec/effect-summaries.md). Their **catalogued** origins come from the hand-audited `data/effects/core.yml` of [#380](https://github.com/rigortype/rigor/issues/380), with per-class default postures and argument-dependent narrowing; the catalogue's contract is analyzer-internal and is specified in [`effect-summaries.md`](../internal-spec/effect-summaries.md) § The catalogue. The **declared lane** has two producers: the project's `effects.attribution:` table ([#385](https://github.com/rigortype/rigor/issues/385), § Attribution), which colours calls into code Rigor never analysed, and the call-site envelope import of [#386](https://github.com/rigortype/rigor/issues/386) (§ The declared lane at call sites). The snapshot of [#381](https://github.com/rigortype/rigor/issues/381) commits them to a reviewed file; nothing is cached *between runs* until [#382](https://github.com/rigortype/rigor/issues/382).

An **effect summary** describes one method. It carries two lanes and one bit:

- the **proven** lane — a label set the analyzer established from catalogued origins, language constructs and project method bodies, transitively;
- the **declared** lane — a label set imported as an upper bound (`≤`) at call sites whose concrete callee is unknown but whose declared envelope is trusted;
- the **exhaustiveness bit** — false when any call the method makes could not be resolved.

**Diagnostics read the proven lane only.** A non-exhaustive summary renders as "these effects, and possibly more" and MUST NOT produce a finding on its own. This is the robustness principle applied to effects ([robustness-principle.md](robustness-principle.md)): as strict as proven, never as strict as feared.

**Declared labels travel call edges exactly as proven ones do**, monotone to the same fixpoint: a method's declared lane is what its own body claims joined with the declared lanes of everything it calls. A controller two hops above an attributed `Net::HTTP.get` therefore reads `≤ io.net.http` rather than only "and possibly more" — a claim that stopped at the method that made the call would answer no question anyone asks. The two lanes never mix: a declared label MUST NOT enter the proven lane at any distance, which is what keeps a claim from ever producing a finding.

**Rendering rule.** Where a summary is *printed* — the report, the snapshot, a diff — a declared label the same summary's proven lane already admits is dropped: the proven lane says strictly more, and `[io.net] ≤ [io.net.http]` reads as two facts where there is one. The rule applies to output only; the lanes themselves are kept as computed, because a further join has to see what was declared.

Every label in a summary carries an **origin** — the pair of the callee-or-construct it came from and the source that coloured it. Origins are line-free and are what policy discharge operates on; the flat label set is a projection of them.

### Taint causes

When the exhaustiveness bit is false, the summary records why, from this closed enum:

| Cause | Meaning |
| --- | --- |
| `dynamic-receiver` | the receiver's type was `Dynamic`, so the callee is unknown |
| `dynamic-send` | `send` / `public_send` with a non-literal selector |
| `method-missing` | dispatch reached a `method_missing` the analyzer does not model |
| `unresolved-self-call` | an implicit-self call with no project-known definition |
| `unresolved-super` | a `super` whose target the project's own ancestry does not define |
| `opaque-callable` | a block or proc the analyzer could not follow to a body |
| `unknown-ownership` | a mutating call whose receiver could not be proven frame-owned; the mutation is recorded as taint rather than as a proven `mutate` label |
| `plugin-attribution` | a label contributed by a source whose trust tier does not discharge |
| `template-not-analysed` | a render edge into a template that is not an effect unit |
| `collector-error` | the collector failed on this method and dropped its summary |
| `budget` | an inference budget cut the walk short |

The enum is closed. A new cause is a change to this document, not a producer's free choice.

> As of this writing `method-missing`, `template-not-analysed` and `budget` are reserved and unproduced; the other eight have producers (`plugin-attribution` since [#385](https://github.com/rigortype/rigor/issues/385), from the configured attribution table; `unresolved-super` since [#446](https://github.com/rigortype/rigor/issues/446)). Which shapes reach which cause is [`effect-summaries.md`](../internal-spec/effect-summaries.md) § Taints.

## Effect envelopes

> **Implemented as of this writing** ([#383](https://github.com/rigortype/rigor/issues/383), [#385](https://github.com/rigortype/rigor/issues/385), [#386](https://github.com/rigortype/rigor/issues/386)): both annotation spellings are read off the project's own RBS — its `signature_paths:` tree and the rbs-inline / plugin-synthesized signatures derived from its `.rb` files — the `.rigor.yml` convention spelling is read from `effects.envelopes:`, and all three are checked against each method's proven summary as `effect.envelope-exceeded`, and against each override's, as `effect.liskov-widened`, whenever `effects.check` is on (which it is by default under an `effects:` block). An envelope in RBS Rigor did not load from the project — rbs core, a gem's shipped signatures — is still never *checked*: the checked stratum is the project's own declarations ([ADR-103](../adr/103-effect-labels.md) WD6). It is read for one other purpose, which produces no finding: importing a `≤` bound at a call site (§ The declared lane at call sites).

An **effect envelope** is an author-declared upper bound on a method's effect labels, checked structurally against the method's *code* — dead code and block literals included. The RBS spelling follows the `RBS::Extended` conventions of [rbs-extended.md](rbs-extended.md):

```
envelope = "%a{" "rigor:v1:effect" WS label-list "}"
label-list = label { "," label }
```

- The directive head is separated from its payload by whitespace, as `assert` and `conforms-to` are; the payload is a comma-separated list of bare label tokens.
- The list MUST NOT be empty — `%a{rigor:v1:effect}` is malformed.
- There is no parenthesised comment form. RBS has real comments.

```rbs
class UserRepository
  %a{rigor:v1:effect io.db}
  def find: (Integer) -> User

  %a{pure}
  def slug: (String) -> String
end
```

`%a{pure}` is the **only** purity spelling. It reads as the empty envelope, tolerating `mutate.local` — a method may freely mutate objects its own frame allocated and never let escape. `rigor:v1:pure` is not implemented and is not part of the language; [control-flow-analysis.md](control-flow-analysis.md) § Purity policy names `%a{pure}`.

`%a{pure}` and `%a{rigor:v1:effect …}` on one declaration are contradictory; `pure` wins, and the conflict is reported through the existing `RBS::Extended` conflict channel.

An envelope on a supertype's method binds its overrides: an implementation may be purer than the bound it inherits, never less pure (§ Liskov inclusion).

### What the envelope binds

The bound is checked against the method's **proven** lane, transitively: its own body, the block literals it contains, and every project method it calls. A repository declared `%a{rigor:v1:effect io.db}` whose body calls a helper that calls `Net::HTTP` exceeds its envelope, because the envelope is a contract about what the method *does* and not about which lines spell it.

Three rules keep this from spending false-positive budget:

- **The declared lane and the exhaustiveness bit are not read.** A summary that could not resolve every call reads "these effects, and possibly more"; the *possibly* never produces a finding, and what was proven still does. This is "as strict as proven" ([robustness-principle.md](robustness-principle.md)) applied to the second dimension.
- **`mutate.local` is tolerated by every envelope**, `%a{pure}` included.
- **`effects.tolerated:` discharges per origin, not per label** (§ Discharge by policy). What the check compares against is the proven lane *minus every origin bundle the policy discharges*, so a policy silences a whole origin and never a label wherever it came from.

A proven label the bound does not admit is one `effect.envelope-exceeded` diagnostic per (method, label), **positioned at the Ruby `def`** rather than at the `.rbs` line — that is where the fix goes and where `# rigor:disable` is read. Where the method has no Ruby `def` (a synthesized `attr_*` accessor reached by class-level distribution) the position falls back to the class's own file. The message names the label, the shortest path to the origin that proves it, the author's own spelling of the bound, and where that bound was written; the identifier taxonomy and its severities are [diagnostic-policy.md](diagnostic-policy.md).

The check runs only when the configuration carries an `effects:` block **and** `effects.check` is not `false`; `effects.check` defaults to true under a present block. An `%a{pure}` in a project with no `effects:` block is inert — reading it as a checked contract on the quiet default surface would make a pre-existing annotation start failing ([ADR-50](../adr/50-release-engineering-and-stability-strategy.md) WD1).

### Class-level distribution

A class-level envelope distributes to every method of that Ruby class which discovery knows — reopenings, definitions in other files, and synthesised `attr_*` / `define_method` members included. It does **not** distribute to subclasses. On a module, it distributes to the module's own methods only. A method-level envelope wins over a distributed class-level one; nearest wins, and no `-except` syntax is needed.

### Envelopes by convention

An envelope may also be written in `.rigor.yml`, selecting classes by path or by namespace rather than naming one method:

```yaml
effects:
  envelopes:
    - match: "app/presenters/**/*.rb"     # presenters do not query
      effect: []
    - namespace: "Policies::*"
      effect: [mutate.local]
```

An entry MUST name **exactly one** of `match:` or `namespace:`, and MUST carry an `effect:` list — `effect: []` is the empty envelope, and a missing `effect:` is an error at load time, as is a malformed selector or label.

- `match:` selects a class when **any** file that defines one of its methods matches the glob. `File.fnmatch?` with `FNM_PATHNAME`, project-relative, so `**` is the only way across a directory boundary.
- `namespace:` selects a class by its fully-qualified name, matched segment by segment: `*` matches exactly one segment (`Presenters::*` selects `Presenters::User` and neither `Presenters::Admin::User` nor bare `Presenters`), `**` matches one or more (`Presenters::**` selects both), and a `*` inside a segment matches within it (`Api::V*`).

A selected class receives the entry's bound **exactly as a class-level annotation distributes it** — every method discovery knows, never a subclass unless it is selected on its own account. Precedence is nearest-wins, and configuration is the furthest thing from the method:

> per-method annotation **>** class-level annotation **>** configuration entry

Among configuration entries, the **first** one that selects a class binds it; a list is read top to bottom, and a later entry never silently overrides one written above it. A method therefore has at most one envelope, from exactly one source, and there is no merging of bounds. The diagnostic names that source as `.rigor.yml effects.envelopes[N]` and stays positioned at the Ruby `def`.

An unrecognised label in an entry's `effect:` degrades the whole entry to ⊤ and surfaces as `effect.unknown-label` positioned at `.rigor.yml`, exactly as it does for an annotation (§ Unknown labels).

### Liskov inclusion

An envelope is a contract about a method, and `class PgRepo < Repo` says a `PgRepo` is usable wherever a `Repo` is. A bound written on `Repo#find` therefore binds `PgRepo#find` too:

> An override MUST NOT escape the envelope written on the method it overrides. Implementations may be purer than the bound they inherit; they may never be less pure.

The envelope an override inherits is the one resolved for the **nearest ancestor whose own method key carries one**, by the same three strata and the same nearest-wins precedence a method's own envelope is resolved by. A bound written closer to the override is the more specific statement about it, and a grandparent's bound already binds the parent between them.

A violation is one `effect.liskov-widened` per (override, exceeding label), **positioned at the override's Ruby `def`**, and it arises in exactly one of two ways — never both, so one label never produces two diagnostics on one line:

- **The override declares no envelope of its own.** What it *does* is then what the inherited bound must admit, judged against the same lane `effect.envelope-exceeded` reads: the proven closure, discharged per policy, `mutate.local` tolerated, taint ignored.
- **The override declares its own envelope.** The comparison is then between the two authored bounds and is **proven-independent**: a declared bound wider than the inherited one is a Liskov violation in the declaration, whatever the body turns out to do. What the body does is already `effect.envelope-exceeded`'s question, asked against the override's own bound.

Two restrictions keep this inside the accepted construction:

- **Both sides are authored.** Nothing fires unless someone wrote an envelope on the overridden method; an override alone can never produce a finding. This is the same both-sides-authored construction the `def.override-*` family uses ([ADR-35](../adr/35-override-signature-compatibility.md)).
- **Nominal subclassing only.** A method of an included module is not overridden by the includer's own `def`: Ruby's ancestry puts the includer's method *ahead* of the module's rather than under it, and the substitutability argument that licenses the rule is the subclass one. Prepending, `extend`, and refinements are likewise out.

### The declared lane at call sites

A call whose concrete callee is unknown may still be bounded, because the thing it is called *on* declared what it does. Where that holds, the callee's bound joins the caller's **declared** lane as `≤` and never its proven one, under an origin naming the callee (§ Effect summaries).

**The carrier is nominal.** The lookup is by the receiver's *static* class as the analyzer projected it — for an implicit-self call, by the class the calling method is defined on — and it does not walk ancestors: a receiver typed `PgRepo` does not import `Repo#find`'s bound, because `PgRepo#find` is the definition that call reaches. Structural interfaces are not a carrier: RBS interface types erase to `Dynamic[top]` and have nothing to attach a bound to, so a call through an interface-typed receiver imports nothing ([structural-interfaces-and-object-shapes.md](structural-interfaces-and-object-shapes.md); the reading arrives with the structural carrier). The strata are the envelope strata plus one, nearest-first:

> per-method annotation **>** class-level annotation **>** `effects.envelopes:` entry **>** accepted signature

An **accepted signature** is an envelope carried by RBS the project did not write — a gem's shipped signatures, Rigor's bundled overlays — read from the built RBS environment rather than from the project's sources. It is never checked, because there is no body to check it against; what it does is state what a call into un-analysed code promises, which is the same trust already extended to that file's *types*.

An `effects.envelopes:` entry participates when it selects by `namespace:`. A `match:` entry does not: a path glob is a fact about where a class is *defined*, which the per-file collection window cannot answer. It still bounds the methods of the classes it selects, for the envelope check and for Liskov inclusion.

**Discharge.** A call site bounded this way is **exhaustive by envelope**: it contributes no taint, and it keeps its edges into the project definitions the closed world knows. That is [ADR-103](../adr/103-effect-labels.md) WD6's trust ladder — a project-authored envelope is contract-checked and Liskov-checked, and an accepted signature's types are already trusted — so a receiver the analyzer could only type as `Dynamic` is not "callee unknown" when the class it names has declared its bound. Two strata do **not** discharge, and neither imports here: `effects.attribution:` (§ Attribution) and a third-party plugin's manifest table, both of which are claims about code nothing has checked, and both of which keep their `plugin-attribution` taint.

An envelope that reads ⊤ imports nothing and discharges nothing. A tag that stopped bounding must not silently buy a call site its exhaustiveness back.

## Attribution

Gem methods have no bodies Rigor analyses, so someone must colour them. `effects.attribution:` is the project's own channel for that:

```yaml
effects:
  attribution:
    "Net::HTTP.get": [io.net.http]
    "Logger#info": [telemetry]
```

A key is a method key exactly as the symbol tables spell one — `Owner#instance_method` or `Owner.singleton_method` — and a key of any other shape is an error at load time. A call whose owner and selector match contributes the entry's labels to **the caller's declared lane**, under an origin of that key, and leaves a `plugin-attribution` taint at the site.

Three properties follow, and they are the whole point of the channel:

- **Attributed labels never enter the proven lane.** Diagnostics read the proven lane only, so no envelope can fire because of an attribution, whatever it claims.
- **Attribution never discharges the taint.** It is an unchecked claim about code the analyzer did not read, so the summary reads "declared this, and possibly more" ([ADR-103](../adr/103-effect-labels.md) WD6). A first-party plugin's framework-derived attribution is a different, higher tier and does discharge; a project's YAML table does not.
- **The claim propagates.** The declared lane travels call edges (§ Effect summaries), so every caller that reaches the attributed call reads the same `≤` bound — in the report and in the snapshot's `reach:` table, where `methods:` keeps each method's own claim so its diff stays attributable.
- **A label the registry does not know is reported, not rejected.** The attribution stands as written — the taint already says the reading is incomplete — and `effect.unknown-label` says the vocabulary cannot explain it.

### The plugin stratum

> **Implemented as of this writing** ([#387](https://github.com/rigortype/rigor/issues/387)): plugin attribution and plugin framework edges, with the whole Rails vocabulary of [ADR-103](../adr/103-effect-labels.md) WD10 built on them. The manifest surface is [`plugin.md`](../internal-spec/plugin.md) § Effect contributions; how the tables are compiled and consulted is [`effect-summaries.md`](../internal-spec/effect-summaries.md) § The plugin stratum.

A plugin that models a framework attributes calls into it, through `effect_attributions:` in its manifest or through a `%a{…}` annotation in the RBS it ships. Both land in the **declared** lane, exactly as `effects.attribution:` does. What differs is the taint, and it follows [ADR-103](../adr/103-effect-labels.md) WD6's ladder rather than the channel:

| Contributor | Taint at the site | Reading |
| --- | --- | --- |
| a **first-party bundled** plugin's `discharge: true` row, or an annotation in its shipped RBS | none | "this is what it does" — the accepted-signature tier |
| any other plugin, and the project's own YAML table | `plugin-attribution` | "declared this, and possibly more" |

A discharging row also **bounds the site**: `dynamic-receiver`, `unresolved-self-call` and the ownership judgment on a receiver mutation are all already answered by a trusted statement of what the call does, and a taint beside it would be one no annotation could ever clear. A row MAY nonetheless carry an explicit taint of `template-not-analysed` or `opaque-callable` — the two things a framework model can honestly not see.

A plugin also contributes **edges**: calls the framework makes that the syntax at the call site does not contain. `save` runs the class body's callbacks and validators, `Job.perform_now` runs `Job#perform`, `UserMailer.welcome(u)` runs `UserMailer#welcome`. What a plugin MUST NOT contribute is an edge from `perform_later` to `perform` (§ Effect summaries, deferred execution): the body runs in another process on another stack, so the caller's code does not contain it. The available strategies are a closed enum with no spelling for it.

A plugin's **transport** row MAY be narrowed by a project fact it reads: an ActiveJob enqueue is bare `io` argument-blind, an `io.db.write` under a declared Solid Queue adapter and an `io.net` under Sidekiq. This is the configuration-level twin of argument-dependent narrowing, and an unread or per-environment declaration keeps the honest upper bound.

## Discharge by policy

`effects.tolerated:` lists the labels a project has decided not to act on. It is applied when a difference or a bound is **judged**, never when a fact is recorded, and it operates **per origin**:

> A bundle is discharged when **any** of its labels is tolerated.

An origin is one callee or one construct, and its labels are what that one thing does — so tolerating what an origin was *for* frees the transport it came with. `Logger#info` is `io` + `telemetry` in one bundle: `tolerated: [telemetry]` discharges it whole, because the `io` in that bundle *is* the logging. A `File.read` in the same body is a different origin with a different bundle, and its `io.fs.read` still counts. A label that arrives through both a discharged and an undischarged origin survives, because the undischarged one proves it on its own.

Four invariants govern the policy, and each is a separate commitment:

1. **The record is undischarged.** The effect snapshot holds what the analyzer proved; `rigor effects update` writes the same bytes whatever the policy says.
2. **The policy is in one place.** `effects.tolerated:` in `.rigor.yml`, not scattered across per-site suppressions.
3. **The audit switch exists.** `--no-tolerated-effects`, on `rigor check` and on the snapshot verbs, runs the same judgment with an empty tolerated set, so what the policy hides can always be seen. It changes the judgment and nothing else — not collection, not the record, not the cache identity.
4. **Emission uses undischarged sets.** A summary written out as an annotation (`sig-gen`) must state what the code does, never what the project has agreed to ignore.

For the envelope check the discharge applies transitively: what a bound is compared against is the proven closure minus every discharged origin bundle, computed at the origin's own method and propagated along call edges like the proven lane itself. For a snapshot difference, an **added** label is tolerated exactly when every origin introducing it is discharged; a **removal** is judged by label, because the origin that produced it no longer exists to consult.

## Unknown labels

> **Implemented as of this writing** ([#384](https://github.com/rigortype/rigor/issues/384), [#385](https://github.com/rigortype/rigor/issues/385)): the ⊤ degradation, the intent-gated `effect.unknown-label` at the declaration (RBS and rbs-inline) and at every `.rigor.yml` label surface — `effects.tolerated:`, `effects.envelopes[].effect`, `effects.attribution:` values and `effects.labels:` — and the `effect.annotations-unchecked` residual.

A well-formed label the registry does not recognise MUST make **the whole tag read as ⊤** — never the recognised subset of it.

This is fail-open, and it is the only safe reading. A tag whose author meant `io.db` but wrote `io.bd` describes a method the analyzer cannot bound; narrowing the bound to the labels it happened to recognise would turn a typo into findings on correct code. Widening to ⊤ suppresses findings instead, which is the direction false positives are budgeted in ([ADR-5](../adr/5-robustness-principle.md)).

The same rule applies to a retired spelling and to a label a plugin was expected to register but did not.

The degradation is paired with a diagnostic, because a bound that silently stopped bounding is exactly the kind of thing a fail-open rule must not be allowed to hide. `effect.unknown-label` reports it **at the declaration** — the `.rbs` line, the `.rb` line for an rbs-inline annotation, or `.rigor.yml` for a label written in configuration — naming the nearest recognised spelling where there is one, and saying that the declaration now bounds nothing. It never changes a bound, and it rides the same `effects.check` switch as `effect.envelope-exceeded`: opting into envelope enforcement is what turns on the diagnostic that says enforcement stopped.

It fires only where **label intent is evident**, from any one of four signals: the spelling is within a small edit distance of a recognised label; another member of the same list is recognised; the token carries two or more dot-separated segments; or the registry's retired table names it (in which case the replacement is named instead of a guess). A lone far-off word (`%a{rigor:v1:effect database}`) matches none of them and stays silent everywhere — a vocabulary is open by construction (`effects.labels:`, a plugin's own root), so a bare word nothing resembles is as likely to be a label this project has not registered as it is a misspelling, and reporting both would put findings on correct-by-intent code. The silence is about the diagnostic only: the tag reads ⊤ either way.

The identifier is shared with Steins, alongside `effect.liskov-widened`; the identifier taxonomy and the severities are [diagnostic-policy.md](diagnostic-policy.md).

**Annotations without an `effects:` block.** An effect annotation never turns collection on — that would let one line in one signature file make every run of the project more expensive. It is equally never silently inert: a project whose own signatures carry `%a{pure}` / `%a{rigor:v1:effect …}` while `.rigor.yml` carries no `effects:` block receives one `effect.annotations-unchecked` `:info` per run, positioned at the first such annotation. `effects: {}` and `effects: {check: false}` are both deliberate answers and silence it.

## The effect snapshot

> **Implemented as of this writing** ([#381](https://github.com/rigortype/rigor/issues/381)): `rigor effects update` / `check` / `diff` / `explain`, `effects.snapshot.{path,reach,gate}` and a minimal `effects.tolerated:`. The file's layout, its omission rule, the diff categories and the gate semantics are analyzer-internal and are specified in [`effect-summaries.md`](../internal-spec/effect-summaries.md) § The snapshot document. Entry-point **presets** are named by the plugin that models a framework, through the `effect_entry_points:` manifest field ([#387](https://github.com/rigortype/rigor/issues/387)), and adopted by name in `effects.snapshot.reach:`. rigor-railties ships `rails` (controller actions, job `perform`, mailer actions, channel callbacks) and each Rails component plugin ships its own slice. Because a plugin loads *from* the configuration being validated, a `reach:` name is checked for SHAPE at configuration load and for EXISTENCE when the snapshot is built, which is the first point at which the registered set is complete.

The primary way an effect footprint is validated is not an envelope but a committed record: `.rigor-effects.yml`, holding each method's *direct* summary and the transitive reach at declared entry points, whose diff is reviewed and whose drift a CI gate reports. Its header carries the vocabulary version defined above, so a vocabulary bump expires the record rather than reinterpreting it. The snapshot emits no diagnostic and never enters `rigor check`'s stream.

The record is **undischarged**: it holds the sets the analyzer proved, and `effects.tolerated:` applies when a difference is *judged* (§ Discharge by policy), never when the record is written. Writing the file with the policy applied would make it a function of policy, and a policy change indistinguishable from a change in what the code does.
