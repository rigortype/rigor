# Macro / DSL Expansion Substrate

The **macro substrate** is the family of plugin-manifest value objects a
plugin author declares to teach Rigor the call shapes a metaprogramming
library exposes to its users — the `define_method` / `class_eval` /
`const_missing` patterns the engine cannot see by reading source alone.
It was introduced by [ADR-16](../adr/16-macro-expansion.md) (four tiers),
extended by [ADR-18](../adr/18-substrate-per-call-site-return-type.md)
(per-call-site return type) and
[ADR-36](../adr/36-mangrove-enum-nested-class-emission.md) (nested-class
emission).

This document specifies the **plugin-author-facing value-object shapes**:
the fields, their types, their validation, and the identity/immutability
contract every entry satisfies. The shapes are the durable contract a
plugin gem is authored against. The engine-side consumption — the
dispatcher's synthetic-method tier and `Environment#synthetic_method_index`
— is normative in [`inference-engine.md`](inference-engine.md) (the
dispatcher tier ordering + the `Environment` query surface); the
floor/ceiling delivery policy and the per-tier rationale are in the ADRs.

All four classes live under the `Rigor::Plugin::Macro` namespace
(`lib/rigor/plugin/macro/`) and are declared through the corresponding
`Manifest` slots documented in [`plugin.md`](plugin.md#rigorpluginmanifest):
`block_as_methods:`, `heredoc_templates:`, `trait_registries:`,
`nested_class_templates:`. Tier D returned demand-gated as **template
units** ([#392](https://github.com/rigortype/rigor/issues/392)); its value
object is `Rigor::Plugin::TemplateUnit` (`lib/rigor/plugin/template_unit.rb`),
specified in _Template units_ below rather than alongside the four above,
because it is the one tier whose declaration is a compiled source rather
than a call shape.

## Common value-object contract

Every macro value object MUST satisfy the same identity and immutability
rules (consistent with the rest of the plugin-contract carriers):

- **Frozen at construction.** All fields are dup-frozen in `#initialize`
  and the instance itself is frozen. `Ractor.shareable?` MUST return
  true after construction (ADR-15 Phase 1), so a materialised plugin
  carries its substrate declarations across the fork/Ractor boundary.
- **Validated at construction.** Each field is checked in `#initialize`;
  a malformed declaration MUST raise `ArgumentError` at manifest-build
  time (load), not fail silently at scan time. The `Manifest` slot
  re-validates that every entry is an instance of the expected class.
- **Value identity.** `#==` / `#eql?` / `#hash` compare by field value
  (most via the canonical `#to_h`), so two structurally-equal
  declarations are interchangeable.
- **`#to_h` round-trips into the cache key.** Every class exposes a
  string-keyed `#to_h`; the manifest folds it into `Manifest#to_h`,
  which is cache-key-stable. A plugin author MAY declare any tier today
  even where the engine integration is deferred (see _Implementation
  status_ below): the declaration round-trips and is exposed on the
  matching `Manifest` reader, and is forward-compatible when the engine
  slice lands.
- **`receiver_constraint` matching.** Every tier carries a
  `receiver_constraint`; the entry fires when the call's lexical
  receiver class **equals or inherits from** that fully-qualified name,
  matched through `Environment#class_ordering`. For `Singleton[X]`
  receivers (class-level DSL calls) the match also consults the
  `extend` edge: an entry fires when the module that would answer the
  call on `X`'s singleton — walked through `extend` edges in
  singleton-ancestor search order (`scope.discovered_extends` stores
  nearest-first), then up the discovered superclass chain, including
  RBS-declared `extend`s surfaced by
  `Environment#singleton_extended_modules` — resolves to the
  constraint and actually defines `method_name`. The class's own
  singleton defs precede every `extend` edge — but only once they have
  RUN: `sig { ... }; def self.sig` still binds `T::Sig`, because the
  `def` has not executed at call time. `Scope#singleton_def_shadows_call?`
  decides this from `discovered_deferred_ranges`, the per-file def /
  block / lambda body-range table: a call contained in any such range
  is deferred to invocation time and is shadowed iff a same-name def of
  the same owner is known at all — either already discovered, or
  recorded by a row the site table missed — while an eager
  class-body call is shadowed only by a same-name, same-owner def whose
  start offset precedes it (byte offsets, so same-line defs order
  correctly; the earliest matching def decides, so a later redefinition
  cannot resurrect the bridge; rows carry the qualified owner, so
  another class's `def self.sig` cannot order `F`'s call). Defs nested
  inside a deferred range — a `def` inside a method body or block —
  install at invocation time and are excluded from ordering, while
  `module_function` rows model the mode toggle and the `module_function
  :x` retro-install at the call site. Eagerly-evaluated bodies are not
  ranges: `Const = Class.new do … end` and `class_eval`-family blocks
  run during the enclosing body — the eval block's defs belong to
  the receiver's surface, so a nameable receiver supplies their
  owner (the def-site, method, visibility, and extends tables
  attribute eval-block bodies to the same receiver). A cross-file def and a file the index
  never saw both count as shadowed — the conservative direction, since
  binding `DeclBuilder` where a project method owns the call would
  invent diagnostics. That is how `class
  F; extend T::Sig; sig { ... }; end` and `class Doc <
  T::ImmutableStruct; sig { ... }; end` both reach the `sig` entry
  (#1097) — while a nearer `extend` whose module defines the same name
  (`extend T::Sig; extend CustomSig`), or the class's own already-run
  `def self.sig`, owns the call and the binding declines, since that
  custom method picks the block's self at runtime.

## Tier A — `BlockAsMethod` (`block_as_methods:`)

"The block passed to a class-level DSL call of one of `method_names` runs as an
instance method on `receiver_constraint`'s subclass tree, with `self`
typed accordingly." Canonical target: Sinatra's `get '/path' { ... }`
(the block literally becomes the route method body).

| Field | Type | Notes |
| --- | --- | --- |
| `receiver_constraint` | non-empty `String` | FQ class name the call's lexical receiver must be or inherit from. |
| `method_names` | non-empty `Array<Symbol>` | DSL method names (coerced from `Symbol`/non-empty `String`) whose block runs as an instance method. |
| `self_type` | `Symbol` or `String` | The `self`-binding inside the block. `:receiver_instance` (default) binds `Nominal[receiver class]` — the Sinatra contract. A String names the class the DSL `instance_eval`s the block on: `"Foo::Bar"` binds `Nominal[Foo::Bar]` (Grape `params` bodies on `Grape::Validations::ParamsScope`, verb bodies on `Grape::Endpoint`) and additionally matches `Nominal[Y ≤ receiver_constraint]` receivers, which is how a nested `requires do … end` inside a `params` body re-enters the same context. `"singleton(Foo::Bar)"` binds `Singleton[Foo::Bar]` (Grape `namespace` bodies on the `Grape::API::Instance` class object) and matches `Singleton` receivers only. `:receiver_singleton` / `:dsl_recorder` remain reserved names, not yet accepted. |

## Tier C — `HeredocTemplate` (`heredoc_templates:`)

"The class-level call `<receiver_constraint>.<method_name>(name_arg, …)`
emits synthetic methods on the calling class, with names interpolating
the source-visible literal argument at `symbol_arg_position`." Canonical
targets: dry-struct's `attribute :name, T` and ActiveStorage's
`has_one_attached :avatar`.

| Field | Type | Notes |
| --- | --- | --- |
| `receiver_constraint` | non-empty `String` | FQ class name (equals-or-inherits). |
| `method_name` | `Symbol` | The DSL method (from `Symbol`/non-empty `String`). |
| `symbol_arg_position` | `Integer >= 0` | Default `0`. The argument index whose literal Symbol value becomes the `name` interpolated into each emit row. |
| `emit` | `Array<Emit>` | Instance methods to synthesise on the calling class (coerced from `Hash`). |
| `class_level_emit` | `Array<Emit>` | Same shape; the synthesised methods are singleton (class-level). |

`NAME_PLACEHOLDER` is the literal `"#{name}"` token an emit row's `name:`
template carries for interpolation.

### `HeredocTemplate::Emit`

One row of an emit table.

| Field | Type | Notes |
| --- | --- | --- |
| `name` | non-empty `String` | The synthetic method's name template; a `"#{name}"` placeholder is interpolated with the call-site literal symbol at `symbol_arg_position`. |
| `returns` | non-empty `String` or `nil` | The declared return type name, resolved via `Environment#nominal_for_name`. When both `returns` and `returns_from_arg` are `nil`, the synthesised method's return falls back to `Dynamic[top]` per the ADR-16 WD13 floor. |
| `returns_from_arg` | `ReturnsFromArg` or `nil` | A per-call-site return type (ADR-18), coerced from a `Hash`. |

### `HeredocTemplate::ReturnsFromArg` (ADR-18)

A sibling class of `Emit` under `HeredocTemplate` (not nested inside
`Emit`), referenced by `Emit#returns_from_arg`. Declares that the
synthesised method's return type comes from a **call-site argument's
source representation**, looked up in a cross-plugin fact channel
([ADR-9](../adr/9-cross-plugin-api.md) `FactStore`). Authoring shape:

```ruby
returns_from_arg: { position: 1, lookup_via: { plugin_id: "dry-types", fact: :dry_type_aliases } }
```

| Field | Type | Notes |
| --- | --- | --- |
| `position` | `Integer >= 0` | The call-site argument index whose source representation is the lookup key. |
| `plugin_id` | non-empty `String` | The producing plugin (from `lookup_via:`). |
| `fact` | `Symbol` | The fact name to read from that plugin's `FactStore` bucket (from `lookup_via:`). |

`.coerce(value)` accepts a `Hash` (requiring a `lookup_via:` Hash), a
`ReturnsFromArg`, or `nil`, and raises on any other shape.

## Tier B — `TraitRegistry` (`trait_registries:`)

"The class-level call `<receiver_constraint>.<method_name>(:trait_a,
:trait_b, …)` effectively includes the modules named in
`modules_by_symbol[:trait_a]` + `[:trait_b]` (plus any `always_included`
modules) on the calling class." Canonical target: Devise's `devise
:database_authenticatable, :recoverable`.

| Field | Type | Notes |
| --- | --- | --- |
| `receiver_constraint` | non-empty `String` | FQ class name (equals-or-inherits). |
| `method_name` | `Symbol` | The DSL method (e.g. `:devise`). |
| `symbol_arg_position` | `:rest` or `Integer >= 0` | `:rest` (default, the only form the scanner honours) treats every positional Symbol arg as a trait; an Integer index is reserved for a future single-trait shape. |
| `modules_by_symbol` | `Hash<Symbol, String>` | Maps each recognised trait symbol to a FQ module name. A symbol absent from the table falls through (the scanner emits a `macro.tier_b.unknown-trait` `:info` marker). |
| `always_included` | `Array<String>` | FQ module names added at every matching call site even when no symbols match. |

`#module_for(symbol)` returns the FQ module name for a trait symbol, or
`nil` when unknown. Tier B is **not** subject to the Tier C `Dynamic[T]`
floor: the synthesised methods replay the included modules' authored RBS
return types (ADR-5 robustness — the substrate does not fabricate
precision it was not given).

## Nested-class tier — `NestedClassTemplate` (`nested_class_templates:`, ADR-36)

Where Tier C synthesises *methods*, this tier synthesises *nested
subclasses* declared by an enum-shaped block DSL. Motivating shape:
Mangrove's `variants do variant Circle, Float end`, where each `variant
<Const>, <Type>` row mints a nested subclass `Shape::Circle < Shape`
carrying `#inner : <Type>`.

| Field | Type | Notes |
| --- | --- | --- |
| `receiver_constraint` | non-empty `String` | FQ module name the enclosing class must `extend` for the block to be recognised (e.g. `"Mangrove::Enum"`). |
| `block_method` | `Symbol` | The enclosing DSL block. Default `:variants`. |
| `variant_method` | `Symbol` | Each declaration call inside the block. Default `:variant`. |
| `symbol_arg_position` | `Integer >= 0` | Default `0`. The argument index whose literal constant names the nested subclass. |
| `inner_arg_position` | `Integer >= 0` | Default `1`. The argument index whose type expression becomes the `#inner` reader's return type. A constant type argument resolves; a non-constant inner shape degrades to `Dynamic[top]`. |
| `inner_reader` | `Symbol` | The payload reader synthesised on each variant subclass. Default `:inner`. |

The `sealed`-parent fact + `is_a?` cross-variant exhaustive narrowing
(ADR-36 WD3) is the deferred ceiling.

## Implementation status

| Tier | Class | Manifest slot | Engine status |
| --- | --- | --- | --- |
| A | `BlockAsMethod` | `block_as_methods:` | Live (worked consumer: `rigor-sinatra`). |
| B | `TraitRegistry` | `trait_registries:` | Live (worked consumer: `rigor-devise`). |
| C | `HeredocTemplate` (+ `Emit` / `ReturnsFromArg`) | `heredoc_templates:` | Live (worked consumers: `rigor-dry-struct` / `rigor-dry-types`); `returns_from_arg` per-call-site lookup is the ADR-18 layer. |
| nested-class | `NestedClassTemplate` | `nested_class_templates:` | Live, Slice A (worked consumer: `rigor-mangrove`); sealed-parent exhaustiveness deferred. |
| D | `TemplateUnit` | `template_globs:` + `#template_units_for_file` | Live as of #392 (worked consumer: the `spec/fixtures/template_units` view-demo fixture, identity transform); ERB is #393. See _Template units_ below. |

Per [ADR-16 WD13](../adr/16-macro-expansion.md), substrate-produced output
ships at a **floor** ("substrate-affected code parses cleanly and has its
identifiers resolved"); precise return-type emission is the ceiling,
layered per tier (Tier C `returns:` strings via
`Environment#nominal_for_name`; ADR-13 `TypeNodeResolver` chain for richer
forms).

## Drift-pin status

The public-API drift spec
([`spec/rigor/public_api_drift_spec.rb`](../../spec/rigor/public_api_drift_spec.rb))
pins the instance method sets of `BlockAsMethod`, `HeredocTemplate`,
`HeredocTemplate::Emit`, `HeredocTemplate::ReturnsFromArg`, `TraitRegistry`,
and `NestedClassTemplate` — **every shipped value object on
the public manifest surface now carries the same accidental-change guard.**
The two formerly-unpinned objects (`NestedClassTemplate` per ADR-36 and
`HeredocTemplate::ReturnsFromArg` per ADR-18) were pinned via the
`PLUGIN_MACRO_NESTED_CLASS_TEMPLATE_INSTANCE` and
`PLUGIN_MACRO_HEREDOC_TEMPLATE_RETURNS_FROM_ARG_INSTANCE` snapshot constants.
`Rigor::Plugin::TemplateUnit` joins them under
`PLUGIN_TEMPLATE_UNIT_INSTANCE` (#392).
None of these objects carry an `sig/rigor/*.rbs` signature yet, so they are
guarded by the runtime instance-method snapshot only, not the RBS sig-drift
dual.

## Template units — `TemplateUnit` (`template_globs:` + `#template_units_for_file`, #392)

The revived [ADR-16](../adr/16-macro-expansion.md) Tier D. Tier D declared
`external_files:` — "files evaluated as if their body were pasted at a
declared call site, with `self` typed as a declared class", plus
`bound_ivars:` — and [ADR-60 WD1](../adr/60-pre-freeze-plugin-contract-consolidation.md)
removed it for want of an engine consumer. The demand arrived with effects
(`docs/design/20260816-effect-labels.md` § 11.3: the review question "what
does this request do" ends at `render` with a taint), and the revived seam
adds the one thing Tier D lacked: a **source transform with a line map**
ahead of parsing.

Unlike the four tiers above, this one is a **claim plus a hook** rather than
one manifest row, because a template is compiled rather than pattern-matched:

| Surface | Shape | Role |
| --- | --- | --- |
| `Manifest#template_globs` | `Array<String>` | Project-relative globs the plugin claims. Absolute globs and `..` segments are refused at manifest-build time. A plugin declaring none is never asked, and a run whose plugins declare none globs nothing. |
| `Base#template_units_for_file(path:, source:)` | `-> Array<TemplateUnit>` | The transform. Called ONCE per matched file, on the parent, before any analysis. `[]` declines the file. |

A returned unit MUST name the file it was offered (`unit.path == path`); a unit naming anything
else is refused. Without that check a `path:` naming another project file silently **replaced** that
file's source — the engine serves a unit's bytes for its own path — and a `path:` naming something
outside the project root was analysed with no dependency-descriptor row, both from one wrong string.

Three failure modes are reported rather than dropped, each as one `:plugin_loader` `runtime-error`
diagnostic positioned at the template file: a transform that **raised**, a template that could not be
**read**, and a unit naming the **wrong path**. That is the isolation envelope every other plugin
hook reports through ([ADR-2](../adr/2-extension-api.md) § "Plugin Trust and I/O Policy"): the file
contributes no unit, the run continues, and the plugin author has something to read.

Two units may share a `logical_name` across different paths. That is not refused: the two are
analysed separately and their summaries union under one `view:` key, the same reading a method
reopened in two files gets. Two units for the same **path** cannot occur — the first claim wins, so a
second plugin claiming a file another already compiled is dropped in registration order.

### `TemplateUnit`

`Rigor::Plugin::TemplateUnit.new(logical_name:, path:, ruby_source:,
line_map: {}, self_type: nil, locals: {}, ivar_seeds: {}, transform_id: nil)`.

| Field | Type | Notes |
| --- | --- | --- |
| `logical_name` | non-empty `String` | Handler-independent name — `users/show.html`, not `users/show.html.erb` — so an ERB → Haml rewrite is not a rename. Spells the `view:<logical_name>` effect-unit key. |
| `path` | non-empty `String` | The template file as the user wrote it, project-relative. Every diagnostic and every `Runner#effect_sources` row names this path. |
| `ruby_source` | `String` | The compiled Ruby. Parsed and typed as a file, NOT wrapped in a synthesised `class … def`; see the positions rule below. |
| `line_map` | `Hash<Integer, Integer>` | `{ ruby_source line => template line }`, 1-based on both sides; a non-positive line on either side raises. An empty map is the identity. |
| `self_type` | `String?` | Fully-qualified class the body's `self` is typed as. Also the owner an implicit-self call in the unit resolves against. |
| `locals` | `Hash<String, String>` | `{ name => type name }` — the render site's parameters. |
| `ivar_seeds` | `Hash<String, String>` | `{ "@name" => type name }` — the assigns the rendering action set. |
| `transform_id` | `String?` | The compiler's identity (`"erubi-1.13"`). Defaults to the declaring plugin's `id@version`. |
| `suppressed_rules` | `Array<String>` | #393 — rule-id PREFIXES the engine drops for this unit's diagnostics. See _Rule posture_ below. |

It satisfies the same common contract as the four tiers: frozen at
construction, validated at construction (a malformed declaration raises
`ArgumentError` at transform time, not at scan time), value identity, and a
`#to_h` that round-trips. It is additionally **`Marshal`-clean**, which the
fork pool depends on.

A `self_type`, `locals` or `ivar_seeds` type name the environment cannot resolve is bound
`Dynamic[top]` — not guessed, and **not left unbound**. The difference matters most for `self_type:`:
leaving it unbound is not "no claim", it is the claim that the body runs at top level, so every
helper call in the template reports `call.unresolved-toplevel` — a finding per line, caused by the
plugin naming a class whose RBS the project does not ship (`ActionView::Base`, on the first real
Rails app to try this). `Dynamic` is the honest reading of "a receiver is declared and the analyzer
cannot see it" ([ADR-5](../adr/5-robustness-principle.md)), and it is silent.

### Positions

`ruby_source` is parsed as-is, under a per-file `Scope` the engine seeds with
`self_type` / `locals` / `ivar_seeds` — the seeding
`StatementEvaluator#build_method_entry_scope` performs at a method boundary,
applied at the file boundary. Wrapping the body in a synthesised `class … def`
would shift every line and force the engine to compose an offset of its own
with the plugin's map; as it is, the only mapping in play is the plugin's.

The `locals:` names are additionally passed to Prism as the parse's enclosing
`scopes:`. Without that the seeding is inert: Prism parses a bare identifier
with no assignment in sight as a **method call**, so `size` in a template was a
`CallNode` and `Scope#local(:size)` was never consulted. Declaring them is what
Rails itself does when it compiles a partial's locals into the compiled
method's parameters.

A diagnostic produced inside a unit is re-pointed through `line_map` before it
leaves the run (`Analysis::TemplateUnits#remap`): the **path is already the
template's** (the parse is stamped with it), so only the line moves, and the
column drops to 1 — a compiler preserves lines and rewrites the text of each,
so a column of the compiled Ruby names nothing in the template. An unmapped
line anchors at the nearest mapped line before it, and at line 1 when there
is none, so a finding always lands inside the file.

The column rule applies whenever the unit carries a non-empty `line_map`, not
only when the line actually moves: a compiler that happens to leave a line
where it was still rewrote that line's text, and ERB is exactly that case — its
map is near-identity and its columns are meaningless either way. A unit with an
empty map claims no mapping at all, and its diagnostics pass through untouched.

### Rule posture (#393)

`suppressed_rules:` is the **per-unit** answer to "which families of finding are meaningful in this
compiler's output". A prefix is a dotted family (`call.`) or a whole rule id; the match is
`String#start_with?`, and `Analysis::TemplateUnits#remap` drops a matching diagnostic before the run's
stream leaves the parent. An empty list — the default — reports everything.

It is deliberately not a `disable:` entry: `disable:` silences a rule in the project's `.rb` files too,
which is the opposite of what a template-unit plugin wants. It is deliberately not engine policy
either: only the plugin knows what its own transform emits, and the honest default for one compiler is
not the honest default for another. It rides the unit digest, so turning a family back on re-analyses.

rigor-actionpack declares `["call.", "flow."]` while `view_type_checks:` is off (its default), and
`docs/notes/20260917-erb-template-units.md` records the corpus measurement each of the two prefixes
rests on — three `flow.always-truthy-condition` false positives on redmine, from the optional-local
preamble a partial writes when its render-site `locals:` are not traced.

### Effects, cache and the pool

- **Effect unit.** A template unit is ONE effect unit keyed
  `view:<logical_name>` — not a `MethodKey`, because a view has no owner class
  and no selector. The scanner takes the whole file body as that unit rather
  than minting one per `def` (`Effects::Scanner#scan_template_unit`), and
  `Runner#effect_sources` traces the key back to `path`.
- **Cache identity.** Each unit's digest is **`ruby_source` bytes + transform
  id + synthesis version** (`TemplateUnit::SYNTHESIS_VERSION`, bumped whenever
  the engine changes what it synthesises). Three rows carry it:
  - the ADR-45 run-result **key** gains a `template-units` `configs:` slot
    hashing the claimed globs (so a plugin editing its own `template_globs:`
    moves the key), every unit digest AND every failure. The failures
    are in it because a run that produced only failures still produced an
    answer; without them such a run's key equalled the no-templates key, which
    the ADR-87 boot-slim probe reconstructs exactly (it loads no plugin), so it
    served those rows after the template was fixed or deleted. The slot exists
    whenever any plugin claimed a glob — the condition under which the probe's
    key is knowingly unreconstructable, so the probe misses rather than hits.
  - every template the run READ, successes and failures alike, joins the
    recorded dependency descriptor as a `:stat` file row.
  - every claimed `template_globs:` pattern joins it as a `:names` glob row,
    whether or not it matched — the #979 mechanism. Only a glob row notices a
    template APPEARING, which is what otherwise let a project's first template
    stay invisible to every warm run until some `.rb` file changed.

  A project whose plugins claim no globs adds none of the three, so no existing
  key or descriptor moves.
- **Fork pool.** The index is built on the parent and inherited by the one
  pre-fork `WorkerSession`, so a worker analyses a unit from exactly the bytes
  the parent compiled. Pooled output equals sequential output for both the
  diagnostic stream and the effect table.
- **`--incremental`.** Units do **not** participate in dependent closures:
  nothing in the ADR-46 dependency graph names a synthesised file, so there is
  no edge that could put one in a closure. The conservative reading is taken —
  **a run always re-analyses every template unit** — which costs one parse per
  template on the warm incremental path and can never serve a stale answer.
  Making units first-class dependents is a later slice. Two mechanics carry it:
  `Runner#target_files` narrows the `.rb` expansion FIRST and appends the units
  second (appending first let the `analyze_only` select eat them), and
  `IncrementalSession` keeps unit paths OUT of `@analyzed`, so a unit is never
  served from the per-file cache and never reads as a project file that vanished.
- **Editor mode.** A single-buffer publish (`buffer:` with no closure) answers
  about the buffer the editor is showing, so the OTHER units do not join its
  analysed set — appending every view would publish diagnostics for files the
  editor did not ask about. When the buffer IS a template, that one unit is the
  analysed set exactly as a `.rb` buffer would be, and the transform is run over
  the **buffer's** bytes rather than the saved file's (`TemplateUnits.collect`
  takes the `BufferBinding`), so `--tmp-file` / `--instead-of` naming a template
  reports what the editor is showing. A `--incremental --tmp-file` recheck,
  which has a closure, analyses every unit.
- **Carrying the index (#1038).** `Analysis::ProjectScan` carries the compiled
  index, so a long-lived `LanguageServer::ProjectContext` does not re-run the
  plugin transform per keystroke — for ERB that was an Erubi compile of every
  view in the project, per publish. A `prebuilt:` runner hands the snapshot's
  index to `TemplateUnits.collect(previous:)`, which keeps what is expensive and
  redoes what is cheap: the claimed globs are re-expanded every run (only a glob
  notices a template APPEARING or vanishing) and every surviving template is
  revalidated through the ADR-87 stat-then-digest pack
  (`Cache::FileDigest.stat_fresh?`, whose authority is the content digest, so a
  touched-but-unedited template is still a reuse and an edited one never is).
  The pack is recorded inside a `Cache::FileDigest.with_run` scope
  (`ProjectPrePasses#build_template_units`), which is what puts ADR-87's racy
  guard behind it: without a scope the recording instant is taken after the
  pack's own `File.stat` and can never be racy, so a template rewritten between
  the collector's read and that stat would be recorded as the old digest beside
  the new stat tuple and served from the tuple fast path forever after. A
  template the plugin DECLINES (or whose transform raised) produces no unit, so
  there is nothing to carry and it is re-offered on every publish — the cost is
  one transform per declining template, and a negative cache would have to carry
  the `plugin_loader` rows with it.
  Three things rebuild the index wholesale, because each can change what a
  transform produces for bytes that never moved: a different root, a different
  set of claimed globs, a different set of glob-claiming plugins. One more
  rebuilds a single plugin's claim wholesale
  ([#1047](https://github.com/rigortype/rigor/issues/1047)): any of that
  plugin's templates edited, added or deleted on disk (a
  deleted template that had produced no unit is the one change this does not
  see; it contributed nothing a sibling could read). A transform may read its
  plugin's OTHER claimed templates — rigor-actionpack seeds a partial's locals
  from every view that renders it — so a template's own freshness cannot vouch
  for its unit, and the seam does not ask a plugin to declare which of its units
  are independent. The editor's buffer is exempt, so this never costs a
  keystroke, and it bites only on an on-disk edit the owner has not invalidated
  for (a save fires `didChangeWatchedFiles`, which rebuilds cold anyway); a
  template the plugin declined is carried as a bare stat pack so its unchanged
  bytes do not read as an edit. A plugin whose transform memoises such
  cross-file state learns that a pass began through
  `Plugin::Base#template_units_pass_started`, called once per pass before any
  `#template_units_for_file` and even when every unit is carried. Separately,
  and whatever the rest of the index does, the path the editor's buffer is bound
  to is recompiled from the buffer's bytes on every publish and its unit never
  enters a shared index. The snapshot is
  frozen, so a template edited on disk **since the scan was built** is
  recompiled on every publish until the owner invalidates — one compile per
  template in the changed template's claim, and a save fires
  `workspace/didChangeWatchedFiles`, which invalidates. A CLI run passes no
  `previous:` and builds the index from scratch exactly as before: its process
  ends with the run, so there is nothing to carry and no second cache to prove
  sound.
- **Path spellings.** A unit is keyed the way a claimed glob spells it —
  project-relative, as `Dir.glob(base:)` returns it — and every other spelling
  reduces to that one before a lookup or a claim test
  (`Analysis::TemplateUnitPaths`). There are more of them than there look to
  be: a language server names a buffer by its absolute path, a shell hands over
  `./app/views/x.rbx` or `lib/../app/views/x.rbx`, and the same directory
  reached through a symlink is the same directory (`Dir.pwd` is always
  resolved; on macOS an editor's `/var/…` and pwd's `/private/var/…` are one
  place, and the resolution walks to the nearest EXISTING ancestor so a view in
  a directory the editor has not created yet still resolves). A path that is
  still absolute after that reduction is **outside the project**, and an
  unanchored claim (`**/*.rbx`) does not reach it: a plugin's glob is a claim
  over the project, and `Dir.glob` could never have returned that path.
- **Position probes.** `rigor type-of` on a path a loaded plugin's
  `template_globs:` claims builds the run's index, parses the unit's COMPILED
  source with `parse_scopes`, seeds the file scope through `seed`, and resolves
  the requested TEMPLATE position through the inverse map
  (`Analysis::TemplateUnitPositions`,
  [#1040](https://github.com/rigortype/rigor/issues/1040)). A path no plugin
  claims builds no index and probes exactly as before; a claimed template whose
  transform raised reports the failure and exits 1; one the plugin declined
  says so and is then probed as the command always probed a file. The inverse is chosen, not
  derived, because nothing the seam ships runs that way:
  - **Lines.** A template line names the SET of compiled lines whose
    `template_line` is that line — the same set a diagnostic from it reports
    from — since `line_map` is not injective.
  - **Columns.** They do not correspond, so a column is resolved through the
    **longest verbatim run**: the template byte at the column is placed against
    every matching byte on those compiled lines, each placement is extended
    while the bytes agree, and the longest wins. The answer is the deepest
    compiled node at the mapped offset, and it is accepted only when that
    longest run is UNIQUE (a tie is two readings — declined as ambiguous), the
    node lies wholly inside the run on one line, and no OTHER placement's node
    lies inside its own run AND outside the winning run's compiled span. The
    "wholly inside" condition rejects markup: a compiler copies template text
    into a string literal, and the literal's quotes are never template bytes.
    It equally rejects code a compiler REWROTE rather than copied
    (rigor-actionpack's `yield` → `__rigor_yield`).
    The rival-placement condition is there because a longer run is not on its
    own a better reading: the compiler's own punctuation joins template bytes
    into runs the template never had, so the `=` of `<%=` matches the `=` of
    `<=`, `==`, `+=` or an assignment and `"= v "` (4 bytes, ending in the
    WRONG `v`) outruns the tag body `" v "`. Without it
    `<%= v %><% if 1 <= v %>` answered about the other `v`, with exit 0 and a
    type `rigor check` disagreed with. A repeat INSIDE the winning run is not
    a rival, because one tag body is copied once and the second occurrence is
    that copy seen from the other end: without that exemption
    `<%= @author.nil? ? l(:a) : l(:b, f(@author)) %>` declined, and the busy
    lines of a real view lost a third of their answers. What still declines is
    the CROSS-TAG repeat — `<%= v %> <%= v.to_s %>`, or `<%= v %><%= "v" %>`
    probed at the string's `v` — the price of not knowing where the tags are; a tag span exported by the
    plugin would answer those, and is the follow-up this rule is conservative
    ahead of.
  - **Hoisted text.** The nearest NON-BLANK compiled line above this template
    line's own joins the search as a SPILL target, and only a string literal
    found there counts. stdlib ERB emits a line's leading text on the line
    above (`_erbout.<< "\nname ".freeze`), so for a probe in that text the
    literal it has to tie with is not on this template line's compiled lines at
    all: without the spill, `name <%= name %>` probed at the HTML word typed as
    the tag's code. It is the nearest non-blank line rather than "the compiled
    lines of template line L-1" because ONE text gap is ONE literal and the
    compiler pads the lines it swallowed with blanks, so the literal sits on
    the last line that emitted anything — L-1 only when L-1 carried a tag
    itself. A CODE node up there must not count, or every `<%= v %>` repeated
    on consecutive template lines would decline.
    Tie-breaking by "the placement whose node looks like code" was rejected for
    the same family of reason: preferring the code would type a word of text.
  A bare `FILE:LINE` lists only the expressions on those compiled lines whose
  span maps back to a template column that the exact form then resolves to a
  node starting where that expression does, so the table never prints a column
  `FILE:LINE:COL` would decline. A `--trace` fallback
  is reported at the template line, and at a template column only when its
  location lies in a verbatim run. The rule knows nothing about ERB: an identity
  transform is one run per line and an ERB compiler one per tag body. The
  `dump_type` helper has no probe path of its own — it is a `rigor check`
  diagnostic, so it already types the compiled unit under the seeded scope and
  reports at the template line. The language server's hover does not route
  through the unit yet.
- **Other file sets.** A unit is an ANALYSED file, never a `source_files:` one:
  the env-build-time `source_rbs_synthesizer` is offered the `.rb` expansion
  alone, because a template's bytes are not Ruby an RBS synthesiser can read.
  `RunStats#target_files` counts units, because they are files the run parsed.

Worked consumers: `spec/fixtures/template_units/view_demo_plugin.rb` (the identity transform #392
shipped) and **rigor-actionpack**, which as of
[#393](https://github.com/rigortype/rigor/issues/393) claims `app/views/**/*.erb` and compiles each
through Erubi when it resolves in the analysed project's bundle
([ADR-90](../adr/90-target-library-resolution-from-project-bundle.md)) and stdlib `ERB` otherwise.

Two things #392 expected that consumer to need, and it did not:

- It does **not** only change `#template_units_for_file`. It needed the per-unit rule posture above,
  because a compiled template's typing is not yet worth a diagnostic per line, and it needed a
  `view:` unit key to be an `effects.envelopes:` subject (`Effects::MethodKey.envelope_owner` — a view
  has no owner class, and `MethodKey.split` would have grouped `view:users/show.html` under the
  class name `view:users/show`, which no run ever produced).
- A template whose compiled Ruby does not **parse** is declined by the plugin rather than handed over,
  through the seam's `[]` door. A layout was the measured case: `<%= yield %>` is legal ERB and illegal
  Ruby outside a method, so the alternative was two parse diagnostics per layout on templates Rails
  renders. [#1047](https://github.com/rigortype/rigor/issues/1047) resolved it **in the transform, not
  in the seam** — the plugin rewrites the `yield` keyword into a call on its synthesised view context
  before either compiler runs, which is the shape this section's Positions rule forces: wrapping the
  body in a synthesised method would shift every line and compose a second map onto the plugin's, so a
  body that must parse as written has to be rewritten as written. The rewrite is not width-preserving
  and does not need to be — a unit with a non-empty `line_map` reports at column 1 by construction.
- A controller action **is** edged to the template it renders
  ([#1048](https://github.com/rigortype/rigor/issues/1048)), through an attribution row's `callee:`
  rule rather than through anything in this seam: the unit key a template unit already carries is the
  callee key the edge names, so the two halves meet in the summaries table with no new resolution.
  The `render` taint survives exactly where the edge does not resolve — a computed target, or a name no
  unit answers. Since #1047 a layout **is** a unit, so a view-side `render layout:` discharges like any
  other partial render; what remains unedged is the layout Rails wraps an *action's* template in, whose
  name is a class-body declaration plus a convention lookup and therefore outside what a callee rule may
  read.
