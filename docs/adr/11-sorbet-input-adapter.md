# ADR-11 — Sorbet input as a plugin adapter

Status: **proposed, 2026-05-09.** Design fixed here so a future
`rigor-sorbet` plugin author can proceed against a stable
contract; no Rigor core changes are required to adopt this ADR.
Implementation queued for v0.1.x+ (no committed milestone).

## Context

Rigor's primary type-source contract is RBS (plus `RBS::Inline`
comments and the `RBS::Extended` annotations). The user
expressed appreciation for [Sorbet][sorbet]'s authorship style:
inline `sig { ... }` blocks, in-line `T.let` / `T.cast` /
`T.must` assertions, and **runtime-enforced** type checks
(`sorbet-runtime` wraps each annotated method so that violations
raise at runtime rather than slipping past static analysis).
The proposal: let Rigor consume Sorbet sigs and the related
`T::*` assertions as type sources, ideally without forcing
users to maintain parallel RBS.

Two facts shape the answer:

1.  **Sorbet has its own type-system semantics that don't
    line up with RBS exactly.** [Sorbet's RBS-comments
    docs][sorbet-rbs] are explicit about this — the Sorbet
    team treats RBS as a "second-class" annotation form and
    states that the two type languages "differ in semantics,
    not just syntax." Examples of divergence:
    - Sorbet has no literal types (`'foo'` is `String`).
    - Sorbet rejects duck typing by design; RBS has structural
      interfaces.
    - `T.untyped` is both a supertype AND subtype of every
      type (gradual semantics); RBS `untyped` is a one-way
      cliff.
    - `T.anything` is the "true" top with no operations
      ([anything.md][sorbet-anything]); RBS `top` doesn't
      enforce the same restriction.
    - Sorbet's `T::Class[T]` and `T.attached_class` /
      `T.self_type` carry context-sensitive semantics that
      RBS does not express directly.

2.  **The Sorbet runtime is a separate gem from the Sorbet
    static analyzer.** `sorbet-runtime` is what wraps `sig`'d
    methods to enforce types at runtime; `srb tc` is the
    static type checker. Rigor competes with `srb tc` (the
    static side); the runtime-enforcement ergonomics the user
    likes are a property of `sorbet-runtime` that survives
    regardless of which static analyzer reads the sigs.

[sorbet]: https://sorbet.org/
[sorbet-rbs]: https://sorbet.org/docs/rbs-support
[sorbet-anything]: https://sorbet.org/docs/anything

## Decision

**Sorbet input lands as a `rigor-sorbet` plugin, not as a
core feature.** The plugin sits in the existing extension
contract surface (ADR-2 / ADR-9), translates Sorbet's type
vocabulary into Rigor's internal carriers at the plugin
boundary, and contributes method signatures + flow assertions
through the existing `flow_contribution_for` substrate. Core
remains RBS-canonical per ADR-0 / ADR-1.

The user keeps `sorbet-runtime` for runtime checks
independently. Rigor reads the same `sig` blocks as static
input; the runtime story is unchanged.

### Why the plugin path, not core

Four design tensions push Sorbet input out of core:

1.  **ADR-0 § "No inline DSL in core."** The existing rule —
    "Application Ruby code stays free of Rigor-only annotation
    syntax. RBS, rbs-inline, and Steep-compatible annotations
    are accepted as type sources" — was about *Rigor's own*
    DSL. Sorbet's DSL isn't Rigor-defined, but accepting it
    in core would force every Rigor user to know Sorbet
    semantics. ADR-2's plugin contract was designed for
    exactly this situation: framework-shaped or third-party-
    DSL-shaped knowledge belongs to a plugin, not the core.

