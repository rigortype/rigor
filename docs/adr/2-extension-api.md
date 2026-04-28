# ADR-2: Extension API Strategy

## Status

Draft

## Context

Rigor should keep the core analyzer small while still handling Ruby frameworks, generated APIs, DSLs, and metaprogramming. PHPStan is the strongest reference point for this part of the design because its extension API gives framework authors precise ways to contribute type facts, reflection facts, rules, and infrastructure behavior without changing the analyzed application code.

The PHPStan reference material for this ADR is `references/phpstan/website/src/developing-extensions/`, especially:

- `dynamic-return-type-extensions.md`
- `type-specifying-extensions.md`
- `type-system.md`
- `scope.md`
- `reflection.md`
- `extension-types.md`
- `dependency-injection-configuration.md`
- `testing.md`

Rigor should model the architecture, not the PHP names, PHPDoc syntax, or PHP runtime assumptions.

## Working Decision

Rigor's extension API should be PHPStan-like: a set of small, typed extension protocols registered by configuration or plugin manifests. Each extension receives immutable analysis context objects such as AST nodes, `Scope`, reflection objects, and `Type` values, then returns either a precise contribution or `nil`/empty results to let the core analyzer continue with default behavior.

Plugins must not execute application code. They may inspect parsed Ruby, RBS, generated signatures, configuration, dependency metadata, and cached plugin metadata.

The core API should start with the extension points that improve type inference and metaprogramming support:

- Dynamic return type extensions.
- Type-specifying extensions for flow narrowing.
- Dynamic member reflection for methods, attributes, constants, and object shapes.
- Custom rules and restricted-usage checks.
- Result-cache metadata and diagnostics.

## PHPStan Extension Surface

| Category | PHPStan feature | Rigor implication |
| --- | --- | --- |
| Foundations | AST, Scope, Type System, Trinary Logic, Reflection, DI and configuration. | Rigor needs stable object models for Prism AST access, flow scope snapshots, type queries, analyzer reflection, three-valued certainty, service construction, and plugin configuration. |
| Custom rules | `Rule<TNode>` runs on a selected AST or virtual node and returns diagnostics. Collectors aggregate cross-file facts before rules run on `CollectedDataNode`. | Rigor should support node-scoped rules first, then cross-file collectors once parallel analysis and caching mature. Diagnostics should carry identifiers, file, line, and severity. |
| Restricted usage | Specialized hooks restrict methods, properties, functions, class names, constants, or similar symbols without writing full AST rules. | Rigor should provide simpler symbol-use hooks for access-policy checks such as internal APIs, generated classes, Rails-only entry points, or test-only helpers. |
| Type inference | Dynamic return type, dynamic throw type, type-specifying, closure, parameter-out, expression resolver, operator type, and custom PHPDoc type extensions. | Rigor should prioritize return inference, flow facts, block/proc context, expression fallback, and custom RBS-extended type parsing. PHP by-reference parameter hooks map to Ruby mutation/effect hooks instead. |
| Metadata | Class reflection extensions, custom deprecations, allowed subtypes, additional constructors, exception classification, conditional stub files. | Rigor should let plugins contribute dynamic Ruby members, sealed-like subtype facts, initialization methods, deprecation/internal metadata, exception policy, and generated or conditional RBS. |
| Dead-code support | Always-read/written properties, always-used constants, always-used methods. | Rigor should defer most dead-code extension points, but the model is useful for Rails, serializers, ORM fields, callbacks, and reflection-heavy code. |
| Output and infrastructure | Error formatters, ignore-error extensions, diagnose extensions, result-cache metadata extensions, extension testing. | Rigor should support cache invalidation metadata and plugin diagnostics early. Custom formatters and ignore hooks can wait until the CLI output model is stable. |

The important design pattern is consistent across the PHPStan API: a narrow extension declares what it supports, receives the current `Scope` and reflection/type objects, and returns a domain object. Broad extension points exist, but PHPStan recommends using the narrowest hook that fits.

## Scope Object

PHPStan's `Scope` represents the analyzer state at the current AST position. It can answer expression type queries, identify the current file, namespace, class, trait, function, method, or closure, and resolve context-sensitive names such as `self`.

