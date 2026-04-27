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

## Type System Object Model

PHPStan represents every type as an object implementing a common `Type` interface. Types answer capability and relationship queries such as `isSuperTypeOf`, `accepts`, `hasMethod`, `getMethod`, `hasProperty`, and `describe`. These answers often use trinary logic rather than booleans.

Rigor should adopt the same style:

- Type objects are ordinary immutable value objects.
- Relationship queries return `yes`, `maybe`, or `no` where uncertainty is meaningful.
- Extensions should ask semantic questions such as `StringType.supertype_of?(type)` rather than checking concrete implementation classes.
- Type constructors should normalize through combinators, for example union, intersection, difference, and erasure helpers.
- Custom type-like refinements should implement relationship, normalization, display, and RBS erasure behavior.

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

## Broad Expression and Operator Hooks

PHPStan has catch-all expression type resolver extensions and operator type specifying extensions. Its documentation recommends narrow hooks, such as dynamic return type extensions, when possible.

Rigor should keep broad expression hooks behind a higher bar because they can make analysis order and performance harder to reason about. They are still useful for Ruby constructs that do not fit method-call hooks, such as custom `[]` access, pattern-matching helpers, DSL literals, or operator-like methods whose meaning is framework-specific.

## Registration, Configuration, and Caching

PHPStan registers extensions as services with tags. Services are long-lived objects constructed by dependency injection; value objects such as types, scopes, and reflections are created during analysis or returned from services. PHPStan also validates custom configuration parameters with schemas.

Rigor should use plugin manifests and project configuration to register extension services. The initial design should include:

- Extension protocol identifiers rather than ad hoc method-name discovery.
- Constructor injection for analyzer services such as reflection providers, type factories, loggers, and configuration readers.
- Explicit plugin configuration schema so typos are diagnostics.
- Deterministic extension ordering.
- Cache metadata hooks so plugins can invalidate results when external schemas, generated files, gem versions, or configuration change.

## Testing and Compatibility

PHPStan provides test bases for rules and type inference extensions. Rule tests assert diagnostics in fixture files. Type inference tests assert inferred types in ordinary analyzed code.

Rigor should provide the same two test styles:

- Rule tests that analyze fixture files and assert diagnostics with line numbers and identifiers.
- Type inference tests that use fixture code and helper assertions to check inferred types, narrowed types, dynamic return types, and plugin-provided members.

Once public, extension protocols should have a backward-compatibility policy. Rigor can evolve internal type representations freely, but plugin-facing interfaces need versioning, deprecation windows, and migration notes.

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

## Identified Concerns from Critical Review

A critical review of the extension API draft surfaced the following risks. They are not blockers for the current direction, but each will need either a working decision or an explicit deferral before plugin authors can build against a stable contract.

### Plugin Precedence and Merging Are Unspecified

Multiple flow contributions can target the same call:

- A built-in narrowing rule (e.g., `is_a?`) and a plugin-provided fact may both apply to the same call site. The precedence rule between core inference and plugins is not stated.
- Two plugins may both register for the same receiver family. Their results may agree, refine through intersection, or contradict; the merge policy in each case is unspecified.
- The draft says ordering is deterministic, but it does not pick a model (registration order, priority field, alphabetical, configuration-driven). Plugin authors cannot predict outcomes without one.
- The rule for combining a plugin's truthy-edge fact with a built-in falsey-edge fact (or vice versa) in the same condition is not documented.

### Cache Invalidation Needs a Declarative API, Not Just a List of Inputs

The draft requires that cache metadata cover external schemas, generated signatures, gem versions, plugin configuration, and any files used by plugins, but the mechanism is not designed:

- How does a plugin declare "I read this YAML; my facts depend on its mtime/digest"?
- What is the granularity of invalidation: per file, per receiver type, per plugin, per fact?
- How are plugin facts attributed to specific cache slots so that a single edited fixture does not invalidate the entire result cache?
- What is the cache-key contract for plugin configuration changes (e.g., user toggles a Rails feature) versus plugin code changes (e.g., upgrading a plugin gem)?

### Type-Inference Assertions Risk Leaking Rigor Syntax into Ruby Code