2.  **ADR-1 § "RBS round-trip is lossless."** Rigor → RBS
    erasure is the canonical export contract. Sorbet types
    have no clean RBS spelling for several constructs
    (`T::Class[T]`, `T.attached_class`, `T.self_type`,
    `T.type_parameter`, sealed/abstract markers, structural
    `T::Struct` shapes). Pulling Sorbet's vocabulary into
    core would either widen Rigor's internal carriers
    (mismatch with the spec corpus the user already
    authored) or accept lossy round-trips (mismatch with
    ADR-1's hard guarantee). Keeping translation at the
    *plugin* boundary lets the lossy edges live there: the
    plugin maps Sorbet → Rigor as best it can; what doesn't
    map degrades to `Dynamic[top]` with `dynamic.sorbet.*`
    provenance.

3.  **The Sorbet DSL is a real parser project.** Static-
    parsing `sig { params(x: Integer, y: T.nilable(String)).returns(String) }`
    requires a fluent-API mini-interpreter that walks a
    `Prism::CallNode` chain and recognises every `T.*`
    constant in `type_parameters` / `params` / `returns` /
    `void` / `bind` / `proc` / `class_of` / `attached_class`
    / `nilable` / `any` / `all` / etc. This is doable, but
    its surface area is large enough that maintaining it in
    core would crowd out core inference improvements.
    Project precedent: [Sord][sord] does roughly this for
    Sorbet → RBS conversion; we'd build a similar but
    Rigor-targeted parser inside the plugin.

4.  **Reuse the trusted-gem opt-in.** ADR-2's trust model
    treats plugins as user-selected gems. `rigor-sorbet`
    fits that model directly: users opt in by adding the
    gem to `.rigor.yml`'s `plugins:` list, exactly as they
    would for `rigor-pattern` or `rigor-statesman`. No new
    trust dimension is required.

[sord]: https://github.com/AaronC81/sord

### Static-vs-runtime decomposition

The user's preference for runtime-enforced types is genuine
and worth honoring, but Rigor's role in that story is small:

- **Static side (what `rigor-sorbet` provides)**: read
  `sig { ... }` blocks and `T.let` / `T.cast` / `T.must`
  / `T.bind` / `T.absurd` as type sources, contribute method
  signatures and flow assertions to the analyzer.
- **Runtime side (unchanged from Sorbet)**: `sorbet-runtime`
  wraps `sig`'d methods at load time and raises on
  violations. Rigor never executes application code (ADR-2
  § "Plugin Trust and I/O Policy"), so runtime enforcement
  is not a Rigor feature even with the plugin loaded.

Practically: a user who values runtime checks keeps
`sorbet-runtime` in their Gemfile; the same `sig` blocks
serve both purposes. Adding Rigor + `rigor-sorbet` gives
them a second-opinion static analyzer with the project's
own type-language extensions (`RBS::Extended` refinements,
plugin-derived dynamic members, etc.) layered on top.

## Translation table

The plugin maps Sorbet's vocabulary into Rigor's internal
carriers at the plugin boundary. Lossy mappings are flagged
explicitly so the plugin emits a `dynamic.sorbet.degraded` /
`dynamic.sorbet.unsupported` diagnostic when applied.

### Method signatures

| Sorbet form | Rigor representation | Notes |
| --- | --- | --- |
| `sig { params(x: T).returns(U) }` | RBS-shaped method type `(T) -> U` | direct |
| `sig { void }` | `(...) -> void` | direct |
| `sig { abstract.returns(T) }` | abstract-method fact + return type `T` | abstract marker captured |
| `sig { override.returns(T) }` | override fact + return type `T` | override-checking left to existing `def.return-type-mismatch` rule |
| `sig { overridable.returns(T) }` | overridable fact + return type `T` | direct |
| `sig(:final) { ... }` | final-method fact | per [final.md][sorbet-final] |
| `sig { type_parameters(:U).params(x: T.type_parameter(:U)).returns(T.type_parameter(:U)) }` | RBS generic method `[U] (U) -> U` | direct |
| `sig { ... .checked(...) }` | discarded by Rigor (runtime-only) | the `.checked` modifier is a runtime hint |
| `sig { ... .on_failure(...) }` | discarded | runtime-only |

[sorbet-final]: https://sorbet.org/docs/final

### Flow-level assertions

| Sorbet form | Rigor representation | Equivalent existing Rigor primitive |
| --- | --- | --- |
| `T.let(expr, T)` | `assert: expr is T` (post-return facts updated) | analogous to `%a{rigor:v1:assert: expr is T}` |
| `T.cast(expr, T)` | `assert: expr is T` (statically assumed) | analogous; both are unchecked statically |
| `T.must(expr)` | `assert: expr is ~nil` | analogous |
| `T.must_because(expr) { reason }` | same as `T.must` for typing purposes | reason ignored |
| `T.assert_type!(expr, T)` | `assert: expr is T` + reject `Dynamic[T]` | strict variant |
| `T.bind(self, T)` | `assert: self is T` | analogous |
| `T.absurd(x)` | `assert: x is bot` (exhaustiveness) | composes with existing `flow.unreachable-branch` |
| `T.unsafe(x)` | erase to `Dynamic[top]` | identity at runtime, untyped statically |
| `T.reveal_type(x)` | `dump.type` diagnostic at the call site | direct map |

### Type vocabulary

| Sorbet form | Rigor carrier |
| --- | --- |
| `T.any(A, B)` | `Union[A, B]` |
| `T.all(A, B)` | `Intersection[A, B]` |
| `T.nilable(T)` | `Union[T, nil]` |
| `T::Boolean` | `Union[Constant[true], Constant[false]]` |
| `T.untyped` | `Dynamic[top]` |
| `T.anything` | `top` |
| `T.noreturn` | `bot` |
| `T::Array[E]` | `Nominal["Array", [E]]` |
| `T::Hash[K, V]` | `Nominal["Hash", [K, V]]` |
| `T::Set[E]` | `Nominal["Set", [E]]` |
| `T::Range[E]` | `Nominal["Range", [E]]` |
| `T::Enumerable[E]` / `T::Enumerator[E]` / `T::Enumerator::Lazy[E]` | `Nominal["Enumerable", [E]]` etc. |
| `T::Class[T]` | `Singleton[T]` (lossy: drops attached-class precision) |
| `T::Module[T]` | `Module[T]` (introduce new carrier OR fall back to `Singleton`) |
| `T.class_of(C)` | `Singleton[C]` |
| `T.proc.params(x: A).returns(B)` | RBS `^(A) -> B` proc type |
| `[A, B]` (tuple in `sig`) | Rigor `Tuple[A, B]` |
| `{a: A, b: B}` (shape in `sig`) | Rigor `HashShape{a: A, b: B}` |
| `T.attached_class` | RBS `Bases::Instance` (instance-of-self) |
| `T.self_type` | RBS `Bases::Self` (best-effort; Sorbet's known limitations apply) |
| `T.type_parameter(:U)` | RBS `Variable[:U]` |

### Constructs that degrade to `Dynamic[top]` with provenance

These constructs have no clean Rigor analogue and emit
`dynamic.sorbet.unsupported` at the contribution site; the
call site retains the dynamic-origin marker so the user can
audit the boundary:

- **`T::Struct` / `T::ImmutableStruct`** — Sorbet's typed
  product types. Rigor's `HashShape` is the closest carrier,
  but property-level annotations (`prop`, `const`) are
  Sorbet-specific. Treated as a `Nominal[<UserDefined>]` plus
  best-effort instance-method inference; field-level types
  are plugin-supplied.
- **`T::Enum`** — Sorbet's typed enumerations. Rigor's
  closest match is a refinement of `Symbol` with a finite
  set, but the runtime semantics differ. Translated to a
  `Nominal[<UserDefined>]` with the enum constants exposed
  as `Singleton[T]` instances.
- **`T::Generic` `type_member` / `type_template`** —
  variance markers (`:in` / `:out` / `:invariant`) and
  bounds (`fixed` / `upper` / `lower`) translate when
  expressible in RBS; complex bounds (`fixed: T.any(A, B)`)
  fall back to `Dynamic[top]` for the affected slot.
- **`T.experimental_*`** namespace — by Sorbet's own
  contract these are unstable; the plugin treats them as
  unsupported.
- **Sorbet sigils** at strictness level `# typed: strong`
  — translates as "no `Dynamic[T]` allowed in this file"
  but Rigor's permissiveness model is set per `severity_profile`.
  Translated by *honoring the sigil for parse + rejection
  decisions* but not re-implementing strong-mode in Rigor.

### Sigil handling

Sorbet sigils control which errors Sorbet reports per file
([static.md][sorbet-static]); they're orthogonal to Rigor's
own analysis. The plugin honors the sigils in three steps:

| Sigil | `rigor-sorbet` action |
| --- | --- |
| `# typed: ignore` | Skip the file entirely (matches Sorbet's behaviour). |
| `# typed: false` | Read `sig` blocks for *signature contributions only* (Sorbet says signatures still apply); skip flow assertions / `T.let` etc. |
| `# typed: true` (default) | Honor everything: signatures + assertions + flow facts. |
| `# typed: strict` | Same as `true`. (Sorbet's strict-mode requirement that every method has a sig is enforced by `srb tc` itself; Rigor doesn't replicate it.) |
| `# typed: strong` | Same as `strict`. (Strong-mode rejection of `T.untyped` is a Sorbet-specific stance; Rigor's `severity_profile` covers the analogous filter.) |

[sorbet-static]: https://sorbet.org/docs/static

### Composition with RBI files

Sorbet's [RBI files][sorbet-rbi] are stub-body Ruby files
under `sorbet/rbi/` that declare external types (gems, DSLs,
etc.) without runtime impact. The plugin walks the RBI tree
in addition to project source:

- `sorbet/rbi/gems/` — autogenerated from `tapioca gems`.
  Composes naturally with [ADR-10][adr-10]'s opt-in
  dependency-source inference: when the user has both an
  RBI file for a gem and that gem listed under
  `dependencies.source_inference`, the RBI's typed
  signatures win (it's a contract); the inference walker
  fills holes the RBI doesn't cover.
- `sorbet/rbi/annotations/` — community annotations from
  [`rbi-central`][rbi-central].
- `sorbet/rbi/dsl/` — autogenerated DSL RBIs (Rails-style).
  Lower priority than first-party Rigor plugins
  (`rigor-activerecord`, `rigor-rails-routes`, etc.) when
  both are loaded; the DSL plugin's contributions are
  authored, the RBI is generated.
- `sorbet/rbi/shims/` — hand-edited overrides. Same priority
  as project `sig/` RBS in the existing tier ordering.

[sorbet-rbi]: https://sorbet.org/docs/rbi
[adr-10]: 10-dependency-source-inference.md
[rbi-central]: https://github.com/Shopify/rbi-central

## Boundary with ADR-1 (RBS round-trip)

Sorbet types translate **into** Rigor's internal carriers at
plugin load time. The reverse direction — Rigor → Sorbet
export — is **not** part of this ADR. Rigor → RBS export
remains lossless / conservative per ADR-1; users who want
Sorbet sigs from Rigor's inference can use Sord (or a future
Rigor-specific equivalent) as a separate authoring tool, but
that tool isn't a normative output of the analyzer.

This means the plugin's translation table is one-way and
plugin-internal. If a Sorbet construct doesn't translate
(`T::Struct` properties, `T.attached_class` in deeply
nested generic positions, etc.), the plugin emits
`dynamic.sorbet.unsupported` and degrades the affected slot
to `Dynamic[top]`. Core never sees Sorbet-only carriers.

## Boundary with ADR-0 (no Rigor-specific inline DSL)

ADR-0 says "Ruby application code MUST NOT require
Rigor-specific annotations or DSLs." This ADR doesn't
violate that:

- Rigor still introduces no DSL of its own.
- The `sig { ... }` and `T.*` syntax is **Sorbet's** DSL,
  authored independently of Rigor. Users who want it
  install `sorbet-runtime` (for runtime support) +
  `rigor-sorbet` (for Rigor's static reading); both are
  user choices.
- Users who don't want a DSL keep using RBS / RBS::Inline
  per the existing path.

The user who proposed this ADR explicitly framed it as
"plugin-via-adapter," which is the correct framing.

## Plugin contract surface

`rigor-sorbet` uses the existing v0.1.0 plugin contract
plus the [ADR-9 cross-plugin API][adr-9] when it lands:

- **`Plugin::Base#flow_contribution_for(call_node:, scope:)`**:
  consulted at every call site. The plugin walks the
  surrounding scope for `sig { ... }` blocks above the
  callee's `def`, parses the sig, and contributes a
  `FlowContribution` with `return_type` set per the sig.
- **`Plugin::Base#diagnostics_for_file(path:, scope:, root:)`**:
  emits `dump.type` for `T.reveal_type(x)` calls, and
  `dynamic.sorbet.unsupported` for constructs the
  translation table doesn't cover. `T.absurd(x)` composes
  with the existing `flow.unreachable-branch` rule.
- **`Plugin::Base#prepare(services)`** (ADR-9 slice 3):
  the plugin walks the project's `.rb` files once at run
  start, builds a per-class table of `(class_name, method_name) → MethodType`
  from the discovered `sig` blocks, and publishes it on
  the fact store as `rigor-sorbet#method_signatures`.
  Subsequent files consume these via the dispatcher.
- **`manifest(produces: [:method_signatures], consumes: [...])`**:
  declares the fact-store contract. Other plugins that
  want to read Sorbet sigs (e.g., a hypothetical
  `rigor-rails` plugin reading Rails-via-Sorbet types)
  declare `consumes: [{ plugin_id: "sorbet", name: :method_signatures }]`.

[adr-9]: 9-cross-plugin-api.md

## Diagnostic prefix family

This ADR adds a new `plugin.sorbet.*` family for plugin-
emitted diagnostics, plus the `dynamic.sorbet.*` family for
boundary-crossing facts. Initial entries:

| Identifier | Meaning |
| --- | --- |
| `plugin.sorbet.parse-error` | A `sig { ... }` block did not parse. |
| `plugin.sorbet.unknown-modifier` | A `sig` modifier (e.g., `.foo` chained on the sig) was not in the recognised set. |
| `plugin.sorbet.duplicate-sig` | More than one `sig` was attached to the same method. |
| `dynamic.sorbet.degraded` | A type translated to a wider Rigor carrier than the original Sorbet type would express; the call site retains dynamic provenance. |
| `dynamic.sorbet.unsupported` | The Sorbet construct has no Rigor analogue; degraded to `Dynamic[top]`. |

The taxonomy slot in
[`docs/type-specification/diagnostic-policy.md`](../type-specification/diagnostic-policy.md)
already accommodates `plugin.<id>.*` and `dynamic.*`; no
spec change is required.

## Implementation slicing

The plugin lives under `examples/rigor-sorbet/` while the
contract stabilises, then extracts via `git subtree split`
per the existing pattern (see
[Rails plugins roadmap][rails-roadmap]). Recommended order:

1.  **`sig { params(...).returns(...) }` parser.** Mini-
    interpreter over `Prism::CallNode` chains; covers
    `params` / `returns` / `void` / `void.checked(...)` /
    `abstract` / `override` / `overridable` / `final`.
    Plugin contributes method types; integration spec
    proves a chained call resolves through the sig.
2.  **`T.let` / `T.cast` / `T.must` / `T.bind`.** Recogniser
    that lifts these into the plugin's `flow_contribution_for`
    output. Composes with the existing
    `%a{rigor:v1:assert:}` machinery.
3.  **Type vocabulary translator.** Maps
    `T.any` / `T.all` / `T.nilable` / `T::Array` / `T::Hash` /
    `T::Boolean` / `T.untyped` / `T.anything` / `T.noreturn` /
    `T.proc` / `T.class_of` / `T.type_parameter` (the dense
    middle of the table above). Each missing token degrades
    with `dynamic.sorbet.unsupported`.
4.  **RBI directory walker.** Reads `sorbet/rbi/**/*.rbi`,
    treats them as Ruby source with stub method bodies,
    feeds the parsed sigs into the same fact store as
    project-source sigs.
5.  **Sigil honoring + dispatcher tier ordering.**
    `# typed:` sigil affects what the plugin contributes
    per file; tier ordering with respect to RBS / project
    sig / `RBS::Extended` is documented (RBS still wins on
    conflict; Sorbet sigs sit at the same tier as project
    `sig/` RBS).
6.  **`T.absurd` exhaustiveness wiring.** Composes with
    `flow.unreachable-branch`. Diagnostic identifier:
    `plugin.sorbet.absurd-reachable`.
7.  **Documentation update.** New
    `examples/rigor-sorbet/README.md` and a chapter in
    `docs/handbook/` covering the adapter for users who
    arrive from a Sorbet-using project. Cross-link from
    [`docs/handbook/01-getting-started.md`](../handbook/01-getting-started.md)'s
    "When inference is not enough" escape hatches.
8.  **Mixin chain resolution (Tapioca DSL compatibility).**
    Slice 4's RBI walker records sigs verbatim under their
    declaring class/module. This works for hand-written
    sig+def pairs but misses Tapioca's standard pattern of
    declaring the sig on a generated module and `include` /
    `extend`-ing that module into the user class:

    ```rbi
    class Post
      include GeneratedAttributeMethods
      module GeneratedAttributeMethods
        sig { returns(String) }
        def body; end
      end
    end
    ```

    The catalog stores this under
    `("Post::GeneratedAttributeMethods", :body, :instance)`,
    but the user-facing `post.body` lookup is
    `("Post", :body, :instance)`. The slice extends
    `Catalog` with `mixins_for(class_name) → {include: [...],
    extend: [...]}`, teaches `CatalogWalker` to record
    `include` / `extend` declarations alongside `sig` /
    `def` pairs, and walks the recorded mixin chain on
    lookup. `extend` lookups consult the mixed-in module's
    instance side (matching Ruby's runtime behaviour:
    `extend M` lifts M's instance methods to singleton
    methods of the extending class).

    The pattern isn't Tapioca-specific — hand-written
    shims in `sorbet/rbi/shims/` and community
    annotations in `rbi-central` use the same shape. The
    slice closes the gap for every RBI consumer, not just
    Tapioca users. See [`20260509-rigor-tapioca-investigation.md`](../design/20260509-rigor-tapioca-investigation.md)
    for the design exploration that decided to land this
    inside ADR-11 instead of as a separate
    `rigor-tapioca` plugin.

[rails-roadmap]: ../design/20260508-rails-plugins-roadmap.md

## Working decisions

### WD1 — Why one plugin covers both `sig` and `T.let`?

The two surfaces share a parser (Sorbet's type vocabulary
is the same in both `sig` blocks and `T.let` arguments).
Splitting them across two plugins would duplicate the
translator and create artificial boundaries between method-
level and statement-level facts. One plugin, two
contribution tiers.

### WD2 — Why honor sigils?

Without sigil honoring, the plugin would surface signatures
from `# typed: ignore` files that Sorbet itself ignores.
This breaks the "Sorbet sees X, Rigor sees Y" expectation
and creates spurious diagnostics on files the user
deliberately excluded from typing. The cost is minimal —
the sigil is a single regex on the file's first non-blank
line.

### WD3 — Why is RBS-vs-Sorbet conflict resolution
RBS-wins?

ADR-1 fixes RBS as the canonical contract. When both an
RBS sig and a Sorbet sig describe the same method, RBS
wins per the existing tier ordering. Users who want
Sorbet's sig to override should remove the conflicting RBS,
not the other way around. The reverse direction (Sorbet
wins) would let third-party-DSL annotations override
authored RBS, which inverts the trust model.

### WD4 — Why a separate `dynamic.sorbet.*` family for
unsupported constructs?

Per ADR-2 § "Plugin Diagnostic Provenance", plugins emit
under `plugin.<plugin-id>.*` for plugin-authored
diagnostics. The `dynamic.sorbet.*` family is reserved for
*type-level* facts about boundary crossings (similar to
ADR-10's `dynamic.dependency-source.*`). Construct-level
parse / authoring errors (e.g., a malformed sig block) use
`plugin.sorbet.*`. Both prefixes coexist.

### WD5 — Why don't we ship a Sorbet → RBS converter?

Sord already exists. Building a Rigor-specific equivalent
would duplicate effort and put Rigor on the wrong side of
the static-vs-runtime decomposition (a converter is an
authoring tool, not an analyzer). Users who want offline
RBS generation use Sord; users who want online type-source
reading use `rigor-sorbet`.

### WD6 — Will Rigor support runtime checking like
`sorbet-runtime`?

No. ADR-2 § "Plugin Trust and I/O Policy" prohibits Rigor
from executing application code. The runtime story remains
`sorbet-runtime`'s — users who want runtime type checks add
`sorbet-runtime` to their Gemfile and Rigor reads the same
sigs statically. The two analyses are independent and
compose.

## Alternatives considered

| Candidate | Status | Reason |
| --- | --- | --- |
| Add Sorbet vocabulary to core type carriers | Rejected | Violates ADR-0 / ADR-1; bloats core; lossy round-trips would force a spec rewrite. |
| Read Sorbet RBI files only (skip inline `sig`) | Rejected | RBI files are stubs for external code; the user's primary value is reading inline `sig` on first-party code. |
| Auto-translate `sig` blocks to RBS at parse time, then run the existing engine | Rejected | The translation is lossy at the boundary anyway, and doing it per-parse would recompute the translation continuously. Plugin-side translation caches per gem version (composes with ADR-10's cache). |
| Build runtime-enforcement into Rigor | Rejected | ADR-2 prohibits it; orthogonal to static analysis; Sorbet's own runtime gem already does it. |
| Vendor `sorbet-runtime` semantics in the plugin | Rejected | The plugin reads sigs but does not execute them; it has no runtime side effects. |
| One plugin per Sorbet feature (`rigor-sorbet-sig`, `rigor-sorbet-let`, …) | Rejected | Duplicates the parser and creates artificial boundaries. |

## Open questions

- Should `rigor-sorbet` participate in [ADR-10][adr-10]'s
  opt-in dependency-source inference? When both an RBI
  file AND opt-in source inference are available for a
  gem, the RBI's typed signatures should win and the
  walker fills gaps. The implementation order suggests
  ADR-10's slice 5 (cache descriptor) lands first; revisit
  composition after that.
- Should `T.reveal_type` map to Rigor's `dump.type`
  diagnostic 1:1, or get its own `plugin.sorbet.reveal-type`
  identifier? Decision deferred to slice 3 — start with
  `dump.type` and split if the noise becomes a problem.
- Should the plugin attempt to read Sorbet's
  `sorbet/config` file (e.g., to honor `--ignore` paths)?
  Decision deferred — start with reading sigils only;
  config-file integration is a polish slice.
- Should the plugin emit migration suggestions for
  Sorbet → Rigor refinements? E.g., `T.must(x.foo)` could
  suggest `%a{rigor:v1:assert: x.foo is ~nil}`. Decision
  deferred to a separate ADR if user demand surfaces.

## Revision history

- 2026-05-09 — initial proposal. Triggered by user request
  to support Sorbet sigs / `T.let` / `T.cast` as
  type-inference sources, with a stated preference for
  runtime-enforced types in the PHP style. Resolution:
  plugin adapter, not core integration.
- 2026-05-09 — added slice 8 (mixin chain resolution).
  Triggered by the Tapioca-comparison investigation which
  surfaced that Tapioca-generated DSL RBIs declare sigs on
  `Generated*` modules `include`d / `extend`ed into the
  user class. Slice 8 lands inside ADR-11 rather than as
  a separate `rigor-tapioca` plugin because the underlying
  semantics (mixin chain traversal during method lookup)
  are general RBI handling, not Tapioca-specific.