Rigor should provide a similar immutable `Scope` object. It should expose:

- `type_of(node)` for expression type queries.
- `analyze_condition(node)` or an equivalent analyzer-owned operation that can produce truthy, falsey, normal, exceptional, and unreachable output scopes.
- Current file, lexical nesting, class/module singleton context, method, block, and visibility context.
- Current receiver type and known local, instance-variable, class-variable, global, constant, and shape facts.
- Value facts, negative facts, relational facts, member-existence facts, shape facts, dynamic-origin provenance, and fact-stability metadata.
- Name and constant resolution helpers for Ruby lexical lookup.
- Flow-edge context such as truthy branch, falsy branch, assertion context, rescue context, and unreachable context.

Extensions should not mutate `Scope` directly. They should return facts, diagnostics, synthetic nodes, or metadata to the analyzer, which applies them through normal control-flow machinery.

The scope model must be precise enough for short-circuiting conditions. If a plugin-defined predicate appears on the left side of `&&`, its true-edge facts must be visible while analyzing the right side. If it appears on the left side of `||`, its false-edge facts must be visible while analyzing the right side.

The minimal first implementation surface for `Scope` is intentionally narrow:

- Type queries: `type_of(target)` returns the current narrowed type for a supported target.
- Relational queries with trinary results: `has_member?(target, name)`, `has_key?(target, key)`, and `equals?(target, value)` return `yes`, `maybe`, or `no` so plugins can ask for relational facts without forcing them into types.
- Edge-aware narrowing: plugins receive separate truthy and falsey scopes for the conditions they participate in, rather than reading flags off a single mutable `Scope`.

A small `ContextInfo` companion object exposes lexical context that does not belong on `Scope` itself, including current file, surrounding class or module, current method, current visibility scope, and whether the call is being analyzed inside a private, protected, or assertion context. Plugin authors should treat it as descriptive only; analyzer state never flows back into `ContextInfo`.

Target paths accepted in the first plugin milestone are restricted to `self`, named parameters, named locals proven stable in the current scope, and stable receiver members where the receiver is itself a stable target. More expressive paths such as hash keys, tuple elements, instance variables, and method-result chains stay internal until fact-stability rules generalize.

## Type System Object Model

PHPStan represents every type as an object implementing a common `Type` interface. Types answer capability and relationship queries such as `isSuperTypeOf`, `accepts`, `hasMethod`, `getMethod`, `hasProperty`, and `describe`. These answers often use trinary logic rather than booleans.

Rigor should adopt the same style:

- Type objects are ordinary immutable value objects.
- Relationship queries return `yes`, `maybe`, or `no` where uncertainty is meaningful.
- Extensions should ask semantic questions such as `StringType.supertype_of?(type)` rather than checking concrete implementation classes.
- Type constructors should normalize through combinators, for example union, intersection, difference, and erasure helpers.
- Custom type-like refinements should implement relationship, normalization, display, and RBS erasure behavior.

`yes` and `no` are reserved for results that are proven under the current source, accepted signatures, plugin facts, and analyzer assumptions. `maybe` means the analyzer cannot prove either side. Accepted method signatures still define trusted method-boundary contracts: parameters and called method return values are analyzed through their accepted RBS, rbs-inline, Steep-compatible, generated, or `RBS::Extended` contracts rather than treated as uncertain merely because the implementation is outside the current method.

`maybe` is not enough to narrow as though a relationship were `yes`, and it does not imply the opposite edge as though the answer were `no`. It may be retained as a weak relational, member-existence, dynamic-origin, or plugin-provenance fact for diagnostics. Whether maybe-dependent calls are reported is an error-level policy, similar in spirit to PHPStan: permissive levels may accept them silently, while stricter levels can report uncertain method calls, role matches, or branch proofs.

This matters because a type such as `non-empty-string` may be represented as a string plus an accessory refinement, and a union of string literals should still answer as a string. Extension authors should not need to know every concrete internal representation.

## Reflection Objects