The draft proposes "type inference tests using fixture code and helper assertions". For tests this is unavoidable, but the boundary needs care:

- Fixture-only assertion DSLs (e.g., `T(/expected/)`, magic comments, helper methods) must be explicitly scoped to test fixtures so the project's "no Rigor syntax in application Ruby" rule is not weakened in practice.
- If fixtures share files with real application code (a common copy-from-production pattern), the marker syntax should be ignorable by Rigor at production-analysis time.
- The assertion harness's syntax should not require a separate parser plugin or modify Prism behavior; otherwise the analyzer ends up with two Ruby dialects.

### Plugin Sandboxing and I/O Policy Is Undecided

"Plugins must not execute application code" is one constraint but not a complete policy:

- May plugins read arbitrary files outside the project directory? Without a rule, cache reproducibility is fragile and security exposure is unclear.
- May plugins make network calls during analysis? CLI determinism strongly suggests no by default.
- How are plugin failures isolated from analyzer crashes? A misbehaving plugin should not be able to take down `rigor check`.
- Plugin code itself runs as ordinary Ruby. The trust model for third-party plugins (review, signing, allowlists, lockfile pinning) should be acknowledged even if the first cut is "trust the user's Gemfile".

### Trinary `maybe` Lacks an Operational Policy

Relationship queries return `yes`/`maybe`/`no`, but the operational meaning of `maybe` is policy-driven:

- Does `maybe` produce a diagnostic in default mode, in strict mode, or never?
- Does `maybe` participate in narrowing as a positive fact, a negative fact, both, or neither?
- When two queries return `maybe` for the same condition, does Rigor promote to `yes`, demote to `no`, or stay at `maybe`?
- How is `maybe` displayed to users so they can act on it (e.g., add a guard, supply a stub, mark as accepted)?

### Capability-Role Provider Question Is Foundational, Not Deferable

The capability-role provider question is currently Open, but it shapes:

- Which roles plugin authors can rely on, and how they import them.
- Whether Rigor ships with a bundled standard-library plugin or links roles directly into core.
- The RBS files (or `RBS::Extended` annotations) that core depends on at startup.

Leaving this open delays the plugin contract design. A working decision (even one as light as "core ships an opinionated set under `lib/rigor/roles`, with replacement allowed via plugins") should be documented soon.

### Authoritative Source for the Flow-Effect Bundle Is Split

The flow-effect bundle is specified in both ADR-1 ("Flow Effects and Extension Contributions") and ADR-2 ("Type-Specifying Extensions" and "Dynamic Return Type Extensions"). When the two diverge, which is authoritative?

- A clear rule (for example, ADR-1 owns semantics and the field set, ADR-2 owns the API surface and packaging) avoids drift.
- The bundle's fields are listed in both ADRs but not guaranteed to remain in sync. A single normative table referenced from both ADRs would prevent silent divergence.

### Reflection Layer Needs an Incremental-Rebuild Story

Rigor combines source declarations, RBS, generated signatures, plugin members, and core/stdlib signatures into a single reflection model. The draft does not describe:

- Which inputs are pre-built before analysis vs. constructed on demand.
- How a single edited file invalidates only the affected reflection slices (member of a class, attribute of a record, plugin-provided dynamic member).
- Whether plugin-provided dynamic members are expected to be stable across runs or recomputed per file.

For CLI-first responsiveness, this is a foundational concern; without it, ADR-0's "high-performance caching" goal is hard to meet.

### Plugin Diagnostic Provenance and De-Duplication

When a plugin contributes a fact that leads to a diagnostic, attribution matters:

- Diagnostics should identify the contributing plugin so users can fix root causes upstream.
- Two plugins contributing the "same" fact about the same expression should not produce duplicate diagnostics.
- Suppression mechanisms (e.g., a future `rigor:disable` comment or configuration entry) interact with plugin facts. The policy on whether suppression covers plugin facts, core facts, or both should be explicit.

### Extension Protocol Versioning Timing

"Once public, extension protocols should have a backward-compatibility policy" is correct, but timing is unspecified:

