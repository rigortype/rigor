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
- Current file, lexical nesting, class/module singleton context, method, block, and visibility context.
- Current receiver type and known local, instance-variable, class-variable, global, constant, and shape facts.
- Name and constant resolution helpers for Ruby lexical lookup.
- Flow-edge context such as truthy branch, falsy branch, assertion context, rescue context, and unreachable context.

Extensions should not mutate `Scope` directly. They should return facts, diagnostics, synthetic nodes, or metadata to the analyzer, which applies them through normal control-flow machinery.

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

## Type-Specifying Extensions

PHPStan type-specifying extensions provide flow facts based on calls to type-checking functions or methods. They receive the call node, method/function reflection, scope, and a context object that says whether the call is being evaluated as truthy, falsy, null, or as an assertion. They return `SpecifiedTypes`, often through a central `TypeSpecifier`.

Rigor should make this a first-class extension family because Ruby code often narrows through predicate and assertion APIs:

- Predicates such as `nil?`, `is_a?`, `kind_of?`, `instance_of?`, `respond_to?`, custom `foo?` methods, and framework guards.
- Assertion methods such as `assert`, `raise unless`, test-framework assertions, contract helpers, and validation libraries.
- Pattern-style or relation-style APIs that prove facts about receiver members, hash keys, or method results.

The extension result should describe positive and negative facts separately. It should also support a true-only form when the false branch does not imply the complement, matching PHPStan's distinction between equality-like assertions and one-sided predicates.

## Dynamic Reflection and Magic Members

PHPStan class reflection extensions describe magic properties and methods exposed through `__get`, `__set`, `__call`, and similar mechanisms. The reflection layer asks registered extensions when native reflection cannot find a member.

Rigor needs the same capability for Ruby's `method_missing`, `respond_to_missing?`, `define_method`, Rails-style generated methods, ActiveRecord attributes, enum helpers, associations, serializers, delegated methods, and DSL-generated constants.

Rigor dynamic reflection extensions should contribute method, attribute, constant, and shape members with ordinary reflection objects. Those reflection objects should expose readable and writable types, method overloads, visibility, deprecation/internal facts, side-effect facts, and source/provenance for diagnostics.

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

## Rejected and Deferred Candidate Decisions

| Candidate | Status | Reason |
| --- | --- | --- |
| One generic plugin hook that can inspect and override everything | Rejected | PHPStan's narrow extension types are easier to reason about, cache, test, and document. Broad expression hooks should be exceptional. |
| Letting plugins mutate the current scope directly | Rejected | Scope mutation would make CFA order-dependent. Plugins should return facts and effects for the analyzer to apply. |
| Executing application code to discover framework behavior | Rejected | Rigor remains a static analyzer with zero runtime dependency. Plugins may read source, signatures, generated metadata, and configuration. |
| Making PHPDoc or inline Ruby comments the main extension interface | Rejected | Rigor keeps application Ruby annotation-free. RBS, `RBS::Extended`, generated signatures, and plugins are the extension surfaces. |
| Shipping all PHPStan-style extension points in the MVP | Deferred | Dynamic return types, type-specifying extensions, and dynamic reflection provide the most immediate value. Output, dead-code, and broad infrastructure hooks can follow later. |

## Open Questions

- What is the smallest stable `Scope` interface needed for the first plugin milestone?
- Should dynamic return extensions match by nominal receiver type only at first, or also by structural interface and object shape?
- How should plugin-provided facts be displayed in diagnostics so users can tell core inference from plugin inference?
- What is the initial plugin manifest format and configuration schema language?
- How should Rigor version public extension protocols separately from internal analyzer classes?
- Should Rigor expose synthetic or virtual AST nodes to rules in the first custom-rule milestone?
- What is the first testing helper spelling for asserting inferred types in Ruby fixtures?

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