PHPStan has an analyzer-owned reflection layer for functions, classes, properties, methods, constants, and PHPDocs. Reflection can come from source, native symbols, stubs, or extension-provided magic members. Methods and functions expose callable variants, and call-site arguments select the applicable variant.

Rigor should expose an analyzer reflection layer separate from Ruby runtime reflection. It should combine:

- Ruby source declarations.
- RBS declarations.
- Generated RBS or plugin-provided signatures.
- Core and standard library signatures.
- Dynamic members contributed by plugins.

Reflection objects should cover classes, modules, singleton class objects, methods, attributes, constants, aliases, interfaces, and object shapes. They should distinguish native/source members from plugin-provided dynamic members where diagnostics need that explanation. Method reflection should expose overloads and a call-site selector that understands Ruby positional, keyword, block, rest, and forwarding arguments.

## Dynamic Return Type Extensions

PHPStan dynamic return type extensions are used when the return type of a function or method depends on the call-site arguments. The extension declares the target class/function, checks whether a method is supported, and receives the method reflection, call AST node, and scope. It returns a `Type` or `null` to fall back to the default return type.

Rigor should use the same shape for Ruby method calls:

- A dynamic return extension declares the receiver family it supports, such as a nominal class, module singleton, interface, object shape, or plugin-defined virtual receiver.
- It receives method reflection, call node, receiver type, argument nodes, block information, and scope.
- It may inspect argument types or literals with `scope.type_of`.
- It returns a type, a typed effect bundle, or `nil` for default behavior.

This hook is appropriate for APIs such as containers, ORMs, factories, schema-backed accessors, `Hash#fetch`-like wrappers, and framework query builders. If ordinary RBS overloads, generics, or `RBS::Extended` conditional return metadata are enough, those should be preferred over custom code.

A typed effect bundle may include the normal return type, receiver or argument mutation facts, introduced dynamic members, thrown or non-returning control-flow facts, and fact invalidations. This keeps Ruby APIs such as builders, validators, schema loaders, and memoized dynamic accessors expressible without allowing extensions to edit `Scope`.

## Type-Specifying Extensions

PHPStan type-specifying extensions provide flow facts based on calls to type-checking functions or methods. They receive the call node, method/function reflection, scope, and a context object that says whether the call is being evaluated as truthy, falsy, null, or as an assertion. They return `SpecifiedTypes`, often through a central `TypeSpecifier`.

Rigor should make this a first-class extension family because Ruby code often narrows through predicate and assertion APIs:

- Predicates such as `nil?`, `is_a?`, `kind_of?`, `instance_of?`, `respond_to?`, custom `foo?` methods, and framework guards.
- Assertion methods such as `assert`, `raise unless`, test-framework assertions, contract helpers, and validation libraries.
- Pattern-style or relation-style APIs that prove facts about receiver members, hash keys, or method results.

The extension result should describe positive and negative facts separately. It should also support a true-only form when the false branch does not imply the complement, matching PHPStan's distinction between equality-like assertions and one-sided predicates.

Rigor also needs relation-aware facts for Ruby-specific guards. Some calls prove `target is T`; others prove only `target == literal`, `target responds_to method`, `hash has key`, or `receiver.member is stable`. The extension API should preserve this difference so the core analyzer can decide whether the fact can be reduced to a type, kept as a relation, or invalidated after mutation.

## Dynamic Reflection and Magic Members

PHPStan class reflection extensions describe magic properties and methods exposed through `__get`, `__set`, `__call`, and similar mechanisms. The reflection layer asks registered extensions when native reflection cannot find a member.

Rigor needs the same capability for Ruby's `method_missing`, `respond_to_missing?`, `define_method`, Rails-style generated methods, ActiveRecord attributes, enum helpers, associations, serializers, delegated methods, and DSL-generated constants.

Rigor dynamic reflection extensions should contribute method, attribute, constant, and shape members with ordinary reflection objects. Those reflection objects should expose readable and writable types, method overloads, visibility, deprecation/internal facts, side-effect facts, and source/provenance for diagnostics.

Dynamic reflection must support structural interface checking, not only member lookup. A plugin-provided member should expose enough signature and certainty information for Rigor to decide whether a nominal type or object shape satisfies an RBS interface. A `respond_to_missing?`-style fact may be useful for a guarded send while still being too weak for full interface conformance.

