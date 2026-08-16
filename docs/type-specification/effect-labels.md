# Effect Labels

Effect labels are Rigor's second dimension beside types: what a method *does*, as opposed to what it returns. This document is normative for the label language — the grammar, the subsumption relation, the registry that recognises spellings, the envelope syntax that bounds them, and the shape of an effect summary. Collection, propagation and the effect snapshot are analyzer-internal and are specified in [`docs/internal-spec/`](../internal-spec/README.md); the rationale is [ADR-103](../adr/103-effect-labels.md), and the research behind it is [`docs/design/20260816-effect-labels.md`](../design/20260816-effect-labels.md).

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

> **Not implemented as of this writing.** The lanes, the exhaustiveness bit and the taint causes are normative here; the collector that produces them lands with [#379](https://github.com/rigortype/rigor/issues/379), and the persisted snapshot with [#381](https://github.com/rigortype/rigor/issues/381). Nothing in Rigor computes an effect summary today.

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

## Effect envelopes

> **Not implemented as of this writing.** The grammar below binds the reader that lands with [#383](https://github.com/rigortype/rigor/issues/383); no Rigor version reads `%a{rigor:v1:effect …}` or checks `%a{pure}` as an envelope today.

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

### Class-level distribution

A class-level envelope distributes to every method of that Ruby class which discovery knows — reopenings, definitions in other files, and synthesised `attr_*` / `define_method` members included. It does **not** distribute to subclasses. On a module, it distributes to the module's own methods only. A method-level envelope wins over a distributed class-level one; nearest wins, and no `-except` syntax is needed.

## Unknown labels

A well-formed label the registry does not recognise MUST make **the whole tag read as ⊤** — never the recognised subset of it.

This is fail-open, and it is the only safe reading. A tag whose author meant `io.db` but wrote `io.bd` describes a method the analyzer cannot bound; narrowing the bound to the labels it happened to recognise would turn a typo into findings on correct code. Widening to ⊤ suppresses findings instead, which is the direction false positives are budgeted in ([ADR-5](../adr/5-robustness-principle.md)).

The same rule applies to a retired spelling and to a label a plugin was expected to register but did not.

> **Not implemented as of this writing.** The paired vocabulary diagnostic `effect.unknown-label` — which surfaces the degradation where label intent is evident, with a nearest-known-label suggestion — lands with [#384](https://github.com/rigortype/rigor/issues/384). Its identifier is reserved jointly with Steins, alongside `effect.envelope-exceeded` and `effect.liskov-widened`; the identifier taxonomy is [diagnostic-policy.md](diagnostic-policy.md).

## The effect snapshot

> **Not implemented as of this writing.** The snapshot file, its format and the `rigor effects` verbs land with [#381](https://github.com/rigortype/rigor/issues/381).

The primary way an effect footprint is validated is not an envelope but a committed record: `.rigor-effects.yml`, holding each method's *direct* summary and the transitive reach at declared entry points, whose diff is reviewed and whose drift a CI gate reports. Its header carries the vocabulary version defined above, so a vocabulary bump expires the record rather than reinterpreting it. The snapshot emits no diagnostic and never enters `rigor check`'s stream.
