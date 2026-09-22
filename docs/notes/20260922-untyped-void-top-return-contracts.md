# `untyped`, `void`, `top` as return contracts — what the `sig/` audit taught (2026-09-22)

Status: research note, no design commitments. Observations taken against Rigor 0.3.9 at `master`
`75c5ae91` (post [#1169](https://github.com/rigortype/rigor/pull/1169)), rbs 4.2.0, Ruby 4.0.5.

This note started as a mechanical question — "which `-> untyped` returns under `sig/` should have
been `-> void`?" — and turned into a small type-theoretic exercise, because the answer depends on
what each of the three types *asserts* rather than on what values they *admit*. The two results:
[#1169](https://github.com/rigortype/rigor/pull/1169) changed the two genuinely void-shaped
declarations, and the remaining `untyped` returns split into four provenance classes, only one of
which is `untyped` by necessity.

## The question

Every method declaration under `sig/` whose return is `untyped` or `untyped?` was listed and checked
against every call site in `lib/`, `spec/`, `plugins/`, `examples/`, `exe/`, and `apps/`:

```sh
# 79 at 02f3e27c (pre-#1169); 77 at 75c5ae91. A raw `grep -- '-> untyped'` says 86: the extra
# seven are one comment and six proc / block types in parameter position, not method returns.
git grep -E '^ *def [^#]*-> untyped\??$' <sha> -- sig/ | wc -l
grep -rn --include='*.rb' -E "(^|[^a-zA-Z0-9_])<method>\b" lib/ exe/ plugins/ spec/ | grep -v 'def '
```

Two methods had (a) every call site discarding the result and (b) a result that is a
last-expression artefact rather than a documented value: `Rigor::Plugin.unregister!` (returns
whatever `Mutex#synchronize` leaves — the cleared gem-registrations `Hash` or `Hash#delete`'s result) and
`Rigor::Plugin::Base.node_file_context` (returns the assigned `Proc`). Both became `-> void`.

Everything else returns a value some caller consumes. So the void question closed at two. The
interesting part is why *those* two, and why the rest are still `untyped`.

## Three types, three different claims

The temptation is to rank `untyped`, `top`, `void` on a single "how much do I know" axis. They are
not on one axis. Each makes a different *kind* of claim about a return position.

### `untyped` — a claim about the checker, not the value

`untyped` is RBS's dynamic type. In the gradual-typing reading Rigor adopts
([special-types.md](../type-specification/special-types.md) § `untyped` and `Dynamic[T]`), it is
consistent with every type in both directions:

```text
consistent(untyped, T)   consistent(T, untyped)
```

Consistency is not subtyping. Assignment in either direction between `untyped` and `T` is admitted
not because `untyped` sits at the top or the bottom of the lattice, but because the *consistency*
relation is lenient: the checker agrees to stop asking. The subtyping judgement is a different
relation and does not become lenient — `relations-and-certainty.md` has `Dynamic[T]` witness
subtyping through its static facet, so `Dynamic[top] <: String` is simply false, and what lets a
dynamic value flow into a `String` slot is `consistent(Dynamic[top], String)`, not a subtype edge.
Rigor's internal form makes this visible — `untyped` is `Dynamic[top]`, a wrapper that records
"this crossed an unchecked boundary" around a static facet that happens to be `top`.

As a return contract, therefore, `-> untyped` says: **"a value comes back, and the checker will
not object to anything you do with it."** It is always *sound* — every Ruby value inhabits it —
but it is the weakest honest claim, and it is a *permission*: `x = m(); x.call` type-checks.

RBS's own early rename from `any` to `untyped` (pre-1.0; `references/rbs/docs/syntax.md` still
records `any` as the former spelling) was precisely about this. `any` reads as an existential
("some type"); `untyped` reads as a checker state ("not checked"). Rigor's rbs 4.2 no longer
accepts `any` at all — `RBS::Parser` reads it as a type-alias reference and `rbs validate` fails
with `NoTypeFoundError` — so the question "should this be `any` instead?" has no answer other than
"they were never different types."

### `top` — a claim about the value, with the checker still on

`top` is the greatest type: every value inhabits it, and that is *all* that is known. Unlike
`untyped`, it is a real lattice element and subtyping is not lenient around it:

```text
T <: top   for every T
top <: T   only when T = top
```

So `-> top` says: **"a value comes back; you may hold it, but you may not send it anything until
you have narrowed it."** This is TypeScript's `unknown`, and the spec assigns it exactly that
role. It is the honest type for a value the author cannot describe but does expect the caller to
inspect.

Two things make `top` a poor fit for the audited returns today. First, none of the audited methods
returns a value the caller is *meant* to narrow — they return either a specific thing whose class
merely lacks a `sig/`, or nothing the caller wants at all. Second, and decisive for practice: the
guard diagnostic that gives `top` its teeth, `static.value-use.top`, is reserved with **no
implementation and no ADR** ([diagnostic-policy.md](../type-specification/diagnostic-policy.md)).
Today an unguarded call on `top` is silently accepted, so `-> top` would carry the right theory
and the same enforcement as `-> untyped`.

### `void` — a claim about the *position*, not the value

`void` is not a value type. Rigor's spec calls it a "result marker for expressions whose return
value should not be used"; RBS's own docs say `void`, `boolish` and `top` are "all equivalent for
the type system; they are all top type", and Rigor's translator implements exactly that
(`Bases::Void => :translate_top`).

So set-theoretically `void` *is* `top` — the same inhabitants. The difference is a side channel:
ADR-100's `void_origins` table records, at the point where `void → top` widens, that this `top`
was born from an author's `-> void`, and `static.value-use.void` fires when that provenance
reaches a value position (assignment RHS, call receiver, call argument).

Formally this is a **use-count restriction layered on `top`**, carried in a side-table rather
than in the type: it constrains how many times the result may be *consumed* (zero), not what it
is. (It is not linear or affine typing — those permit exactly one or at most one use; `void`
permits none — and ADR-100 deliberately made it a side-table rather than a carrier type.) That is
why it is the correct spelling for `unregister!` and `node_file_context`: the truthful
set-theoretic claim about their return is "anything" (the gem-registrations `Hash`, the `Proc`,
whatever `delete` gave back), and the truthful *contract* claim is "and do not read it."

It also explains why `-> nil` was the wrong alternative. `nil` is a singleton value type; `-> nil`
is a positive claim that the body produces `nil`. For `dynamic_return` and `narrowing_facts`,
whose bodies end in a literal `nil`, that claim is true and the sibling `-> nil` sigs are right.
For `node_file_context`, whose body ends in `@node_file_context_block = block`, `-> nil` would be
*false* — a type that the runtime value does not inhabit. `void` needs no such lie.

A last consequence worth recording: because `void` *is* `top` in the lattice, `bot <: void`
holds trivially — an always-raising body satisfies a `void` contract — while `void <: bot` does
not, exactly as the spec states.

### Summary table

| Return | Set of inhabitants | Claim | Enforced in 0.3.9? |
| --- | --- | --- | --- |
| `untyped` | all values | checker off; caller may do anything | n/a (it is the absence of a check) |
| `top` | all values | caller must narrow before sending | no (`static.value-use.top` reserved) |
| `void` | all values (as `top`) | caller must not consume | yes (`static.value-use.void`, behind `use-of-void-value`) |
| `nil` | `{nil}` | body yields `nil` | yes (ordinary nominal check) |
| `bot` | `∅` | body never returns normally | yes (flow) |

The only row whose enforcement discriminates among the audited methods is `void`, which is why
the PR stopped there.

## Why the remaining 77 are still `untyped`

If `untyped` is the weakest claim, are the other 77 declarations unavoidable? Mostly not. They
fall into four provenance classes; only the last is `untyped` by necessity.

### A. Expressible today, unwritten — including the generic case

Some `untyped` returns have a precise type already available in the environment.

The clearest case is **parametric passthrough**. `Rigor::Testing.dump_type(value)` and
`assert_type(expected, value)` are documented as "returns `value` unchanged at runtime". The
honest type is not "some value" but "*that* value":

```rbs
def self.dump_type: [A] (A value) -> A
def self.assert_type: [A] (String expected, A value) -> A
```

This is ordinary parametric polymorphism: the return type is *determined by* an argument type, so a
type variable expresses a dependency `untyped` throws away. Under `-> untyped`,
`x = dump_type(some_string); x.upcase` leaves `x` as `Dynamic[top]` and the downstream chain
untyped; under `[A] … -> A`, `x` keeps `String`. The fixture helpers that exist to *probe* types
are exactly where losing the type is costly. [#1171](https://github.com/rigortype/rigor/pull/1171)
landed this; its review measured the binding directly (`compose_arg_type_vars` in
`rbs_dispatch.rb` binds `A` to the argument type verbatim, an unbound `A` translates back to
`Dynamic[top]`, and a `bot` argument yields `bot`) and found one reach limit: the binding needs a
scoped dispatch, so a bare `dump_type(x)` after `include Rigor::Testing` in a discovered-only
class still takes the ancestor fallback and answers `Dynamic[top]`, as it did before.

The other members of this class are returns whose classes are already nameable in `sig/` or in
bundled RBS, and where the implementation comments name the type outright:

| Method | Currently | Implementation says |
| --- | --- | --- |
| `Reflection.instance_method_definition` / `singleton_method_definition` | `untyped` | `RBS::Definition::Method` or nil |
| `Reflection.instance_definition` / `singleton_definition` | `untyped` | `RBS::Definition` or nil |
| `Environment#instance_definition` / `singleton_definition` | `untyped?` | `RBS::Definition` or nil |
| `Scope#user_def_for` / `singleton_def_for` / `top_level_def_for` / `bindable_top_level_def_for` | `untyped?` | `Prism::DefNode` or nil |
| `Source::NodeLocator.at_position` / `at_offset` (class and instance) | `untyped?` | `Prism::Node` or nil |
| `Plugin::Registry#find` | `untyped` | `Plugin::Base` or nil |
| `Plugin::Base.node_file_context_block` | `untyped` | the declared `Proc` or nil |
| `Plugin::Base#dynamic_return_type` | `untyped` | `Rigor::Type` or nil |
| `Environment::RbsLoader#each_known_class_name` | `untyped` | `void` with block; `Enumerator[String, void]` without |
| `SigGen::SkipReasonCatalog::Entry#id` / `summary` / `explanation` / `next_step` | `untyped` | `String` (every `Data` field is a string literal) |
| `Plugin::Manifest#consumes` | `untyped` | `Array[Manifest::Consumption]` (`Consumption` is already in `sig/`) |

`Prism::Node` is usable in `sig/` (`sig/prism_node_children.rbs` already declares against it), and
`::RBS::Definition` comes from the `rbs` gem's own signatures.

### B. Blocked on an unsigned namespace

A second group returns an object whose *class* has no declaration under `sig/`. Naming it would
raise `RBS::UnknownTypeName` at load, so `untyped` is a placeholder rather than a claim. The sig
comments say so explicitly (`sig/rigor.rbs` on `cache_store` and `effect_table`):

- `Cache::*` — `Plugin::IoBoundary#cache_descriptor`, `Plugin::Base#plugin_entry`,
  `Runner#cache_store`.
- `Effects::*` — `Runner#effect_table`, `#effect_collection`, `#effect_sources`,
  `#effect_plugin_facts`, `#effect_collections_by_path`.
- `Analysis::ProjectScan` — `Runner#prepare_project_scan`.
- `Plugin::ProtocolContract` — `Manifest#protocol_contracts`, `Base#protocol_contracts`.

Generics do not help here; the fix is to extend `sig/` coverage into those namespaces, which is
the ordinary incremental sig-coverage work and has its own review boundary under ADR-107.

### C. `sig-gen` inference gaps

`sig/` is seeded by `rigor sig-gen`, and a method whose body widens to `Dynamic[top]` is emitted
as `sig.skipped.untyped-return`. Several manifest readers carry the comment "an `attr_reader` over
an ivar assigned in `initialize` from a parameter the manifest validates but does not type, so
inference reaches `untyped` where the contract is `Array[String]`" ([#392]). The honest fix is in
the engine, not the sig; hand-editing these is allowed under the type-authoring contract's review
boundary but does not close the gap `sig-gen` recorded.

### D. Genuinely `untyped`

Plugin-supplied opaque values: `Plugin::Base#read_fact`, `#producer_value`, `#producer_error`,
`FactStore#read`, `Manifest#config_schema`, `Cache.fetch`'s `loader:` / `store:`. These carry a
value whose type is chosen by a third party at runtime. They *could* be made generic by
parameterising the fact-store interface, but the parameter would be instantiated at `untyped` at
every call site in the repo, so nothing downstream would tighten. `untyped` is the honest claim.

## Follow-ups

- Class A is a self-contained sig PR: generic `dump_type` / `assert_type`, and the nameable
  `Prism::` / `RBS::` / in-`sig/` returns. It changes no runtime behaviour and sits inside the
  ADR-107 review boundary because each type is read from the implementation, not guessed.
- Class B is the sig-coverage backlog and should be tracked per namespace.
- Class C stays with [#392].
- `static.value-use.top` remains the missing piece that would make `-> top` a meaningful third
  option for a return the author expects the caller to inspect; until it exists, `top` in a return
  position is theory without teeth.

## Second sweep (2026-09-23)

A pass over the residue left after the Class A landing found the split inside class B/C was
coarser than reality: a reader whose contract is `Array[String]` does not need new `sig/` coverage
at all — `String` is core — and only readers whose *element classes* are unsigned are genuinely
blocked. The second batch tightens the ones that clear that bar:

| Declaration | Now |
| --- | --- |
| `Environment#hkt_scan_failure` | `[String, String, String?, Symbol]?` (the tuple the comment documented) |
| `Inference::Narrowing.analyse` | `[Scope, Scope]?` |
| `Plugin::Loader.load` / `.load` | `Registry` (and the previously-undeclared `feature_resolver:` kwarg) |
| `Manifest#produces` | `Array[Symbol]` (the reader, not the validator's input: `initialize` maps `to_sym`) |
| `Manifest#owns_receivers` / `#open_receivers` / `#rbs_complete_ancestors` / `#signature_paths` | `Array[String]` (stored post-`to_s`) |
| `Manifest#type_node_resolvers` | `Array[Plugin::TypeNodeResolver]` |
| `Runner#effect_sources` | `Hash[String, Array[String]]` |
| `Runner#return_summaries` | `Hash[[String, String], Hash[Symbol, untyped]]` |
| `Runner#param_inferred_types` / `#collect_param_inference_table` | `Hash[[String, Symbol, Symbol], Hash[Symbol, Type::t]]` |
| `Runner#evaluate_return_types` | `Hash[[String, Symbol, bool], Array[String?]]` |

What remains is genuinely Class B: `Runner#effect_table` / `#effect_collection` /
`#effect_plugin_facts` / `#effect_collections_by_path` / `#prepare_project_scan` wait on `Effects::*`
and `Analysis::ProjectScan` coverage; `Manifest#block_as_methods` / `#heredoc_templates` /
`#nested_class_templates` / `#trait_registries` on `Plugin::Macro::*`; `#hkt_registrations` /
`#hkt_definitions` on `Inference::HktRegistry::*`; `#protocol_contracts` (and
`Plugin::Base#protocol_contracts`) on `Plugin::ProtocolContract`; `#additional_initializers` on
`Plugin::AdditionalInitializer`; `Analysis::Baseline#audit` on `Baseline::DriftRow`;
`CheckRules.node_collector_driver` on `RuleWalk::CollectorDriver`; `Environment#reflection` and the
three `*_reporter` readers on `Environment::Reflection` and the reporter duck types; and
`RbsExtended.read_flow_contribution` / `read_effect_envelope` on `Effects::Envelope`. Class D from
the first sweep is unchanged — `RbsCacheProducer.fetch` is additionally subclass-polymorphic, so its
`untyped` is honest for the same reason `read_fact`'s is, and `Manifest#source_rbs_synthesizer`
joined it on review: the constructor only requires `respond_to?(:call)` and ADR-32 WD6/WD12 give the
outcome a multi-shape contract (`String` / nil / `[:error, msg]` / `[:ok, src, msgs]`), so a
`^(String) -> String?` declaration would have copied WD4's stale comment, not the real contract.

## Two incidental findings

Recorded here so the next sweep does not rediscover them:

- `sig/rigor/sig_gen/skip_reason_catalog.rbs` references `::Rigor::SigGen` without a declaration;
  `rbs validate` over `sig/` and `make steep-check` both fail on it at `master`. The Rigor loader
  quarantines it, so the self-check stays green.
- `flow.always-truthy-condition` fired at `lib/rigor/effects/unit_scan.rb:560` on clean `master` —
  visible in CI Self-check logs too, but those jobs ran `rigor check --format json lib` without the
  Makefile's `--fail-on=warning`, so the warning never failed CI. Root cause was
  `gather_ivar_writes` not seeding compound ivar writes (`@x ||= v`), so `@dispatch_top_level` stayed
  `Constant[false]` — the `||=` seeding shape ADR-58 § WD5 deferred. Resolved by
  [#1179](https://github.com/rigortype/rigor/pull/1179) (closing
  [#1175](https://github.com/rigortype/rigor/issues/1175)): the pre-pass seeds all three compound
  forms and CI self-check now runs with `--fail-on=warning`.

[#392]: https://github.com/rigortype/rigor/issues/392