The same mechanism should support capability roles for standard and framework objects. For example, `IO` and `StringIO` can both satisfy readable or rewindable stream interfaces without either becoming a subtype of the other. A standard-library fact provider or plugin should be able to contribute role conformance, member signatures, and role-specific exclusions such as file-descriptor-backed behavior.

Rigor should ship an opinionated core catalog of common standard-library capability roles, such as readable stream, writable stream, rewindable stream, seekable stream, closable, enumerable, callable, and file-descriptor-backed. Plugins may add roles, additional conformance facts, role-specific exclusions, and `maybe` conformance, but they should not silently replace the core catalog.

## Reflection Layer Rebuilds

The reflection layer should be layered by input source rather than rebuilt as one monolithic table. The initial layers are core and standard-library signatures, project source declarations, accepted RBS and inline signatures, generated signatures, and plugin-provided dynamic members.

Each reflection contribution should have a stable identity and cache key at the narrowest practical slice: class or module declaration, singleton object, member entry, shape provider, generated signature unit, or plugin dynamic-member provider. A single edited source file should invalidate the affected declaration and member slices, not every plugin fact or every reflected class.

Plugin-provided dynamic members must carry provenance and dependency descriptors. If a Rails plugin builds members from schema files, model source, plugin configuration, and gem versions, those inputs belong to the dynamic-member cache key. Stable dynamic members may be reused across files and runs; members that depend on the analyzed file or call-site context should be recomputed at that narrower analysis point.

## Broad Expression and Operator Hooks

PHPStan has catch-all expression type resolver extensions and operator type specifying extensions. Its documentation recommends narrow hooks, such as dynamic return type extensions, when possible.

Rigor should keep broad expression hooks behind a higher bar because they can make analysis order and performance harder to reason about. They are still useful for Ruby constructs that do not fit method-call hooks, such as custom `[]` access, pattern-matching helpers, DSL literals, or operator-like methods whose meaning is framework-specific.

The first public plugin milestone should defer broad expression and operator hooks unless a concrete framework use case cannot be represented by narrower hooks. When introduced, broad hooks must come with traversal-order guarantees, invocation budgets, timeouts or cancellation behavior, and a diagnostic tracing mode that shows which hook affected an expression.

## Flow Contribution Bundle

Plugins, `RBS::Extended` annotations, and built-in narrowing rules all hand the analyzer the same kind of object: a bundle of facts and effects produced at a single call edge. The bundle is the public packaging of the flow contribution semantics owned by ADR-1.

The minimal first implementation public bundle is a single struct with optional slots:

- `return_type`: normal-edge return type.
- `truthy_facts`, `falsey_facts`: facts that hold only on the corresponding control-flow edge.
- `post_return_facts`: facts that hold after the call returns normally on any edge, used for assertions.
- `mutations`: receiver and argument mutation effects.
- `invalidations`: targeted fact invalidations beyond what mutations imply.
- `exceptional`: non-returning, raising, or unreachable effects.
- `role_conformance`: capability-role conformance facts when the contribution provides them.
- `provenance`: source family, plugin id, annotation node, and any cache descriptor required for incremental rebuilds.

A field that is left unset means the contribution does not assert anything in that slot. The struct is the only shape plugin authors need to learn; richer or more permissive shapes are not part of the first public contract.

Internally the analyzer flattens each bundle into a tagged element list keyed by `(target, flow edge, effect kind)` before running the merge policy described below. The flattening is mechanical, deterministic, and round-trippable: a bundle and its element list represent the same contribution. Plugin authors should not rely on the element-list form, but it is the natural implementation of `Plugin Contribution Merging` because compatible elements compose by their tags and conflicts surface as duplicate elements with incompatible payloads.

## Plugin Contribution Merging

Multiple flow contributions can target the same call: a built-in narrowing rule and a plugin-provided fact may apply at the same site, two plugins may both register for the same receiver family, and `RBS::Extended` annotations may add their own facts. Rigor merges these contributions deterministically rather than letting any one source silently override another.

