# ADR-128 — The plugin hook surface as structural interfaces, and how its breaking changes ship

Status: **Proposed, 2026-11-03.** Nothing is implemented. Slice 1 (WD7) can land today. It adds no
diagnostic to plugin source, because the interface types stay inert there until two issues land:
#929 (RBS interface types erase to `untyped`) and #2681 (a source-only plugin class does not take
`Plugin::Base`'s RBS types). Slice 2 must land before those two. Slice 3 makes the types live, behind
a dedicated rule (WD6).

Grounding: the measurement in #2681 (`make check-plugins`, 47 plugin classes, 2026-11-03).

## Context

Before ADR-50 freezes the plugin contract at v1.0.0, two things need settling: what a plugin author
may rely on, and how Rigor checks that they rely on nothing else. Today neither is settled.

- **The hook surface is untyped.** `sig/rigor/plugin/base.rbs` has 90 `untyped`. Every engine
  object a hook receives is `untyped`: `scope`, `call_node`, `root`, `node`, `services` and `config`.
- **The binding spec and ADR-50 disagree on what is public.**
  [`public-api.md`](../internal-spec/public-api.md) names `Rigor::Scope` public, and
  `spec/rigor/public_api_drift_spec.rb` pins 207 of its instance methods (`SCOPE_INSTANCE`), bucket
  accessors such as `locals` and `fact_store` included.
  [ADR-50](50-release-engineering-and-stability-strategy.md) WD1 names `Scope` and `Type::*` engine
  internals that "may change any release".
  [`control-flow-analysis.md`](../type-specification/control-flow-analysis.md) § "Scope snapshots and
  fact buckets" says the public surface of `Scope` MUST NOT expose its buckets.
- **What plugins actually use is small.**
  - On a scope a hook handed them, bundled plugins call five `Scope` methods directly: `type_of`,
    `self_type`, `local`, `source_path`, `environment`.
  - They also call two ancestor walks, `user_def_through_ancestors` and
    `discovered_method_through_ancestors?`: 10 calls in 8 expressions across `rigor-activerecord`,
    `rigor-active-model-serializers` and `rigor-rspec`.
  - The two walks are not interchangeable:
    - when the ancestor budget runs out, the discovery walk answers `true` and the def walk answers
      `[nil, nil]` (`lib/rigor/scope.rb` ~L1915, ~L2040);
    - the discovery table also counts `attr_*` and `define_method`;
    - singleton lookups go through a third walk, `singleton_def_through_ancestors`.

    Each site picks the walk whose uncertainty direction it needs.
  - `rigor-active-model-serializers` guards with `scope.respond_to?(:user_def_through_ancestors)`,
    an author hedging against a method nobody promised.
  - Plugins also pass the hook's scope to the public `Rigor::Reflection`, whose RBS takes
    `scope: Scope` (`sig/rigor/reflection.rbs`).
  - `rigor-alba` and `rigor-typelizer` reach the internal `Rigor::Inference::DeclarationWalk`.
