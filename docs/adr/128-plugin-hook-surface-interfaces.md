# ADR-128 — The plugin hook surface as structural interfaces, and how its breaking changes ship

Status: **Proposed, 2026-11-03.** Nothing is implemented. Slice 1 (WD7) can land today and changes no
diagnostic. The interface types stay inert under `rigor check` until #929 (interface types erase to
`untyped`) and #2681 (a source-only plugin class does not take `Plugin::Base`'s RBS types) land, and
slice 2 must land before those to keep the result free of false positives.

Grounding: the measurement in #2681 (`make check-plugins`, 47 plugin classes, 2026-11-03).

## Context

Before ADR-50 freezes the plugin contract at v1.0.0, two things need settling: what a plugin author
may rely on, and how Rigor checks that they rely on nothing else. Today neither is settled.

- **The hook surface is untyped.** `sig/rigor/plugin/base.rbs` has 90 `untyped`. Every engine
  object a hook receives is `untyped`: `scope`, `call_node`, `root`, `node`, `services` and `config`.
- **Two binding documents disagree on what is public.**
  [`public-api.md`](../internal-spec/public-api.md) names `Rigor::Scope` public, and
  `spec/rigor/public_api_drift_spec.rb` pins about 210 of its instance methods.
  [ADR-50](50-release-engineering-and-stability-strategy.md) WD1 names `Scope` and `Type::*` engine
  internals that "may change any release". Separately,
  [`control-flow-analysis.md`](../type-specification/control-flow-analysis.md) § "Scope snapshots and fact buckets" says
  the public surface of `Scope` MUST NOT expose its buckets, and today's pinned set does.
- **What plugins actually use is small.** Bundled plugins call seven `Scope` methods on a scope a
  hook handed them:
  - five directly: `type_of`, `self_type`, `local`, `source_path`, `environment`;
  - two ancestor queries, at 9 sites in 3 plugins (`rigor-activerecord`,
    `rigor-active-model-serializers`, `rigor-rspec`): `user_def_through_ancestors` and
    `discovered_method_through_ancestors?`.

  Every one of the 9 sites reduces to a single boolean question: does the project define method `m`
  on class `C` or one of its ancestors. `rigor-active-model-serializers` guards the call with
  `scope.respond_to?(:user_def_through_ancestors)`, which shows an author hedging against a method
  nobody promised. `rigor-alba` and `rigor-typelizer` reach `Rigor::Inference::DeclarationWalk`,
  which `public-api.md` lists as internal.