Extensions do not override `Scope`, method reflection, or the selected RBS contract directly. They return provenance-bearing contributions that the analyzer merges through the same control-flow machinery as built-in rules.

Authority tiers are explicit:

- Core Ruby semantics and accepted ordinary RBS, rbs-inline, and Steep-compatible contracts are authoritative.
- `RBS::Extended` annotations and generated metadata may refine those contracts.
- Plugins may refine compatible analyzer facts.
- Lower tiers must not weaken or contradict higher tiers. Lower-tier contributions that contradict a higher tier are diagnostics, not silent overrides.

Plugin order within the same tier is deterministic: project configuration order after dependency constraints are satisfied, with plugin identifier order as the tie-breaker. The first public API does not expose ad hoc priority fields.

Compatible contributions compose by target, flow edge, and effect kind:

- Positive type facts on the same target and edge are intersected. "Compatible" means the intersection of value domains does not collapse to `bot`; intersections that do collapse are conflicts.
- Negative and relational facts accumulate under the normal fact budgets defined in ADR-1.
- Return types from dynamic return extensions are checked against the selected signature. A plugin may narrow within the contract; an incompatible return is a conflict diagnostic, not a contract override.
- Mutation, escape, and invalidation effects are unioned conservatively. Effect declarations that cannot both be true, such as `pure` combined with a receiver-mutation effect, are conflicts.

Contradictions are diagnostics, not first-wins or last-wins behavior. When two same-tier contributions conflict, Rigor reports both sources and falls back to the nearest non-conflicting higher-tier or default fact for that target and edge.

Truthy-edge and falsey-edge facts stay edge-local. A plugin's true-edge fact does not imply the false-edge complement unless the contribution explicitly supplies it or a trusted core rule derives it. Plugins that want PHPStan `@phpstan-assert`- or TypeScript `is`-style two-edge narrowing should declare both edges explicitly, for example with paired `predicate-if-true` and `predicate-if-false` effects.

Repeated `maybe` results remain `maybe` unless a stronger proof is supplied. Counting two uncertain plugin answers is not enough to promote a relationship to `yes`. Certainty changes only when a contribution supplies a stronger proof or the core analyzer can derive one from compatible facts.

This gives plugin authors a predictable rule: contributions refine the existing Ruby/RBS contract, and conflicts are reported rather than silently ordered away.

## Plugin Diagnostic Provenance

Diagnostics that depend on plugin, generated, or `RBS::Extended` contributions should expose stable identifiers, similar to PHPStan error identifiers. Public identifiers should use source-family prefixes, for example `plugin.<plugin-id>.<name>`, `rbs_extended.<name>`, or `generated.<provider>.<name>`.

The public identifier is not the whole provenance model. Internally, facts, effects, and diagnostics should retain source tier, plugin identifier, plugin version, configuration source, dependency descriptors, target path, effect kind, and contributing reflection or signature object where available. This richer data supports explanations, cache invalidation, and future suppression policies.

Diagnostic de-duplication should use a normalized key such as diagnostic identifier, location, target path, normalized fact or effect kind, and contributing source family. When several plugins contribute the same conflicting fact, Rigor should report one diagnostic with multiple sources rather than repeating the same message.

## Registration, Configuration, and Caching

PHPStan registers extensions as services with tags. Services are long-lived objects constructed by dependency injection; value objects such as types, scopes, and reflections are created during analysis or returned from services. PHPStan also validates custom configuration parameters with schemas.

Rigor should use plugin manifests and project configuration to register extension services. The initial design should include:

- Extension protocol identifiers rather than ad hoc method-name discovery.
- Constructor injection for analyzer services such as reflection providers, type factories, loggers, and configuration readers.
- Explicit plugin configuration schema so typos are diagnostics.
- Deterministic extension ordering.
- Declarative cache dependency descriptors so plugins can invalidate results when external schemas, generated files, gem versions, plugin versions, or configuration change.

Cache dependencies should be explicit descriptors rather than an after-the-fact list of arbitrary reads. The first implementation uses a typed-slot schema with a fixed set of slots and per-entry comparators, rather than a flat list of kind-tagged entries:

