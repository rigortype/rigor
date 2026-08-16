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
| Shared base | Steins' v1 set verbatim: `exit`, `ffi`, `global.read`, `global.write`, `io`, `io.db`, `io.fs`, `io.fs.read`, `io.fs.write`, `io.input`, `io.ipc`, `io.net`, `io.net.http`, `io.output`, `io.output.buffer`, `io.output.header`, `io.output.stdout`, `io.output.stderr`, `io.process`, `io.signal`, `mutate`, `mutate.local`, `nondet`, `nondet.random`, `nondet.time` | Steins and Rigor jointly; a divergence is raised upstream before it ships |
| Ruby leaves | `mutate.self` (self's state), `mutate.instance` (a receiver that is neither self nor frame-owned), `mutate.static` | Rigor |
| Proposed shared core leaves | `io.db.read`, `io.db.write`, `io.db.transaction` | Rigor, pending adoption by Steins |
| Application meaning | `telemetry`, `email.send`, `job.enqueue`, `cache.read`, `cache.write` | shared; these are the labels a policy names and a `tolerated:` set grips, so they MUST spell the same in both analyzers |

`io.output.buffer` and `io.output.header` are registered but unproduced in Ruby: they exist so a policy written against Steins parses here.

Framework roots (`rails.*`) are contributed by the plugin that models the framework and are not part of the shipped file.

### Root ownership

A registry extension names an **owner**: a plugin id, the framework root a first-party plugin models, or nothing at all for the project's own configuration. Each added label MUST satisfy one of:

- its root is already known to the registry being extended — the extension is a leaf under an existing root; or
- its root equals the owner — the extension opens the owner's own root; or
- the owner is the project, which MAY open any root.

An added label that satisfies none of these is an error at extension time, not a diagnostic: an extender that cannot own the root it is opening has no honest way to proceed. An added label MUST also satisfy the label grammar.

### Vocabulary evolution

The registry carries a `vocabulary` version, and the rules that govern it follow from subsumption:

- **Adding a leaf is always safe and MUST NOT bump the version.** A recognised bound admits every descendant of its members, so a new `io.db.upsert` is already inside a declared `io.db`. No previously-accepted program becomes rejected.
- **Renaming or removing a label is breaking and MUST bump the version**, and the old spelling MUST be recorded in the registry's `retired` table with its replacement labels. A reader encountering a retired spelling knows what it became; a reader encountering an unrecognised spelling does not.
- A retired spelling is not known. It reads as an unknown label (§ Unknown labels) and degrades fail-open, with the retired table available to explain the degradation.
- The vocabulary version is part of the identity of any persisted effect record, so a version bump invalidates it rather than silently reinterpreting it.

## Effect summaries

> **Partly implemented as of this writing.** The proven lane, the exhaustiveness bit and the taint causes are computed by the collector of [#379](https://github.com/rigortype/rigor/issues/379) whenever the `effects:` block is present, and `rigor effects` prints them; how they are produced is [`effect-summaries.md`](../internal-spec/effect-summaries.md). Their **catalogued** origins come from the hand-audited `data/effects/core.yml` of [#380](https://github.com/rigortype/rigor/issues/380), with per-class default postures and argument-dependent narrowing; the catalogue's contract is analyzer-internal and is specified in [`effect-summaries.md`](../internal-spec/effect-summaries.md) § The catalogue. The **declared lane is always empty**: envelopes are read and checked at the declaration ([#383](https://github.com/rigortype/rigor/issues/383), § Effect envelopes), but importing a trusted envelope as a `≤` bound at a *call site* whose callee is unknown lands with [#386](https://github.com/rigortype/rigor/issues/386). The snapshot of [#381](https://github.com/rigortype/rigor/issues/381) commits them to a reviewed file; nothing is cached *between runs* until [#382](https://github.com/rigortype/rigor/issues/382).

An **effect summary** describes one method. It carries two lanes and one bit:

- the **proven** lane — a label set the analyzer established from catalogued origins, language constructs and project method bodies, transitively;
- the **declared** lane — a label set imported as an upper bound (`≤`) at call sites whose concrete callee is unknown but whose declared envelope is trusted;
- the **exhaustiveness bit** — false when any call the method makes could not be resolved.

**Diagnostics read the proven lane only.** A non-exhaustive summary renders as "these effects, and possibly more" and MUST NOT produce a finding on its own. This is the robustness principle applied to effects ([robustness-principle.md](robustness-principle.md)): as strict as proven, never as strict as feared.

Every label in a summary carries an **origin** — the pair of the callee-or-construct it came from and the source that coloured it. Origins are line-free and are what policy discharge operates on; the flat label set is a projection of them.

### Taint causes

When the exhaustiveness bit is false, the summary records why, from this closed enum:

| Cause | Meaning |
| --- | --- |
| `dynamic-receiver` | the receiver's type was `Dynamic`, so the callee is unknown |
| `dynamic-send` | `send` / `public_send` with a non-literal selector |
| `method-missing` | dispatch reached a `method_missing` the analyzer does not model |
| `unresolved-self-call` | an implicit-self call with no project-known definition |
| `opaque-callable` | a block or proc the analyzer could not follow to a body |
| `unknown-ownership` | a mutating call whose receiver could not be proven frame-owned; the mutation is recorded as taint rather than as a proven `mutate` label |
| `plugin-attribution` | a label contributed by a source whose trust tier does not discharge |
| `template-not-analysed` | a render edge into a template that is not an effect unit |
| `collector-error` | the collector failed on this method and dropped its summary |
| `budget` | an inference budget cut the walk short |

The enum is closed. A new cause is a change to this document, not a producer's free choice.

> As of this writing `method-missing`, `plugin-attribution`, `template-not-analysed` and `budget` are reserved and unproduced; the other six have producers. Which shapes reach which cause is [`effect-summaries.md`](../internal-spec/effect-summaries.md) § Taints.

## Effect envelopes

> **Implemented as of this writing** ([#383](https://github.com/rigortype/rigor/issues/383)): both spellings are read off the project's own RBS — its `signature_paths:` tree and the rbs-inline / plugin-synthesized signatures derived from its `.rb` files — and checked against each method's proven summary as `effect.envelope-exceeded` whenever `effects.check` is on (which it is by default under an `effects:` block). Two neighbouring readings are not: an envelope declared on a *supertype* does not yet bind its overrides (`effect.liskov-widened`, [#386](https://github.com/rigortype/rigor/issues/386)), and an envelope written in `.rigor.yml` by path or namespace ([#385](https://github.com/rigortype/rigor/issues/385)) is accepted by the schema and not read. An envelope in RBS Rigor did not load from the project — rbs core, a gem's shipped signatures — is deliberately never read: the checked stratum is the project's own declarations ([ADR-103](../adr/103-effect-labels.md) WD6).

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

An envelope on a supertype's method binds its overrides: an implementation may be purer than the bound it inherits, never less pure.

### What the envelope binds

The bound is checked against the method's **proven** lane, transitively: its own body, the block literals it contains, and every project method it calls. A repository declared `%a{rigor:v1:effect io.db}` whose body calls a helper that calls `Net::HTTP` exceeds its envelope, because the envelope is a contract about what the method *does* and not about which lines spell it.

Three rules keep this from spending false-positive budget:

- **The declared lane and the exhaustiveness bit are not read.** A summary that could not resolve every call reads "these effects, and possibly more"; the *possibly* never produces a finding, and what was proven still does. This is "as strict as proven" ([robustness-principle.md](robustness-principle.md)) applied to the second dimension.
- **`mutate.local` is tolerated by every envelope**, `%a{pure}` included.
- **`effects.tolerated:` is not consulted.** That list is a judgment-time policy for the snapshot's diff (§ The effect snapshot); an envelope is a contract, and discharging a contract by policy is a separate decision ([#385](https://github.com/rigortype/rigor/issues/385)).

A proven label the bound does not admit is one `effect.envelope-exceeded` diagnostic per (method, label), **positioned at the Ruby `def`** rather than at the `.rbs` line — that is where the fix goes and where `# rigor:disable` is read. Where the method has no Ruby `def` (a synthesized `attr_*` accessor reached by class-level distribution) the position falls back to the class's own file. The message names the label, the shortest path to the origin that proves it, the author's own spelling of the bound, and where that bound was written; the identifier taxonomy and its severities are [diagnostic-policy.md](diagnostic-policy.md).

The check runs only when the configuration carries an `effects:` block **and** `effects.check` is not `false`; `effects.check` defaults to true under a present block. An `%a{pure}` in a project with no `effects:` block is inert — reading it as a checked contract on the quiet default surface would make a pre-existing annotation start failing ([ADR-50](../adr/50-release-engineering-and-stability-strategy.md) WD1).

### Class-level distribution

A class-level envelope distributes to every method of that Ruby class which discovery knows — reopenings, definitions in other files, and synthesised `attr_*` / `define_method` members included. It does **not** distribute to subclasses. On a module, it distributes to the module's own methods only. A method-level envelope wins over a distributed class-level one; nearest wins, and no `-except` syntax is needed.

## Unknown labels

> **Implemented as of this writing** ([#384](https://github.com/rigortype/rigor/issues/384)): the ⊤ degradation, the intent-gated `effect.unknown-label` at the declaration (RBS, rbs-inline and `effects.tolerated:`), and the `effect.annotations-unchecked` residual. The remaining `.rigor.yml` label surfaces — `effects.envelopes[].effect`, `effects.attribution:` and `effects.labels:` — are accepted by the schema and not yet read, so nothing judges their members either ([#385](https://github.com/rigortype/rigor/issues/385)).

A well-formed label the registry does not recognise MUST make **the whole tag read as ⊤** — never the recognised subset of it.

This is fail-open, and it is the only safe reading. A tag whose author meant `io.db` but wrote `io.bd` describes a method the analyzer cannot bound; narrowing the bound to the labels it happened to recognise would turn a typo into findings on correct code. Widening to ⊤ suppresses findings instead, which is the direction false positives are budgeted in ([ADR-5](../adr/5-robustness-principle.md)).

The same rule applies to a retired spelling and to a label a plugin was expected to register but did not.

The degradation is paired with a diagnostic, because a bound that silently stopped bounding is exactly the kind of thing a fail-open rule must not be allowed to hide. `effect.unknown-label` reports it **at the declaration** — the `.rbs` line, the `.rb` line for an rbs-inline annotation, or `.rigor.yml` for a label written in configuration — naming the nearest recognised spelling where there is one, and saying that the declaration now bounds nothing. It never changes a bound, and it rides the same `effects.check` switch as `effect.envelope-exceeded`: opting into envelope enforcement is what turns on the diagnostic that says enforcement stopped.

It fires only where **label intent is evident**, from any one of four signals: the spelling is within a small edit distance of a recognised label; another member of the same list is recognised; the token carries two or more dot-separated segments; or the registry's retired table names it (in which case the replacement is named instead of a guess). A lone far-off word (`%a{rigor:v1:effect database}`) matches none of them and stays silent everywhere — a vocabulary is open by construction (`effects.labels:`, a plugin's own root), so a bare word nothing resembles is as likely to be a label this project has not registered as it is a misspelling, and reporting both would put findings on correct-by-intent code. The silence is about the diagnostic only: the tag reads ⊤ either way.

The identifier is shared with Steins, alongside `effect.liskov-widened`; the identifier taxonomy and the severities are [diagnostic-policy.md](diagnostic-policy.md).

**Annotations without an `effects:` block.** An effect annotation never turns collection on — that would let one line in one signature file make every run of the project more expensive. It is equally never silently inert: a project whose own signatures carry `%a{pure}` / `%a{rigor:v1:effect …}` while `.rigor.yml` carries no `effects:` block receives one `effect.annotations-unchecked` `:info` per run, positioned at the first such annotation. `effects: {}` and `effects: {check: false}` are both deliberate answers and silence it.

## The effect snapshot

> **Implemented as of this writing** ([#381](https://github.com/rigortype/rigor/issues/381)): `rigor effects update` / `check` / `diff` / `explain`, `effects.snapshot.{path,reach,gate}` and a minimal `effects.tolerated:`. The file's layout, its omission rule, the diff categories and the gate semantics are analyzer-internal and are specified in [`effect-summaries.md`](../internal-spec/effect-summaries.md) § The snapshot document. Entry-point **presets** are named here but none ships: the plugin manifest field that registers them lands with the Rails slice.

The primary way an effect footprint is validated is not an envelope but a committed record: `.rigor-effects.yml`, holding each method's *direct* summary and the transitive reach at declared entry points, whose diff is reviewed and whose drift a CI gate reports. Its header carries the vocabulary version defined above, so a vocabulary bump expires the record rather than reinterpreting it. The snapshot emits no diagnostic and never enters `rigor check`'s stream.

The record is **undischarged**: it holds the sets the analyzer proved, and `effects.tolerated:` applies when a difference is *judged*, never when the record is written. Writing the file with the policy applied would make it a function of policy, and a policy change indistinguishable from a change in what the code does.