- **Typing the hooks today checks nothing.** The #2681 measurement found three separate reasons:
  1. RBS interface types erase to `untyped` (`lib/rigor/inference/rbs_type_translator.rb` ~L81,
     `RBS::Types::Interface => :translate_untyped`; #929).
  2. A source-only plugin class does not take `Base`'s RBS types for DSL block parameters, override
     parameters or readers (#2681). Declaring each class in RBS works around it.
  3. With (1) and (2) worked around, typing `call_node` and `scope` adds 9 `call.argument-type-mismatch`
     diagnostics, all on `scope.type_of(call_node.receiver)` right after a nil guard. They are false
     positives: Prism node readers are not declared `%a{pure}`, so the impure-by-default policy does
     not carry the guard to the re-read.

  The same run found **no** call outside the draft surface on a scope a hook received directly. All
  9 out-of-surface sites sit in private helpers that take `scope` as a plain parameter, and such a
  parameter stays `Dynamic` under `check`.

Terminology ([`CONTEXT.md`](../../CONTEXT.md)): an RBS structural type is an **interface**. "Protocol" is
reserved for ADR-28's path-scoped contracts.

## Decision

Each engine object a hook receives is exposed to plugins as a named RBS structural interface under
`Rigor::Plugin` (`_Scope`, `_Environment`, `_Services`, …). `base.rbs` types every hook position
against those interfaces, against concrete Prism node classes, against `Rigor::Type::t`, or against
core types.

**Criterion.** A method is public plugin API **if and only if** it is declared on `Plugin::Base`, on
a plugin-facing interface, or in a namespace `public-api.md` lists as public (`Type::Combinator`,
`Source::Literals`, …). Being reachable at runtime does not make it public, and neither does a drift
pin.

**Admission rule.** A method enters an interface only when both of these hold:

- a plugin needs it;
- its contract can be stated without naming an engine-internal type.

When the second fails, Rigor adds a facade method that answers the plugin's actual question, rather
than exposing the internal shape (such as `[Prism::DefNode, String] | [nil, nil]`).

## Working decisions

**WD1 — The initial `_Scope`.**

```rbs
interface Rigor::Plugin::_Scope
  def type_of: (::Prism::Node node) -> Rigor::Type::t
  def self_type: () -> Rigor::Type::t?
  def local: (String | Symbol name) -> Rigor::Type::t?
  def source_path: () -> String?
  def environment: () -> Rigor::Plugin::_Environment
  def project_defines?: (String class_name, String | Symbol method_name, ?(:instance | :singleton) kind) -> bool
end
```

`project_defines?` is new. It answers the boolean question behind all 9 ancestor-query sites by ORing
the existing `user_def_through_ancestors` and `discovered_method_through_ancestors?` walks on
`lib/rigor/scope.rb`. The three plugins migrate to it in slice 1. `_Environment` starts with the
member plugins call through it, `nominal_for_name`. Slice 1 measures the rest of its set the way this
ADR measured `_Scope`.

**WD2 — The other hook positions.**

- `call_node`, `root` and `node` take concrete Prism classes. Prism ships its own RBS (`sig/` in the
  prism gem).
- The `dynamic_return` block returns `Rigor::Type::t?`. Plugins build types through
  `Type::Combinator`, which is already public.
- Diagnostic hooks return `Array[Rigor::Analysis::Diagnostic]`.
- `services` becomes `_Services`, initially `fact_store`, `configuration`, `reflection` and `type`,
  each narrowed to the members plugins call: `publish`/`read` 21, `paths` 7,
  `instance_method_definition` 1, `literal_string_compatible?` 2.
- `config` becomes `Hash[String, untyped]`. Its values are schema-driven per plugin, and typing them
  precisely is out of scope.

**WD3 — Where generics apply.** Generics apply only where a key links a write to a later read:
`producer` with `producer_value`, and the fact store's `publish` with `read`. These gain an
*additive* typed-key overload, `(ProducerKey[V]) -> V` beside the existing `(Symbol) -> untyped`, so
no caller breaks. They are not part of slice 1. They land when a plugin needs the precision.

**WD4 — The boundary is gated by a spec, not by the type check.** A spec-only `TracePoint` recorder
runs over the bundled plugins' integration specs. It records every method called on a `Rigor::Scope`
(and on each other interface's backing class) from a frame under `plugins/` or `examples/`, and it
fails when a recorded method is not on the interface. The recorder wraps nothing, so object identity
and `is_a?` are preserved and production pays no cost. Its coverage is whatever the plugin specs
exercise. The type check cannot carry this gate (#2681's measurement): helper parameters are
`Dynamic`, so even with #929 and #2681 fixed it sees only direct hook bodies. Known internal reaches
(`Inference::DeclarationWalk`) either get a facade or an allow-list entry that cites a filed issue.

**WD5 — The concrete classes stay internal.** ADR-50 WD1 holds. In slice 1, `public-api.md` replaces
its `Rigor::Scope` / `Rigor::Environment` entries with the interfaces. The drift spec gains an
interface snapshot that pins each interface's member list. The existing `SCOPE_INSTANCE` snapshot
stays as an internal change detector, relabelled so that it no longer reads as a promise.

**WD6 — How a breaking plugin-API change ships.** Classify the change first. The class decides the
release vehicle.

| Change | Example | Pre-1.0 | Post-1.0 |
| --- | --- | --- | --- |
| Signature precision only (RBS, no runtime effect) | `untyped` → `Prism::CallNode` | any release | any release |
| Promise narrowed (no longer public, still callable) | `Scope`'s ~210 methods → `_Scope` | minor, `changed` fragment | major |
| Runtime break | a hook renamed or removed, its block arity changed | deprecate in minor N, remove in minor N+1 | deprecate in a minor, remove in the next major |

A runtime break follows the ADR-80 precedent: `type_specifier` warned throughout 0.2.x and was removed
in 0.3.0, where it raises at class-definition time.

- **The deprecation shim** warns once per plugin class and names the replacement. It ships with a
  `deprecated` fragment that carries the migration.
- **The removal** fails loudly at load or class definition, never silently.
- **Bundled plugins migrate in the deprecating PR.** They ship in the same gem, so a spec asserts
  that no bundled plugin triggers a deprecation warning.
- **Third-party plugins** are documented to depend on `rigortype` with `~> 0.N.0` before 1.0,
  because the minor is the hard break there (ADR-50 WD5), and with `~> 1.0` after 1.0.

**WD7 — Sequencing.**

1. **Slice 1:** declare the interfaces, type `base.rbs`, add `project_defines?`, migrate the three
   plugins, amend `public-api.md`, and add the WD4 gate and the WD5 snapshot. Because of #929 and
   #2681 this is inert under `check`. Its acceptance bar is that `make check-plugins` reports no new
   diagnostic.
2. **Slice 2:** declare Prism node readers `%a{pure}` through a Rigor-shipped overlay. Prism nodes are
   effectively immutable after parsing. This removes the 9 false positives before anything makes them
   reachable.
3. **Slice 3:** #2681, then #929, make the types live. Acceptance: `make check-plugins` reports no new
   diagnostic on the bundled plugins, and any firing is adjudicated before it lands.

## Rejected / deferred alternatives

| Alternative | Status | Reason |
| --- | --- | --- |
| Promote `Rigor::Scope` wholesale, as `public-api.md` reads today | Rejected | It freezes about 210 methods at v1.0, including bucket accessors the CFA spec forbids exposing, for a surface plugins use 7 of. |
| Pass hooks a runtime facade or wrapper object | Rejected | Hooks run per call node, so it allocates on the hottest plugin path (ADR-50's perf gate). It also breaks identity when a plugin hands the scope back to an engine API (`resolver.resolve(node, scope)`). |
| A nominal facade class in RBS instead of an interface, which checks today once #2681 lands | Rejected | It declares a class that does not exist at runtime. `Rigor::Scope` is not one, and every RBS reader would trust the lie. This ADR's measurement used one only as a stand-in. |
| Enforce the boundary through the type check alone | Rejected | Measured blind to helper methods, which are where all 9 out-of-surface calls sit. |
| `Base[Config]` class generics for typed `config` | Rejected | Plugin authors would have to write RBS, which runs against ADR-0's "no Rigor-specific annotations". |
| A plugin-API version field in the manifest | Deferred | ADR-2 deferred it until gem constraints prove insufficient. Bundled plugins ship in the gem, and gem plugins have WD6's constraint. Revisit on the first report of a non-gem plugin breaking silently across a minor. |
| A `call.deprecated` diagnostic driven by `%a{deprecated}` in shipped RBS | Deferred | It needs slice 3 to reach plugin code at all. Revisit at the first plugin-API deprecation after slice 3. |

## Consequences

- **Positive:** the v1.0 plugin freeze (#927) becomes an enumerable list: `Base` plus the interface
  member lists. `public-api.md` and ADR-50 WD1 stop contradicting each other.
- **Positive:** a plugin author gets typed hook arguments, and a reason to stop guarding calls with
  `respond_to?`.
- **Negative:** the useful half, `check` reporting misuse in a plugin, waits on two engine issues and
  the purity overlay. Until then the interfaces are documentation, plus whatever the WD4 gate covers.
- **Negative:** the WD4 gate is only as complete as the plugin specs' coverage.
- **Carry-over:** `Inference::DeclarationWalk`'s plugin users need a facade or a tracked allow-list
  row. `_Environment` and `_Services` still have to be measured to their final member sets.

## Relationship to other ADRs

- [ADR-2](2-extension-api.md) — the extension API whose public namespaces this ADR enumerates. Its
  deferral of a protocol version stands (WD6).
- [ADR-37](37-plugin-interface-segregation.md) and [ADR-80](80-narrowing-facts-rename.md) — the hook DSLs
  being typed. ADR-80's alias-then-remove is WD6's runtime-break precedent.
- [ADR-43](43-rbs-complete-ancestor-resolution.md) — the allow-list bridge that #2681 extends to
  parameter binding.
- [ADR-50](50-release-engineering-and-stability-strategy.md) — WD1 (what is internal), WD5 (the hard
  break is the minor pre-1.0), WD7 (deprecation cadence). This ADR applies them to the plugin API and
  does not change them.
- [ADR-1](1-types.md) — capability roles over RBS interfaces. #929 implements their assignability.
- [ADR-0](0-concept.md) — no Rigor-specific annotations in application code (the `Base[Config]`
  rejection).