- `files`: project or external file inputs. Each entry carries a path and a digest or mtime policy.
- `gems`: gem name and version constraint or pinned version.
- `plugins`: plugin identifier and pinned plugin gem version.
- `configs`: configuration keys and a hash of their accepted value, so a toggled feature flag invalidates only the depending slice.

A descriptor attaches to the contribution or reflection slice it produced. Plugin-wide dependencies are allowed when the fact truly depends on the whole plugin configuration, but the preferred granularity is per dynamic-member provider, generated signature unit, receiver family, analyzed file, or flow contribution. This keeps one edited schema or fixture from invalidating the entire result cache. Adding a new dimension such as environment variables is an explicit schema change and should be accompanied by an ADR update.

## Plugin Trust and I/O Policy

Plugins must not execute application code. They may inspect parsed Ruby, RBS, generated signatures, project configuration, dependency metadata, and cached plugin metadata.

The first implementation should treat plugins as trusted Ruby gems selected by the user, their Gemfile, or project configuration. Rigor should document that trust model rather than pretending ordinary in-process Ruby plugins are sandboxed. Future implementations may explore stronger isolation such as Ruby::Box or process isolation, but that is not part of the first public plugin contract.

During analysis, network access should be disabled by default for determinism. File reads should normally be scoped to the project root, configured generated files, dependency metadata, and installed gem metadata. Reads outside those areas require explicit configuration and should be reflected in cache dependency descriptors.

Plugin failures should be isolated at the analyzer boundary. A plugin exception should become a plugin diagnostic with provenance and, where possible, should degrade only the affected contribution rather than crashing `rigor check`.

## Testing and Compatibility

PHPStan provides test bases for rules and type inference extensions. Rule tests assert diagnostics in fixture files. Type inference tests assert inferred types in ordinary analyzed code.

Rigor should provide the same two test styles:

- Rule tests that analyze fixture files and assert diagnostics with line numbers and identifiers.
- Type inference tests that use fixture code and helper assertions to check inferred types, narrowed types, dynamic return types, and plugin-provided members.

Type-inference assertion syntax is fixture-harness syntax, not application Ruby syntax. The first test helper should use comments or external expectation files that Prism can parse as ordinary Ruby without a custom dialect. Production analysis ignores the markers completely unless an explicit test harness enables them.

Extension compatibility should initially be managed through Ruby gem version dependencies and a Rigor-provided extension test suite rather than a separate protocol-version number. Public extension namespaces should be documented as public; internal protocols should be explicitly marked internal so plugin authors do not depend on them accidentally. Rigor can evolve internal type representations freely, but documented plugin-facing interfaces need deprecation windows, compatibility tests, and migration notes once they are released as public gem APIs.

## Feedback from the Resulting Type Specification

Reconstructing `docs/types.md` exposes several extension API requirements that are not optional for the ideal type model:

- Extensions need to return flow contributions, not just types. A contribution should be able to describe truthy facts, falsey facts, post-return assertion facts, normal return type, exceptional or non-returning effects, receiver and argument mutations, and fact invalidations.
- `Scope` must be edge-aware. Plugin facts must participate in the same short-circuiting machinery as built-in guards so `&&`, `||`, `unless`, `elsif`, `case`, and pattern matching can refine scopes before later operands or arms are analyzed.
- Target paths need a staged design. The first annotation grammar may support only `self` and named parameters, but the plugin API should be prepared for local variables, receiver members, instance variables, hash keys, tuple elements, and stable method-result paths.
- The API needs relation facts in addition to type facts. Ruby `==`, `respond_to?`, key-presence checks, and framework predicates often prove relations or capabilities that are weaker than `target is T`.
- Extensions and standard-library fact providers need a way to declare capability-role conformance, so unrelated nominal classes such as `IO` and `StringIO` can satisfy shared stream roles without becoming mutually assignable as whole classes.
- Dynamic reflection should expose member certainty, provenance, visibility, call signature, mutation behavior, and stability. Without this, structural interface conformance would collapse into name-only duck typing.
- Type and reflection APIs need trinary certainty for `yes`, `maybe`, and `no`, because plugin-provided dynamic behavior often cannot be modeled as a hard boolean.
- Extension tests must be able to assert inferred types and facts at program points inside compound conditions, not only at statement boundaries.
- Cache metadata must include external schemas, generated signatures, gem versions, plugin configuration, and any files used to produce dynamic members or flow facts.