- **Typing the hooks today checks nothing in plugin source.** The #2681 measurement found three
  causes:
  1. RBS interface types erase to `untyped` (`lib/rigor/inference/rbs_type_translator.rb` ~L81,
     `RBS::Types::Interface => :translate_untyped`; #929).
  2. A source-only plugin class does not take `Base`'s RBS types for DSL block parameters, override
     parameters or readers (#2681).
  3. With (1) and (2) worked around, typing `call_node` and `scope` adds 9 `call.argument-type-mismatch`
     diagnostics, all on `scope.type_of(call_node.receiver)` right after a nil guard. They are false
     positives: Prism node readers are not declared `%a{pure}`.

  That run found no call outside the draft surface on a scope a hook received directly. Every
  out-of-surface call sits in a helper that takes the scope as a plain parameter, or reads it from
  an instance variable, so the scope is `Dynamic` there under `check`.

Terminology ([`CONTEXT.md`](../../CONTEXT.md)): an RBS structural type is an **interface**. "Protocol" is
reserved for ADR-28's path-scoped contracts.

## Decision

Each engine object a hook receives is exposed to plugins as a named RBS structural interface under
`Rigor::Plugin` (`_Scope`, `_Environment`, `_Services`, …). `base.rbs` types every hook position
against those interfaces, concrete Prism node classes, `Rigor::Type::t`, or core types. Public APIs
that accept a scope back (`Rigor::Reflection`'s `scope:`) accept the interface.

**Criterion.** A method is public plugin API **if and only if** it is declared on `Plugin::Base`, on
a plugin-facing interface, or in a namespace `public-api.md` lists as public (`Type::Combinator`,
`Reflection`, `Source::Literals`, …). Being reachable at runtime does not make it public, and neither
does a drift pin.

**Admission rule.** A method enters an interface only when both of these hold:

- a plugin needs it;
- its contract can be stated without naming an engine-internal type or hiding an uncertainty
  direction.

When the second fails, Rigor adds a facade on a public namespace that answers the plugin's actual
question.

## Working decisions

**WD1 — The initial `_Scope`, and an ancestor facade on `Reflection`.**

```rbs
interface Rigor::Plugin::_Scope
  def type_of: (::Prism::Node node) -> Rigor::Type::t
  def self_type: () -> Rigor::Type::t?
  def local: (String | Symbol name) -> Rigor::Type::t?
  def source_path: () -> String?
  def environment: () -> Rigor::Plugin::_Environment?
end
```

The ancestor question becomes `Rigor::Reflection.project_method_defined(class_name, method_name, kind:,
source:, scope:) -> Rigor::Trinary`. It lives on `Reflection`, the public read-side facade. Its
parameters:

- `kind:` is `:instance` or `:singleton`. Each kind walks its own chain.
- `source:` is `:def` or `:any`. `:def` asks about `def` nodes only; `:any` also counts `attr_*` and
  `define_method`, as the discovery table does.

It answers `maybe` when the ancestor budget runs out. Each migrated site keeps its own direction:

- a site that admits on a hit tests `yes?`;
- a site that declines on a hit tests `!no?`.

That preserves today's behaviour at all 8 expressions. `_Environment` starts with the two members
plugins call through it, `nominal_for_name` and `rbs_module?`. Slice 1 measures the rest of its set
the same way.

**WD2 — The other hook positions.**

- `call_node`, `root` and `node` take concrete Prism classes. Prism ships its own RBS (`sig/` in the
  prism gem).
- The `node_rule` block receives `(node, scope, path, file_context, context)` (`base.rb` ~L614).
  `context` is `Plugin::NodeContext`, which gets an RBS declaration in slice 1.
- The `dynamic_return` block returns `Rigor::Type::t?`.
- The `narrowing_facts` block returns the fact array `narrowing_facts_for` collects (`base.rb`
  ~L644); slice 1 declares its element type.
- Diagnostic hooks return `Array[Rigor::Analysis::Diagnostic]`.
- `services` becomes `_Services`: `fact_store`, `configuration`, `reflection` and `type`, each
  narrowed to the members plugins call.
- `config` becomes `Hash[String, untyped]`. Its values are schema-driven per plugin, and typing them
  precisely is out of scope.
- `TypeNodeResolver` hooks receive a `TypeNode::NameScope`, which is already drift-pinned public. It
  stays a concrete public class here; giving it an interface is a later slice.

**WD3 — Where generics apply.** Generics apply only where a key links a write to a later read:
`producer` with `producer_value`, and the fact store's `publish` with `read`. These gain an
*additive* typed-key overload, `(ProducerKey[V]) -> V` beside `(Symbol) -> untyped`, so no caller
breaks. They are not part of slice 1; they land when a plugin needs the precision.

**WD4 — The boundary is gated by a spec, not by the type check.** A spec-only `TracePoint` recorder
runs over the bundled plugins' integration specs.

- It listens to `:call` and `:c_call`. `self_type`, `environment` and the bucket accessors are
  `attr_reader`s, which fire only `:c_call`.
- It records every method called on a `Rigor::Scope` (and on each other interface's backing class)
  from a frame under `plugins/` or `examples/`.
- It fails when a recorded method is neither on the interface nor inherited from
  `Object`/`Kernel`/`BasicObject`. Calls such as `nil?`, `respond_to?` and `is_a?` stay allowed.
- It wraps nothing and costs production nothing. Its coverage is whatever the plugin specs exercise.

The type check cannot carry this gate (#2681): helper parameters are `Dynamic`, so even with #929 and
#2681 fixed it sees only direct hook bodies. Known internal reaches (`Inference::DeclarationWalk`)
get a facade, or an allow-list entry that cites a filed issue.

**WD5 — The concrete classes stay internal.** ADR-50 WD1 holds. In slice 1:

- `public-api.md` replaces its `Rigor::Scope` / `Rigor::Environment` entries with the interfaces.
- `Reflection`'s RBS takes `scope: Rigor::Plugin::_Scope`. Its implementation still receives a real
  `Scope` at runtime and reads it as one.
- The drift spec gains an interface snapshot. The existing `SCOPE_INSTANCE` snapshot stays as an
  internal change detector, relabelled so that it no longer reads as a promise.

**WD6 — How a breaking plugin-API change ships.** Classify the change first; the class decides the
release vehicle. ADR-50 WD5's tiers apply unchanged: a patch carries no behaviour surprise, and a
maintenance line gets no new diagnostic.

| Change | Example | Pre-1.0 | Post-1.0 |
| --- | --- | --- | --- |
| Signature precision only | `untyped` → `Prism::CallNode` in `base.rbs` | a minor, or a patch only while slice 3 has not made it observable | a minor |
| Promise narrowed (no longer public, still callable) | `Scope`'s 207 pinned methods → `_Scope` | a minor, with a `changed` fragment | a major |
| Runtime break | a hook renamed or removed, its block arity changed | deprecate in minor N, remove in minor N+1 | deprecate in a minor, remove in the next major |

ADR-50 Decision 1 pledges "minor-non-break" on the enumerated surface. A narrowed promise keeps that
pledge for running plugins, because nothing they call changes at runtime. What changes is what Rigor
promises to keep.

A runtime break follows the ADR-80 precedent: `type_specifier` warned throughout 0.2.x and was removed
in 0.3.0, where it raises at class-definition time.

- **The deprecation shim** warns once per plugin class and names the replacement. It ships with a
  `deprecated` fragment that carries the migration.
- **The removal** fails loudly at load or class definition, never silently.
- **Bundled plugins migrate in the deprecating PR.** A spec asserts that no bundled plugin triggers a
  deprecation warning.
- **Third-party plugins** are documented to depend on `rigortype` with `~> 0.N.0` before 1.0,
  because the minor is the hard break there (ADR-50 WD5), and with `~> 1.0` after 1.0.

**The check slice 3 turns on is a new discipline.** A call outside an interface works at runtime, so
`call.undefined-method` must not fire on it. Slice 3 reports such a call under a dedicated rule
(`plugin.api-surface`). The rule sits in the bleeding-edge overlay until the next hard break (ADR-50
Decision 3, WD2, WD7).

**WD7 — Sequencing.**

1. **Slice 1:** declare the interfaces and `NodeContext`; type `base.rbs` and `Reflection`'s `scope:`;
   add `Reflection.project_method_defined`; migrate the three plugins; amend `public-api.md`; add the
   WD4 gate and the WD5 snapshot. Acceptance:
   - `make check-plugins` and `make check` report no new diagnostic. `make check` matters because
     `lib/` calls the typed hooks with explicit receivers, which the ADR-43 bridge and RBS dispatch
     already check.
   - The migrated plugins' integration specs pass unchanged.
   - A survey diff on the projects those plugins serve (Mastodon for `rigor-active-model-serializers`
     and `rigor-activerecord`, an RSpec-heavy target for `rigor-rspec`) shows no delta.
2. **Slice 2:** declare Prism node readers `%a{pure}` through a Rigor-shipped overlay; Prism nodes
   are effectively immutable after parsing. The overlay applies to every analysed project that uses
   Prism, so its acceptance includes a corpus before/after run as well as removing the 9 false
   positives.
3. **Slice 3:** #2681, then #929, make the types live, with WD6's `plugin.api-surface` rule in the
   bleeding-edge overlay. Acceptance: `make check-plugins` reports no new default-on diagnostic, and
   any firing is adjudicated before it lands.

## Rejected / deferred alternatives

| Alternative | Status | Reason |
| --- | --- | --- |
| Promote `Rigor::Scope` wholesale, as `public-api.md` reads today | Rejected | It freezes 207 methods at v1.0, including bucket accessors the CFA spec forbids exposing, for a surface plugins use five of directly. |
| Pass hooks a runtime facade or wrapper object | Rejected | Hooks run per call node, so it allocates on the hottest plugin path (ADR-50's perf gate). Plugins also hand the scope back to `Reflection` (`rigor-activesupport-core-ext`, `rigor-rspec`), which needs the real object. |
| A boolean `project_defines?` on `_Scope` that ORs the existing walks | Rejected | It flips budget uncertainty into admission at the site that admits on a hit (`rigor-active-model-serializers`), and it mixes the def and discovery tables and the singleton chain. |
| A nominal facade class in RBS instead of an interface | Rejected | It declares a class that does not exist at runtime, and every RBS reader would trust the lie. #2681's measurement used one only as a stand-in. |
| Enforce the boundary through the type check alone | Rejected | Measured blind to helpers, which are where every out-of-surface call sits. |
| `Base[Config]` class generics for typed `config` | Rejected | Plugin authors would have to write RBS, which runs against ADR-0's "no Rigor-specific annotations". |
| Report out-of-interface calls as `call.undefined-method` | Rejected | The method exists, so that would be a false positive on correct code. WD6's dedicated bleeding-edge rule replaces it. |
| A plugin-API version field in the manifest | Deferred | ADR-2 deferred it until gem constraints prove insufficient. Revisit on the first report of a non-gem plugin breaking silently across a minor. |
| A `call.deprecated` diagnostic driven by `%a{deprecated}` in shipped RBS | Deferred | It needs slice 3 to reach plugin code at all. Revisit at the first plugin-API deprecation after slice 3. |

## Consequences

- **Positive:** the v1.0 plugin freeze (#927) becomes an enumerable list: `Base`, the public
  namespaces and the interface member lists. `public-api.md` and ADR-50 WD1 stop contradicting each
  other.
- **Positive:** a plugin author gets typed hook arguments and a three-valued answer to the ancestor
  question, in place of a `respond_to?` guard on an internal walk.
- **Negative:** the useful half, `check` reporting misuse in a plugin, waits on two engine issues and
  the purity overlay. Even then it is opt-in until a hard break.
- **Negative:** the WD4 gate is only as complete as the plugin specs' coverage, and it covers only
  bundled plugins.
- **Carry-over:** `Inference::DeclarationWalk`'s plugin users need a facade or a tracked allow-list
  row. `_Environment`, `_Services` and `NameScope` still have to be measured to their final shapes.
  ADR-2's third-party conformance suite remains the place a WD4-style check would reach outside
  bundled plugins.

## Relationship to other ADRs

- [ADR-2](2-extension-api.md) — the extension API whose public namespaces this ADR enumerates. Its
  deferral of a protocol version stands (WD6).
- [ADR-37](37-plugin-interface-segregation.md) and [ADR-80](80-narrowing-facts-rename.md) — the hook
  DSLs being typed. ADR-80's alias-then-remove is WD6's runtime-break precedent.
- [ADR-43](43-rbs-complete-ancestor-resolution.md) — the allow-list bridge that #2681 extends to
  parameter binding.
- [ADR-50](50-release-engineering-and-stability-strategy.md) — Decision 1 (minor-non-break), Decision 3
  (a new discipline is breaking), WD1 (what is internal), WD2/WD7 (the bleeding-edge overlay), WD5
  (release tiers; the hard break is the minor pre-1.0). This ADR applies them to the plugin API and
  does not change them.
- [ADR-1](1-types.md) — capability roles over RBS interfaces. #929 implements their assignability.
- [ADR-0](0-concept.md) — no Rigor-specific annotations in application code (the `Base[Config]`
  rejection).