- Is "public" the first release, the first stable release, or the end of a designated experimental window?
- Internal-only protocols should be marked as such so plugin authors do not depend on them by accident.
- A policy for major-version transitions (deprecation length, parallel-protocol periods, migration guides) should be sketched even if numbers are placeholders.

### Operator and Expression Hooks Have No Cost Model

The draft accepts broad expression and operator hooks "behind a higher bar" without describing what that bar is:

- The analyzer's traversal order with broad hooks active is not documented. A misbehaving hook can silently change which scopes are seen by other extensions.
- Performance budgets for broad hooks (e.g., maximum invocations per file, time-out per call) are not described, which makes plugin behavior in large code bases unpredictable.
- A diagnostic mode that surfaces broad-hook activity to plugin authors and end users would help, but is not part of the current draft.

## Rejected and Deferred Candidate Decisions

| Candidate | Status | Reason |
| --- | --- | --- |
| One generic plugin hook that can inspect and override everything | Rejected | PHPStan's narrow extension types are easier to reason about, cache, test, and document. Broad expression hooks should be exceptional. |
| Letting plugins mutate the current scope directly | Rejected | Scope mutation would make CFA order-dependent. Plugins should return facts and effects for the analyzer to apply. |
| Executing application code to discover framework behavior | Rejected | Rigor remains a static analyzer with zero runtime dependency. Plugins may read source, signatures, generated metadata, and configuration. |
| Making PHPDoc or Rigor-specific inline Ruby comments the main extension interface | Rejected | Rigor should not invent a new application-code annotation DSL. Existing RBS-, rbs-inline-, and Steep-compatible annotations are accepted as type sources; RBS, `RBS::Extended`, generated signatures, and plugins remain the extension surfaces. |
| Shipping all PHPStan-style extension points in the MVP | Deferred | Dynamic return types, type-specifying extensions, and dynamic reflection provide the most immediate value. Output, dead-code, and broad infrastructure hooks can follow later. |

## Open Questions

- What is the smallest stable `Scope` interface needed for the first plugin milestone?
- Should dynamic return extensions match by nominal receiver type only at first, or also by structural interface and object shape?
- How should plugin-provided facts be displayed in diagnostics so users can tell core inference from plugin inference?
- What is the initial plugin manifest format and configuration schema language?
- How should Rigor version public extension protocols separately from internal analyzer classes?
- Should Rigor expose synthetic or virtual AST nodes to rules in the first custom-rule milestone?
- What is the first testing helper spelling for asserting inferred types in Ruby fixtures?
- What is the smallest public shape of a flow contribution bundle that supports truthy, falsey, assertion, mutation, and invalidation effects?
- Which target-path forms should be public in the first plugin API, and which should remain internal until fact-stability rules are clearer?
- How should tests assert facts that exist only on the right side of `&&` or `||` before the surrounding `if` body is entered?
- Should standard-library capability roles be supplied by core Rigor, generated RBS, or a bundled standard-library plugin?
- How should plugins declare that a dynamic class satisfies only part of a role, or satisfies it with `maybe` certainty?
- What is the precedence rule when built-in narrowing and one or more plugin-provided facts target the same call or condition?
- What is the declarative API a plugin uses to register cache invalidation inputs (file paths, digests, gem versions, configuration keys)?
- What is the boundary between fixture-only test syntax and ordinary application Ruby for type-inference assertions, and how is that boundary enforced at production-analysis time?
- What is the minimum sandbox and I/O policy for third-party plugins, including filesystem scope, network access, and crash isolation?
- What operational policy applies to `maybe` results in default mode versus strict mode, including narrowing behavior and diagnostic emission?
- Which document owns the canonical schema of the flow-effect bundle, and how is the schema kept in sync between ADR-1 and ADR-2?
- What is the rebuild granularity of the reflection layer when source, RBS, generated signatures, or plugin-provided members change?
- How are plugin-contributed diagnostics attributed and de-duplicated, and how do future suppression mechanisms interact with them?
- When does an extension protocol become "public" for versioning purposes, and what deprecation or parallel-protocol policy applies after that point?
- What performance and traversal-order guarantees apply to broad expression and operator hooks, and how are they surfaced to plugin authors?

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