## Critical Review Working Responses

A critical review of the extension API draft surfaced the following risks. The working responses below record the current decisions or explicit deferrals. Exact object shapes, naming, and budgets can still evolve before the first public plugin API.

### Cache Invalidation Needs a Declarative API

Concern: plugin cache metadata named important inputs, but did not define how a plugin ties facts to files, generated signatures, gem versions, plugin versions, or configuration keys.

Working response: plugin facts and reflection contributions should carry declarative dependency descriptors attached to the cache slice they produced. Preferred granularity is contribution, generated signature unit, receiver family, dynamic-member provider, or analyzed file. Plugin-wide invalidation is allowed only when the whole plugin configuration truly affects the fact.

### Type-Inference Assertions Must Stay Fixture-Only

Concern: type inference tests need program-point assertions, but helper syntax could accidentally become a Rigor-specific Ruby dialect.

Working response: assertion markers are fixture-harness syntax. They should use comments or external expectation files that Prism parses as ordinary Ruby, and production analysis ignores them unless an explicit test harness enables them.

### Plugin Sandboxing and I/O Start from a Trusted-Gem Model

Concern: "plugins must not execute application code" is not a complete filesystem, network, failure-isolation, or trust policy.

Working response: the first implementation treats plugins as trusted Ruby gems selected by the user, Gemfile, or project configuration. Network access is disabled by default during analysis, ordinary reads are scoped to project and dependency inputs, and reads outside those inputs require explicit configuration plus cache dependency descriptors. Plugin exceptions become diagnostics at the analyzer boundary. Stronger isolation, such as Ruby::Box or process isolation, remains a future option.

### Trinary `maybe` Is Policy-Aware Uncertainty

Concern: relationship queries return `yes`/`maybe`/`no`, but the operational meaning of `maybe` was underspecified.

Working response: `yes` and `no` are proven answers under the current accepted contracts and analyzer assumptions; `maybe` is everything else. `maybe` does not narrow as a positive proof, does not create a complementary false-edge proof, and repeated `maybe` evidence remains `maybe`. Error levels decide whether maybe-dependent calls are accepted silently, reported as weak diagnostics, or rejected more strictly.

### Capability Roles Are Supplied by Core

Concern: plugin authors need to know which standard roles exist and whether Rigor depends on a core role provider, bundled plugin, or external plugin.

Working response: Rigor ships an opinionated core catalog of common standard-library capability roles. Plugins may add framework roles, additional conformance facts, role-specific exclusions, and uncertain conformance, but they should not silently replace core role definitions.

### ADR-1 Owns Flow-Effect Semantics

Concern: ADR-1 and ADR-2 both mention flow-effect bundle fields, which risks drift.

Working response: ADR-1 owns the semantic schema: fields, target-path meaning, certainty rules, and scope transitions. ADR-2 owns plugin packaging, registration, service lifetime, and provenance. `docs/types.md` carries the detailed normative product specification both ADRs reference.

### Reflection Rebuilds Are Slice-Based

Concern: combining source declarations, RBS, generated signatures, plugin members, and core/stdlib signatures into one reflection model needs an incremental rebuild story.

Working response: reflection inputs are layered by source and cached by stable slices such as declaration, member entry, singleton object, shape provider, generated signature unit, and plugin dynamic-member provider. Plugin dynamic members carry provenance and dependency descriptors so a single edited file or schema invalidates only the affected reflection slices.

### Diagnostic Provenance Uses Public Prefixes and Internal Detail

Concern: plugin-related diagnostics need attribution, de-duplication, and future suppression behavior.

Working response: public diagnostic identifiers should use source-family prefixes similar to PHPStan error identifiers, such as `plugin.<plugin-id>.<name>`, `rbs_extended.<name>`, or `generated.<provider>.<name>`. Internally, diagnostics retain richer provenance for explanations, cache keys, and future suppression policy. Duplicate diagnostics are grouped by normalized identifier, location, target, fact/effect kind, and source family.

### Compatibility Uses Gem Versions and Test Suites First

Concern: public extension protocols need compatibility policy, but a separate protocol-version system may be premature.

Working response: the first public contract should rely on Ruby gem version dependencies, documented public namespaces, explicit internal namespaces, and a Rigor-provided extension conformance test suite. A separate extension protocol version can be introduced later if gem version constraints and tests are not enough.

### Broad Expression and Operator Hooks Are Deferred

Concern: broad hooks can make analysis order and performance difficult to reason about.

Working response: the first public plugin milestone should defer broad expression and operator hooks unless a concrete framework use case cannot be represented by narrow hooks. Any future broad hook must specify traversal-order guarantees, invocation budgets, timeout or cancellation behavior, and diagnostic tracing.

## Rejected and Deferred Candidate Decisions

| Candidate | Status | Reason |
| --- | --- | --- |
| One generic plugin hook that can inspect and override everything | Rejected | PHPStan's narrow extension types are easier to reason about, cache, test, and document. Broad expression hooks should be exceptional. |
| Letting plugins mutate the current scope directly | Rejected | Scope mutation would make CFA order-dependent. Plugins should return facts and effects for the analyzer to apply. |
| Executing application code to discover framework behavior | Rejected | Rigor remains a static analyzer with zero runtime dependency. Plugins may read source, signatures, generated metadata, and configuration. |
| Making PHPDoc or Rigor-specific inline Ruby comments the main extension interface | Rejected | Rigor should not invent a new application-code annotation DSL. Existing RBS-, rbs-inline-, and Steep-compatible annotations are accepted as type sources; RBS, `RBS::Extended`, generated signatures, and plugins remain the extension surfaces. |
| Making type-inference assertion helpers part of application Ruby | Rejected | Assertion markers are fixture-harness syntax only. Production analysis must ignore them unless a test harness explicitly enables them. |
| Introducing a separate extension protocol version before gem compatibility proves insufficient | Deferred | Ruby gem version dependencies, documented public namespaces, explicit internal namespaces, and Rigor-provided conformance tests should carry the first public compatibility contract. |
| Shipping all PHPStan-style extension points in the MVP | Deferred | Dynamic return types, type-specifying extensions, and dynamic reflection provide the most immediate value. Output, dead-code, and broad infrastructure hooks can follow later. |

## Open Questions

- Should dynamic return extensions match by nominal receiver type only at first, or also by structural interface and object shape?
- What is the initial plugin manifest format and configuration schema language?
- Should Rigor expose synthetic or virtual AST nodes to rules in the first custom-rule milestone?
- What is the exact fixture marker spelling for asserting inferred types and branch-local facts in Ruby fixtures, including facts that exist only while analyzing the right side of `&&` or `||`?
- What exact payload should plugins use to declare full, partial, excluded, or `maybe` capability-role conformance?
- What exact diagnostic identifier taxonomy and display format should Rigor use for conflicting plugin, generated, and `RBS::Extended` contributions?
- What exact reflection cache key schema and persistence format should represent source, RBS, generated, and plugin-provided slices?
- What gem dependency ranges and Rigor-provided conformance tests define compatibility for public extension namespaces?
- If broad expression or operator hooks are enabled later, what concrete invocation budgets, timeout behavior, traversal-order guarantees, and tracing output should they use?

## Consequences

Positive:

- Rigor can support framework-specific Ruby behavior without hard-coding frameworks into the core.
- Extension authors get focused protocols with stable context objects.
- The core analyzer keeps ownership of flow application, normalization, diagnostics, and caching.
- PHPStan's separation between Scope, Type, Reflection, and extension services gives Rigor a proven shape for plugin APIs.

Negative:

- Public extension protocols create compatibility obligations.
- A useful plugin API requires careful type, scope, and reflection object design earlier than the core-only MVP would.
- Broad hooks can harm performance or predictability if introduced without discipline.
- Plugin test harnesses become part of the supported developer experience.
