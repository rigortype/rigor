# ADR-1: Type Model and RBS Superset Strategy

## Status

Draft.

ADR-1 records type-model design decisions and their rationale. The companion document `docs/types.md` is the type specification: it defines how the analyzer behaves at the level of normalization, narrowing, erasure, signature handling, and diagnostic surfaces. When the two documents discuss the same area:

- `docs/types.md` is authoritative for *what the analyzer does*, including concrete rules, defaults, and budgets.
- ADR-1 is authoritative for *why a decision was taken* and for the design boundaries that scope follow-up work.
- If the two documents diverge in observable behavior, treat `docs/types.md` as the binding text and update ADR-1 to match. ADR-1 should not silently restate a behavior contract that lives in the spec.

ADR-1 also defers to ADR-2 for plugin extension API design. ADR-1 only fixes the analyzer-side surface that ADR-2 must attach to (Scope queries, fact contributions, capability roles, mutation summaries, diagnostic identifier prefixes); concrete plugin lifecycle, configuration, and merging rules are normative in ADR-2.

## Context

Rigor is an inference-first static analyzer for Ruby. It must interoperate with the existing RBS ecosystem while supporting internal types that are more precise than RBS can express.

RBS already defines a rich type syntax, including nominal types, singleton class types, literal types, unions, intersections, optionals, records, tuples, proc types, type variables, `self`, `instance`, `class`, `bool`, `untyped`, `nil`, `top`, `bot`, and `void`.

Rigor should also learn aggressively from PHPStan, TypeScript, and Python's typing specification. Those systems demonstrate that practical static analysis benefits from literal types, finite unions, control-flow narrowing, negative facts, shape-like types, gradual typing discipline, and expressive type operators. Rigor should adapt those ideas to Ruby and RBS rather than copying their syntax uncritically.

The initial design requirement is:

- Every RBS type is a valid Rigor type, and the RBS→Rigor direction is *lossless*: any RBS type round-trips through Rigor's internal representation without losing precision. Internal wrappers such as `Dynamic[T]` are reversible at the boundary.
- Rigor may infer richer types than RBS.
- Every Rigor-inferred type can be conservatively erased to valid RBS, but the Rigor→RBS direction is generally *not* lossless: erasure may collapse refinements, literal unions, shapes, and dynamic-origin provenance. Erasure must never produce a narrower type than Rigor proved, but it may produce a wider one.
- Special RBS types such as `untyped`, `top`, `bot`, and `void` must be handled with type-theoretic clarity rather than as ad hoc aliases.
- Types that exceed RBS may be recorded in RBS annotations under a provisional `RBS::Extended` convention.

The compatibility hierarchy is:

- RBS and rbs-inline are first-order norms for type syntax and inline annotation compatibility.
- Steep 2.0 behavior is the second-order norm for how existing annotations are interpreted when prose specifications leave behavior open.
- TypeScript, PHPStan, and Python typing are design references used to find missing concepts and practical analyzer features; they are not syntax compatibility targets.

This ADR cites locations under `references/` (for example `references/phpstan/...`, `references/typescript/...`, `references/python-typing/...`) as indicative reference paths inside the Rigor checkout. The exact files and line numbers depend on the submodule revisions configured by `make init-submodules`. If a path does not resolve in a particular checkout, treat the citation as a pointer into the upstream repository at the corresponding revision rather than as a hard reference.

## Goals

- Preserve RBS compatibility for input and output.
- Keep application code free of Rigor-specific inline type syntax. Rigor may still consume existing RBS-, rbs-inline-, and Steep-compatible annotation comments as type sources.
- Support precise control-flow and data-flow inference.
- Support PHPStan-, TypeScript-, and Python-style narrowing where it fits Ruby semantics.
- Make gradual typing boundaries explicit.
- Make exported RBS conservative and explainable.
- Keep room for plugin-provided type facts without baking framework behavior into the core.

## Non-Goals

- Rigor does not need to invent an incompatible signature language.
- Rigor does not need to expose every internal refinement in generated RBS.
- Rigor does not need to finalize every type operator syntax before implementing the underlying semantics.
- Rigor does not need to implement the complete final type lattice in the first MVP.

## Options Considered

### Option A: Use RBS Types Only

Rigor could represent exactly the types RBS can spell.

Benefits:

- Simple export path.
- Close alignment with existing tooling.
- Smaller initial implementation.

Drawbacks:

- Inference loses useful facts, such as literal sets, integer bounds, truthiness refinements, and dynamic-origin provenance.
- Diagnostics become less precise.
- `void` and `untyped` are likely to be treated as broad aliases too early.
- PHPStan-, TypeScript-, and Python-style refinements cannot be represented well.

### Option B: Use a RBS Superset with Conservative Erasure

Rigor can represent every RBS type and add internal-only refinements. Export converts those refinements back to conservative RBS.

Benefits:

- Keeps RBS as the interoperability format.
- Allows precise inference and diagnostics.
- Provides a principled path for gradual typing and advanced refinements.
- Supports control-flow analysis with positive and negative facts.
- Matches the project goal of inference-first analysis without application-code annotations.

Drawbacks:

- Requires a real erasure pass.
- Requires separate normalization, subtyping, and consistency logic.
- Users may need explanations when exported RBS is less precise than Rigor's internal type.
- The syntax for Rigor-only type operators must be designed carefully.

### Option C: Use RBS Plus `RBS::Extended` Annotations Only

Rigor could avoid an independent internal type model and represent every extension as RBS annotations.

Benefits:

- Keeps all explicit type metadata attached to RBS declarations, members, or overloads.
- Remains invisible to standard RBS parsers.
- Provides a migration path for advanced library signatures.

Drawbacks:

- Annotations are not enough for inferred facts produced by CFA.
- It risks turning annotations into an unstructured second language.
- It does not solve internal normalization, subtyping, or erasure.

### Option D: Create a Separate Rigor Signature Language

Rigor could define a new full signature language and optionally generate RBS.

Benefits:

- Maximum expressiveness.
- No need to fit internal concepts into RBS constraints.

Drawbacks:

- Splits the ecosystem.
- Adds learning and maintenance cost.
- Conflicts with the goal of using existing RBS types for dependencies.
- Encourages annotation workflows that Rigor is intentionally avoiding.

## Working Decision

Adopt Option B, with a constrained part of Option C: Rigor's type language is a strict superset of RBS with conservative RBS erasure, and `RBS::Extended` annotations may describe Rigor-only facts in `*.rbs` files.

RBS remains the boundary format. Rigor's internal type representation may include refinements that RBS cannot express, but those refinements must always have a valid RBS erasure.

`RBS::Extended` annotations are metadata layered on top of ordinary RBS. They are not a replacement for internal inference and should not require annotations in Ruby application code.

How Rigor *chooses* between candidate types when authoring its own signatures (built-in catalog entries, inferred user-method types, RBS::Extended payloads) is governed by the asymmetric robustness principle in [ADR-5](5-robustness-principle.md): strict returns to maximise downstream precision propagation, lenient parameters to avoid forcing callers to paste defensive coercions. Hand-written RBS authorship binds; the principle directs the default choice when Rigor authors the signature itself.

## Key Design Points

### Subtyping and Gradual Consistency Are Separate

Rigor should distinguish ordinary subtyping from gradual consistency.

`top` is the greatest static value type. `bot` is the empty type. `untyped` is the dynamic type and should not be collapsed into `top`, even though RBS describes it as both a subtype and supertype of all types for gradual typing purposes.

This separation lets Rigor keep track of unchecked boundaries while still allowing gradual code to type-check.

Internally, dynamic-origin values should be represented as `Dynamic[T]`, where `T` is the currently known static facet. Raw `untyped` is `Dynamic[top]`. This is not user-facing RBS syntax; it is the implementation device that lets Rigor narrow an unchecked value without losing the fact that the value came from a gradual boundary.

The dynamic algebra preserves the static facet through the ordinary type operators while keeping the dynamic-origin marker:

- `Dynamic[A] | Dynamic[B] = Dynamic[A | B]`
- `T | Dynamic[U] = Dynamic[T | U]`
- `Dynamic[T] & U = Dynamic[T & U]`
- `Dynamic[T] - U = Dynamic[T - U]`

Generic positions preserve dynamic-origin slots. `Array[untyped]` becomes `Array[Dynamic[top]]`, so element reads, writes, and leaks can be explained precisely. Subtyping and member lookup still use the static facet when one is available; gradual consistency only applies at the dynamic boundary.

Strict modes use this provenance rather than changing the core relation. One level may report dynamic-to-precise boundary crossings and unchecked generic leaks; a stricter level may also report operations whose proof depends on dynamic-origin facts.

The documentation should write the gradual-consistency relation as `consistent(A, B)`, not `A ~ B`, because `~T` is reserved for negative or complement types.

Display of `Dynamic[T]` follows the diagnostic identifier system. Diagnostics outside the `dynamic.*` family render the narrowed static facet `T` with a small `from untyped` provenance note rather than the wrapped form, because the dynamic origin is incidental to most user-facing messages. Diagnostics in `dynamic.*` and explanations requested through `rigor explain` show the full `Dynamic[T]` form. Internal traces, cache keys, and plugin `Scope` queries always retain the wrapped form regardless of display choices, so reasoning chains across plugins and refactors remain stable.

### Trinary Certainty Is Not a Proof System Shortcut

Relationship queries should return `yes`, `no`, or `maybe` when uncertainty is meaningful. `yes` and `no` are reserved for results that are proven under the current source, accepted signatures, plugin facts, and analyzer assumptions. `maybe` means the analyzer cannot prove either side.

Accepted method signatures still define trusted method-boundary contracts. Parameters and called method return values are analyzed according to their accepted RBS, rbs-inline, Steep-compatible, generated, or `RBS::Extended` contracts; Rigor does not turn every value received from another method into an uncertain value merely because the implementation is elsewhere.

`maybe` is not enough to narrow as though the relationship were `yes`, and it does not imply the opposite edge as though the relationship were `no`. It may be retained as a weak relational, member-existence, dynamic-origin, or plugin-provenance fact for diagnostics. Repeated `maybe` evidence remains `maybe` unless a stronger proof is supplied.

Diagnostics for `maybe` are policy-driven. Like PHPStan error levels, Rigor should leave room for a permissive level that accepts maybe-dependent calls without reporting them and stricter levels that report uncertain method calls, role matches, or branch proofs.

`maybe` and incomplete inference are distinct concepts and must not be conflated:

- `maybe` is a *relational query result*. It answers a question such as subtype relationship, structural compatibility, or member existence with three values. It applies even when inference is complete: the analyzer simply cannot prove either side under the available evidence.
- Incomplete inference is an *analyzer outcome* triggered by a budget cutoff (recursion depth, call-graph width, operator ambiguity, and so on). It produces a `static.*` diagnostic with a reason and a placeholder type such as `Dynamic[top]` or another conservative incomplete-inference marker. The cutoff is independent of any specific relational question.
- The two compose. A relational query against a placeholder type is allowed to return `maybe` because the missing precision prevents a `yes`/`no` answer, but the underlying cause is the cutoff and the diagnostic identifies it as such. Implementers must not collapse "stopped early" into a relational `maybe` that hides the cutoff from users.

### PHPStan Compared with RBS

The PHPStan documentation in `references/phpstan/website/src/writing-php-code/` is useful because it describes the feature surface of a mature analyzer for a dynamic language. PHPStan is not a compatibility target, and PHPDoc syntax should not become Rigor syntax, but its features are a strong checklist for what users eventually expect from precise static analysis.

| Area | PHPStan | RBS and Rigor implication |
| --- | --- | --- |
| Annotation boundary | PHPStan combines PHP native typehints with PHPDoc tags on functions, methods, properties, classes, local variables, and vendor stub files. PHPDocs augment native hints when PHP syntax is too weak. | Rigor keeps Ruby application code free of Rigor-specific annotation DSLs. RBS, rbs-inline, and Steep-compatible annotations are accepted type sources, while `RBS::Extended` annotations or external signatures are the place for Rigor-only extra facts. Inline Ruby comments should not become the main correction mechanism for Rigor-specific refinements. |
| Trust and source of truth | PHPStan trusts inline `@var` assertions and recommends fixing types at the source with better PHPDocs, stubs, generics, assertions, or extensions. | Rigor should prefer RBS signatures, generated facts, and checked assertions over local override comments. Any future local override should be visibly unsafe and should not silently replace inferred facts without diagnostics. |
| Dynamic type | PHPStan `mixed` permits unchecked operations. It distinguishes implicit `mixed`, caused by missing types, from explicit `mixed`, and stricter rule levels limit what can be done with it. | RBS `untyped` is the dynamic type. Rigor should preserve dynamic-origin provenance so strict modes can distinguish deliberate `untyped` from missing or inferred-unknown information. |
| Basic scalar and object types | PHPStan has PHP-shaped scalar, object, resource, callable, iterable, and class/interface names, plus aliases such as `int` and `integer`. | Rigor should use RBS and Ruby names as canonical. PHP aliases are reference material only; Ruby core classes, singleton class types, interfaces, and RBS built-ins define the surface. |
| `void` and bottom | PHPStan uses `void` for no useful return value and aliases such as `never` for early-terminating calls. `@return never` also helps undefined-variable analysis after exits or redirects. | RBS already has `void` and `bot`. Rigor should keep `void` as a no-use return marker and use `bot` for non-returning control flow, early termination, impossible branches, and exhaustiveness. |
| Unions, intersections, and parentheses | PHPStan supports unions, intersections, and grouping in PHPDoc types. | RBS already supports unions and intersections. Rigor should preserve RBS syntax at the boundary and use normalization internally for precise diagnostics. |
| Literal and constant types | PHPStan accepts scalar literals and class or global constants, including wildcard-like constant enumerations. | RBS supports literal types. Rigor can use literal unions and selected constant expansion internally, but constant-pattern enumeration should follow Ruby constant semantics rather than PHP class-constant syntax. |
| Integer refinements | PHPStan has named integer refinements and ranges such as positive, non-zero, and bounded integer intervals. | Rigor should keep useful refinements such as `positive-int` and `non-zero-int`, but Ruby/RBS-shaped range notation such as `Integer[1..10]` is preferable to PHPStan syntax. |
| String refinements | PHPStan has `non-empty-string`, `literal-string`, `numeric-string`, case refinements, decimal-int strings, and PHP-truthiness-oriented string types. | Rigor should import only refinements that make sense for Ruby. `non-empty-string`, `literal-string`, `numeric-string`, `lowercase-string`, `uppercase-string`, and `decimal-int-string` are plausible; PHP truthiness spellings such as `truthy-string` are not useful because Ruby strings are always truthy. |
| Arrays, lists, and iterables | PHPStan distinguishes homogeneous arrays, non-empty arrays, lists with sequential integer keys, iterables with key and value types, and collection-like traversable classes. | RBS has arrays, tuples, records, and enumerable-like library signatures. Rigor should infer array/list/iterator element facts where useful, but Ruby `Array[T]`, tuples, records, and library RBS should remain the export forms. |
| Array and object shapes | PHPStan array shapes support required and optional keys, tuple-like numeric keys, class-constant keys, `list{...}`, and non-empty shape forms. Object shapes describe public read-only properties, with intersections used to regain writability. | RBS records and tuples cover part of this space. Rigor should infer richer hash, keyword, tuple, and object shapes internally, including optional keys and open or closed extra-key policies, then erase them to RBS records, tuples, `Hash[K, V]`, interfaces, nominal types, or `top`. |
| Key and value projection | PHPStan has `key-of`, `value-of`, and offset access such as `T[K]`, especially for arrays and generic attribute maps. | Rigor should support the semantics of key projection, value projection, and indexed access for records, tuples, hashes, keyword arguments, and object shapes, using canonical forms such as `key_of[T]`, `value_of[T]`, and `T[K]`. |
| Type aliases | PHPStan supports global configured aliases plus local `@phpstan-type` aliases and `@phpstan-import-type`. | RBS already has type aliases. Rigor should use RBS aliases for shared names and reserve `RBS::Extended` metadata for facts that ordinary RBS cannot express, rather than adding a second alias system. |
| Generics and variance | PHPStan defines generic classes, interfaces, traits, functions, and methods with `@template`, bounds, defaults, declaration-site variance, call-site variance, and star projections. | RBS already has generics and variance for declarations. Rigor should preserve RBS generic boundaries, consider call-site variance and unknown-argument projections as future internal checking tools, and avoid importing PHPDoc template syntax. |
| Conditional and dependent returns | PHPStan conditional return types, `template-type`, and `new` express return types dependent on argument types, generic arguments, or class-name strings. | Rigor should model argument-sensitive and receiver-sensitive return facts as inference, overload selection, or `RBS::Extended` metadata. Class-name-string projections are less central in Ruby than class objects and `singleton(C)`. |
| Class-name strings | PHPStan has `class-string<T>`, `interface-string`, `trait-string`, and `enum-string`, narrowed by calls such as `class_exists`. | Ruby can pass class and module objects directly. Rigor should prefer `singleton(C)` and object-level facts; string-to-class projections are deferred and should be designed around Ruby constant lookup and factory APIs. |
| Callable precision | PHPStan PHPDocs can specify callable signatures, pure callables, generic closures, by-reference parameters, variadic parameters, immediate versus later invocation, and closure `$this` rebinding. | RBS already has method, proc, block, overload, optional, keyword, rest, and self-related forms. Rigor should model Ruby blocks, procs, lambdas, receiver binding, purity, and invocation timing as separate facts where they affect flow analysis. |
| Magic members and mixins | PHPStan uses `@property`, `@method`, and `@mixin` to describe `__get`, `__set`, `__call`, delegation, and framework-style dynamic APIs. | Ruby has `method_missing`, `respond_to_missing?`, delegation, `include`, `extend`, and metaprogramming. Rigor should keep these out of core syntax where possible and represent them through RBS members, interfaces, generated signatures, and future plugin facts. |
| Flow narrowing | PHPStan narrows through strict comparisons, type-checking functions, `instanceof`, `assert`, assertion libraries, and custom type-specifying extensions. | Rigor should implement Ruby-specific CFA using equality, `nil?`, `is_a?`, `kind_of?`, `instance_of?`, `respond_to?`, pattern matching, returns, raises, assertions, and plugin facts. The narrowed facts are internal even when they were motivated by signature metadata. |
| Predicate and assertion metadata | PHPStan's `@phpstan-assert`, `@phpstan-assert-if-true`, and `@phpstan-assert-if-false` can narrow parameters, properties, and method return values, including negated assertions and true-only equality assertions. | RBS has no predicate return type. Rigor should use `RBS::Extended` flow effects for assertion behavior, support positive and negative branch facts, and allow an explicit form for true-only narrowing when the false branch does not imply the complement. |
| Out and self effects | PHPStan can describe by-reference output parameters with `@param-out` and receiver type changes with `@phpstan-self-out` or `@phpstan-this-out`. | Ruby does not have PHP-style by-reference parameters, but methods can mutate receivers and arguments. Rigor should model receiver, argument, instance-variable, and shape mutation as effects, not as ordinary return types. |
| Exceptions, deprecations, and internal APIs | PHPStan reads tags such as `@throws`, `@deprecated`, `@not-deprecated`, and `@internal`, with extensions for richer policies. | These are analyzer features around symbols and control flow more than value types. Rigor should eventually attach equivalent facts to RBS declarations or project configuration, while keeping the core value type language focused. |
| Extensions and configuration | PHPStan exposes stub files, dynamic return type extensions, type-specifying extensions, parameter-out extensions, closure extensions, early-terminating call configuration, and extension packages. | This strongly supports Rigor's plugin direction. Framework- and library-specific facts should be contributed by signatures, configuration, generated RBS, or plugins rather than by hard-coding framework behavior into the core analyzer. |

The main PHPStan lesson for Rigor is that useful static analysis needs more than nominal signatures. Users need precise collection members, shapes, callable behavior, flow predicates, magic-member descriptions, and library-specific facts. Rigor should provide those capabilities while keeping RBS as the stable interchange format and keeping Ruby source code free of analyzer-specific PHPDoc-like comments.

### TypeScript Compared with RBS

The TypeScript handbook and reference materials in `references/TypeScript-Website/packages/documentation/copy/en/handbook-v2/` and `references/TypeScript-Website/packages/documentation/copy/en/reference/` are useful design input, but TypeScript is not a compatibility target. Rigor should borrow the semantic ideas that fit Ruby and RBS, not TypeScript syntax.

| Area | TypeScript | RBS and Rigor implication |
| --- | --- | --- |
| Signature boundary | TypeScript normally mixes implementation code and type annotations in `.ts` files, and also supports declaration-only `.d.ts` files for JavaScript libraries. Type annotations are erased from emitted JavaScript. | Rigor does not introduce TypeScript-like inline syntax for Ruby. RBS, rbs-inline, and Steep-compatible annotations are the accepted Ruby ecosystem inputs, and Rigor-only internal precision must erase conservatively to ordinary RBS. |
| External type ecosystem | TypeScript uses built-in `lib.*.d.ts`, bundled package declarations, and DefinitelyTyped `@types` packages. | Rigor should rely on RBS for Ruby core, stdlib, gems, and dependency signatures. TypeScript declarations are reference material only. |
| Compatibility model | TypeScript compatibility is primarily structural. Object, interface, class instance, and generic compatibility are based on available members, with private and protected class members adding nominal-like constraints. | RBS classes and modules remain nominal. RBS interfaces and Rigor object shapes provide the structural bridge. Rigor should not make all class assignability TypeScript-style structural by default. |
| Soundness model | TypeScript intentionally accepts some unsound behavior for JavaScript ergonomics, including `any`, assignment compatibility, function parameter bivariance in some modes, optional/rest parameter rules, and local excess-property heuristics. | Rigor should make unsoundness visible through `untyped`, gradual consistency, plugin facts, and diagnostics. It should not copy TypeScript assignment compatibility wholesale. |
| Dynamic, top, and unknown values | `any` disables checking and propagates dynamically. `unknown` can hold any value but requires narrowing before use. `object` excludes primitives. `never` is bottom. | RBS already has `untyped`, `top`, and `bot`. Rigor maps the idea of `any` to `untyped`, the safe-top role of `unknown` mostly to `top` plus checked operations, and `never` to `bot`. TypeScript spellings should not become canonical Rigor spellings. |
| `void` | TypeScript `void` is mainly a function return type. A function returning a value may be assignable to a `void` callback type, while a direct `function f(): void` body cannot return a value. | RBS `void` is a no-use return marker. Rigor should keep it distinct so assigning or sending messages to a `void` result is diagnostic, and should not import TypeScript's callback-specific `void` assignability without a Ruby block-semantics reason. |
| Absence and nilability | TypeScript has both `null` and `undefined`; optional properties read as possibly `undefined` under `strictNullChecks`; non-null assertion `!` removes `null | undefined` without a runtime check. | Ruby has `nil`, not JavaScript `undefined`. RBS `T?` means `T | nil`. Rigor should model missing hash keys, missing keyword arguments, and nilability separately, and should treat unchecked non-nil assertions as flow effects or diagnostics, not as TypeScript syntax. |
| Truthiness | JavaScript falsy values include `0`, `NaN`, `""`, `0n`, `null`, and `undefined`. TypeScript narrows around that model. | Ruby falsy values are only `false` and `nil`. Rigor should borrow the control-flow-narrowing idea, but must use Ruby truthiness. Types such as `truthy-string` or `non-falsy-string` add no Ruby precision. |
| Object and hash shapes | TypeScript object types describe property bags with required, optional, and `readonly` properties, index signatures, excess-property checks for object literals, and mapped transformations over keys. | RBS has records, tuples, interfaces, and nominal classes, but not the full TypeScript object-type calculus. Rigor may infer richer hash, keyword, and object shapes internally, then erase them to RBS records, `Hash[K, V]`, interfaces, nominal bases, or `top`. |
| Mutability qualifiers | TypeScript has `readonly` properties, `ReadonlyArray`, readonly tuples, and mapped modifiers that add or remove `readonly` and optionality. These are compile-time use restrictions and do not imply deep runtime immutability. | Rigor should model read-only views, frozen values, shape entry mutability, and writer availability as separate facts. They should not become ordinary nominal value types unless RBS later standardizes them. |
| Union, intersection, literal, and tuple types | TypeScript supports unions, intersections, string/number/boolean literals, discriminated unions, arrays, and tuples. Literal inference is sensitive to `let`, `const`, object mutability, and `as const`. | RBS already supports unions, intersections, literals, arrays, and tuples. Rigor should keep literal precision internally, then widen when mutation, aliasing, performance, or RBS erasure requires it. |
| Flow narrowing | TypeScript narrows with `typeof`, truthiness, equality, `in`, `instanceof`, assignments, reachability, user-defined type predicates, assertion functions, discriminated unions, and `never` exhaustiveness checks. | Rigor should implement Ruby-specific CFA using guards such as `nil?`, `is_a?`, `kind_of?`, `instance_of?`, `respond_to?`, equality, pattern matching, returns, raises, and plugin facts. Predicate and assertion behavior belongs in `RBS::Extended` flow effects, not ordinary return types. |
| Type predicates | TypeScript writes predicates as return types such as `parameter is Type`, and classes may use `this is Type`. | RBS has no equivalent return type form. Rigor should express these as annotations such as `rigor:v1:predicate-if-true value is T` on ordinary RBS signatures. |
| Exhaustiveness | TypeScript uses `never` after all union alternatives have been removed, often for exhaustive `switch` checks. | Rigor should use `bot` for impossible branches and exhaustiveness over finite literal unions, sealed-like plugin facts, and pattern matches. The canonical spelling remains `bot`. |
| Type-level operators | TypeScript has `keyof`, type-context `typeof`, indexed access types, conditional types with `infer`, distributive conditional types, mapped types, template literal types, and utility types such as `Partial`, `Pick`, `Omit`, `Exclude`, `Extract`, and `NonNullable`. | RBS has no comparable general type-level computation. Rigor may support selected semantics through Rigor-native forms such as `key_of[T]`, `value_of[T]`, `T[K]`, `T - U`, `T & U`, and a future conditional type syntax. It should avoid importing TypeScript operator and utility names unless a concrete migration benefit appears. |
| Generics and variance | TypeScript generic type parameters affect structural compatibility only where they are used in members. Variance is inferred from structural use, and explicit variance annotations are limited to instantiation-based comparisons. | RBS generics are declared on nominal and interface definitions, aliases, methods, and procs with RBS's own variance rules. Rigor should preserve RBS generic boundaries and use structural variance reasoning only where it is comparing shapes or interfaces. |
| Functions and overloads | TypeScript has function type expressions, call signatures, construct signatures, overload signatures, implementation signatures, erased `this` parameters, and contextual typing of callbacks. | RBS has method types, proc types, blocks, overloads, `self`, `instance`, `class`, and `singleton(C)`. Rigor should model Ruby methods, blocks, procs, singleton methods, and class objects directly rather than importing TypeScript call/construct syntax. |
| Classes and object construction | TypeScript classes create both instance-side and static-side types; construct signatures and `InstanceType` relate constructor functions to instances. `implements` checks conformance but does not change the class body's inferred types. | Ruby class objects are ordinary objects and RBS spells class object types with `singleton(C)`. Any future instance projection should be designed around Ruby class objects and factory methods, not JavaScript constructor function types. |
| Declaration merging and namespaces | TypeScript can merge interfaces, namespaces, classes, functions, and enums across declarations, and declarations can create different namespace, type, and value entities. | Ruby already has reopenable classes and modules, and RBS has its own declaration model. Rigor should not import TypeScript declaration merging as a type feature; it should follow RBS and Ruby constant semantics. |
| Enums, JSX, decorators, and symbols | TypeScript includes JavaScript-facing features and documentation for enums, JSX, decorators, `unique symbol`, and well-known symbols. | These are not RBS type-system targets. Rigor should use Ruby literals, constants, symbols, modules, classes, and plugin facts instead of TypeScript-specific runtime or platform constructs. |

Two TypeScript lessons are especially important for Rigor.

First, flow-sensitive analysis is not optional. TypeScript's useful diagnostics depend on preserving the difference between a declared type and the type observed at a program point. Rigor needs the same distinction for Ruby locals, instance variables, method receivers, block parameters, and shape members.

Second, TypeScript's type-level computation is powerful but tightly coupled to JavaScript object keys and property access. Rigor should use those operators as design inspiration for records, tuples, hashes, keyword arguments, object shapes, and plugin-provided facts, while keeping the RBS boundary small and Ruby-shaped.

### Python Typing Compared with RBS

The `references/python-typing` tree is useful reference material, but Python typing is not a compatibility target. Rigor should borrow concepts only when they preserve Ruby semantics and can erase to RBS.

| Area | Python typing | RBS and Rigor implication |
| --- | --- | --- |
| Signature boundary | Python allows inline annotations and separate stubs. | Rigor avoids a Python-like Rigor-specific inline annotation system and uses RBS, rbs-inline, and Steep-compatible annotations as Ruby ecosystem signature inputs. |
| Dynamic and top types | `Any` is an unknown gradual type, while `object` is the greatest fully static object type. | RBS already gives Rigor `untyped` and `top`; Python's materialization and assignability model reinforces keeping them separate. |
| Structural types | `Protocol` and `TypedDict` are structural type forms with explicit typing rules. | RBS interfaces and records cover part of this space; Rigor can infer richer object and hash shapes internally, then erase them to RBS interfaces, records, `Hash[K, V]`, or `top`. |
| Hash shape detail | `TypedDict` distinguishes required, non-required, read-only, open, closed, and extra items. | Rigor should reuse this vocabulary for Ruby hash, options-hash, and keyword-argument shapes, while remembering that ordinary Ruby hashes are mutable unless a separate fact proves otherwise. |
| Class objects and self types | Python uses `type[C]`, `Self`, and constructor-specific rules. | RBS already has `singleton(C)`, `self`, `instance`, and `class`; Rigor should prefer those forms and design any future instance projection around Ruby class objects. |
| Nil-like and bottom types | `None` is an ordinary value type; `Never` and `NoReturn` are bottom aliases. | RBS distinguishes `nil`, `NilClass`, `bot`, and `void`; Rigor should not import Python aliases, and `void` remains a RBS-specific no-use return marker. |
| Type predicates | Python has `TypeGuard` for positive-only narrowing and `TypeIs` for positive and negative narrowing. | RBS has no predicate return type form; Rigor should model these as flow effects in `RBS::Extended` annotations. |
| Metadata | `Annotated[T, ...]` is treated as `T` by tools that do not understand the metadata. | RBS `%a{...}` annotations give Rigor the same compatibility pattern for `RBS::Extended` metadata. |
| Callable precision | Python specifies overload matching, positional and keyword parameter kinds, `ParamSpec`, `TypeVarTuple`, and `Unpack[TypedDict]`. | RBS already has method and proc signatures, overloads, optional and keyword parameters, and block types. Rigor should borrow checking principles and keyword-shape ideas, not Python syntax. |
| Mutability and finality | Python has `Final`, `ClassVar`, `ReadOnly`, and `@final` qualifiers. | Rigor should model these, if needed, as symbol, member, or shape-write facts rather than ordinary value types. |

### Structural Interfaces Are the Protocol Bridge

Python `Protocol` is valuable because it gives static duck typing a named contract: an object is acceptable when it has the required members with compatible types, even without inheriting from the protocol.

Rigor should get the same benefit through RBS interfaces and inferred object shapes, not by importing Python syntax. An RBS interface such as `_Closable` can be treated as a named structural contract. A nominal class, singleton object, module object, or anonymous object shape can satisfy that interface if Rigor can prove that it has every required member with compatible method or attribute behavior.

This is a pseudo-protocol model:

- RBS interface declarations provide stable names for structural contracts.
- Rigor object shapes provide anonymous, inference-produced structural types.
- Assignability to an interface may be proven structurally; no Ruby inheritance, `include`, or runtime marker is required.
- Explicit RBS declarations or future `RBS::Extended` metadata may ask Rigor to verify conformance early, but structural assignability should not require explicit opt-in.
- Runtime checks such as `respond_to?` can provide member-existence facts, but they should not prove full signature compatibility by themselves.

Python's rule that mutable protocol attributes are invariant maps cleanly to Ruby method capabilities. A read-only attribute is a reader method and can be covariant in its result. A write-only attribute is a writer method and is checked contravariantly in its accepted value. A read-write accessor combines both constraints and is effectively invariant.

### Method Shapes and Visibility

Reader and writer capabilities are method capabilities, not field declarations. `attr_reader`, `attr_writer`, and `attr_accessor` are sources of method facts; Rigor models the resulting `x` and `x=` methods as separate entries on the shape.

- `attr_reader :x` contributes a public reader method `x` unless surrounding Ruby visibility state changes it.
- `attr_writer :x` contributes a writer method `x=` and does not imply a reader.
- `attr_accessor :x` contributes both methods, but Rigor still keeps them as two method entries.
- A manually defined or overridden `x` or `x=` method replaces or refines the method fact according to ordinary Ruby method lookup and source order. Reader and writer capability does not imply purity.

Visibility is a first-class facet on every method-shape entry. Rigor tracks at least `public`, `protected`, and `private`, plus the call context in which a member may be used:

- External explicit receiver sends require a public method.
- Private methods may be called only in private-call contexts, not as ordinary explicit receiver sends.
- Protected methods follow Ruby's protected receiver restriction and do not satisfy public structural interface requirements by default.
- Public structural interfaces require public members unless an internal check or a future interface form explicitly requests another visibility.

`respond_to?` checks refine an object to an existence-only shape, not to full signature compatibility. The optional `include_private` argument changes the visibility fact:

- `obj.respond_to?(:foo)` and `obj.respond_to?(:foo, false)` produce a public existence fact for `foo` on the true branch.
- `obj.respond_to?(:foo, true)` produces an existence fact whose visibility may be public, protected, or private. By itself it does not prove that `obj.foo` is legal as an external explicit receiver call.
- If the second argument is not statically known, Rigor records a weaker maybe-private visibility fact.

`respond_to_missing?` and `method_missing` facts carry dynamic provenance and an unknown or plugin-provided signature. They can justify guarded dynamic calls but do not prove full interface compatibility on their own.

The minimal first implementation representation pairs one method-shape entry with one resolved Ruby method body:

- A `MethodEntry` is one record per `(class-or-module, method name)`. Ruby has no per-signature overloading at runtime, so the entry corresponds to the runtime-resolved method body for that name on that class or module.
- A single source-level `def foo` is the simplest input that produces a `MethodEntry`. Multiple source-level `def foo` definitions on the same class or module — whether from a single file, partial classes split across files, monkey patching, or `prepend` and `include` chains — feed into the same entry as merge candidates rather than distinct entries.
- Visibility is stored at the `MethodEntry` level. Ruby's `private :foo` toggles the whole method, not a particular signature variant, so per-overload visibility is not represented in the first version.
- Signature variants from RBS overloads, `RBS::Extended` payloads, or plugin contributions are stored as a list of branches inside the entry. Branches share the entry's visibility but may carry different argument shapes, return types, predicate effects, and mutation effects.
- Conditional `def`, conditional `private`, and other dynamically constructed method definitions are out of scope for the first implementation. They surface as ordinary diagnostics or dynamic-origin facts and may be revisited later.

Open classes, monkey patches, and ancestor chain insertions all feed the same `MethodEntry`:

- Each candidate `def foo` (whether from the original class, a reopened class, a `prepend`ed or `include`d module that ends up resolving on this receiver, or a refinement scope where Rigor has visibility) contributes one input.
- The default merge policy follows Ruby's runtime resolution: the candidate that Ruby would actually dispatch wins. Among ordinary same-class redefinitions this is source order with a last-definition-wins resolution; among ancestor chains this is the lookup order Ruby uses for `prepend` over the class over `include`d modules over the superclass chain.
- Strict mode raises a diagnostic when a re-definition changes RBS-visible signature or visibility without an explicit override marker. The intended override marker is a future `RBS::Extended` directive (working name `rigor:v1:override=replace`); until that exists, strict mode reports the suspected silent monkey patch.
- Module includes and refinements are not flattened into the host class's `MethodEntry`. They remain on their owning module and participate in lookup through the ancestor chain.

### Capability Roles Beat Ad Hoc Mock Unions

Ruby libraries often accept objects that are not related by inheritance but share the capability required by a method body. `IO` and `StringIO` are the central example: `StringIO` is useful as an in-memory test double for many stream consumers, but it is not a subclass of `IO` and does not expose the full `IO` method surface.

Rigor should not model this by declaring `StringIO <: IO`. It should also avoid pushing users toward repetitive declarations such as `IO | StringIO` when the implementation merely needs a small stream capability. Instead, Rigor should infer and support structural capability roles such as readable, writable, rewindable, closable, seekable, and file-descriptor-backed.

This keeps three facts separate:

- `IO` is the nominal type for real `IO` objects and APIs that require file-descriptor-backed behavior.
- `StringIO` is a separate nominal type that can satisfy some stream roles.
- A method's inferred parameter requirement may be a smaller object shape or named interface, such as readable and rewindable stream behavior.

Explicit RBS declarations still define public contracts. If a signature says `IO`, passing `StringIO` should not be silently accepted as a subtype. Rigor may instead report that the implementation appears to require only a smaller capability role and suggest generalizing the signature to an interface. Unions remain appropriate when the implementation genuinely branches on or uses class-specific behavior from both `IO` and `StringIO`.

Rigor should ship an opinionated core catalog of common standard-library capability roles instead of making the first plugin milestone invent its own names. The catalog reuses existing RBS-defined interfaces wherever Ruby and the standard library already provide them, and adds a small set of Rigor-specific roles only where existing interfaces are missing or would conflate distinct capabilities.

Initial reused RBS interfaces:

- `_Each[T]`, `_Reader`, `_Writer`, `_ToS`, `_ToStr`, `_ToInt`, `_ToProc`, `_ToHash[K, V]`, `_ToA[T]`, `_ToAry[T]` for the established stdlib interfaces. Rigor matches these by their existing RBS shape and does not redefine them.
- `Enumerable[T]` and `Comparable` for the broad collection and ordering protocols. They participate in role matching as nominal interfaces rather than fresh structural roles.

Rigor-specific roles introduced for the first milestone (each one ships with an explicit RBS interface in Rigor's bundled signatures):

| Role | Purpose | Required members |
|---|---|---|
| `_RewindableStream` | Stream-like objects that can be replayed from the start | `read`, `rewind` |
| `_ClosableStream` | Stream-like objects whose lifetime can be closed | `close`, `closed?` |
| `_FileDescriptorBacked` | Real OS-backed streams that justify diagnostics requiring an actual `IO` | `fileno` |
| `_Callable[**A, R]` | Anything that responds to `call`, distinct from `_ToProc` | `call(*A) -> R` |

Plugins may add roles, additional conformance facts, role-specific exclusions, and uncertain conformance, but they cannot silently replace either the reused RBS interfaces or the Rigor-specific roles in this catalog.

### Capability-Role Inference Discipline

Capability roles are summaries, not searches. The inference must stay bounded and predictable:

- Each method has a cached requirement summary recording required member names, visibility, arity, keyword and block requirements, return-use constraints, mutation requirements, and provenance for each parameter and receiver.
- The summary is an anonymous object-shape requirement by default. Naming it as a known interface is an export and diagnostic convenience, not the core inference result.
- Requirement inference is local and monotone. Direct calls reuse existing signatures or cached summaries. Recursive or mutually recursive summaries use a widening placeholder and iterate only to a small fixed-point budget.
- Dynamic dispatch through `send`, `public_send`, unconstrained `method_missing`, or untyped delegation records a dynamic requirement instead of attempting to enumerate every possible target.
- Named-interface matching uses an index keyed by member name and visibility. Rigor compares only cheap-filtered candidates; if the candidate set is too large, the anonymous shape is kept and the generalization hint is suppressed.
- Candidate selection is deterministic: exact member-signature match first, configured standard-library roles before coincidental user interfaces, fewer extra required members next, then stable lexical name order. Ambiguity at the top of that ordering means no named suggestion is reported.
- Intersections of roles are allowed but bounded. The first implementation may use exact single-interface matches, explicit standard role bundles, or a small greedy intersection under a strict candidate limit. It does not solve an unbounded set-cover problem.
- Generic preservation is handled by identity tracking, not the role matcher. If a method returns the same parameter object it received, Rigor may infer `[S < _Role] (S value) -> S`. If the body may replace the value or return a delegated object, Rigor uses the ordinary inferred return type.

When the body's inferred capability requirement and the declared nominal type disagree, Rigor escalates along three explicit levels:

- **Diagnostic** is reserved for genuine type mismatches at call sites. A call that does not satisfy the declared parameter type is a diagnostic regardless of how the body is implemented. This level is unconditional and does not depend on configuration.
- **Hint** applies when the body's inferred role is strictly smaller than the declared nominal type and a generalization to a structural interface would still type-check. Hints are emitted under the `hint.role-generalization.*` category and are gated by the `style.suggest_role_generalization` configuration switch. The default is off so library authors who chose a nominal contract are not nudged out of it; opting in is appropriate for application code that wants to discover structural opportunities.
- **Silent** is the default for the remaining cases: the inferred role and the declared type are compatible, no generalization is offered to the user, and the inference result is retained internally for callers and refactor tooling. Plugins and reflective queries can still observe the inferred role through the `Scope` API.

The three levels are mutually exclusive at any given site. Rigor never both rejects a call and offers a generalization hint for the same parameter, and never silently rewrites a public nominal contract into a structural one.

### Control-Flow Narrowing Is Central

Rigor should run appropriate CFA and data-flow analysis, similar in spirit to PHPStan, TypeScript, and Python type checkers.

For example, after `value == "foo"`, the true branch can narrow `value` to `"foo"` and the false branch can carry the negative fact displayed as `~"foo"` when `value` already has a compatible trusted domain. The comparison does not create that positive domain by itself. The exact operator syntax is provisional, but the semantic capability is required.

Python's `TypeGuard` and `TypeIs` distinction supports the same design direction: predicate behavior is a flow effect. A true-only predicate is enough for `TypeGuard`-like behavior; paired true and false facts, or a false fact expressed as `T & ~U`, provide `TypeIs`-like behavior.

CFA must be fine-grained enough to update scope inside a condition expression, not only after the whole condition has been evaluated. For `if foo == "foo" && foo == "bar"`, the right side of `&&` is analyzed in the scope produced by the left side's true edge. If the current domain makes `"foo" & "bar"` impossible, the whole true branch becomes `bot`. The same principle applies to `||`, `!`, `unless`, `elsif`, `case`, and pattern matching.

Ruby equality is method dispatch, so equality narrowing cannot be a purely syntactic rule. `equal?`, `nil?`, boolean checks, trusted built-in literal domains, and predicate effects declared by RBS or plugins can produce type facts. Unknown `==` implementations should produce a weaker relational fact unless Rigor has method information that justifies a value-type refinement.

Raw `untyped` equality remains dynamic-origin relational information. `v: untyped` followed by `v == "foo"` does not become `Dynamic["foo"]` unless an independent guard or trusted equality effect proves that narrowing.

The initial trusted equality surface is intentionally narrow:

- `equal?` produces an identity fact bound to the observed reference. The fact is invalidated by reassignment, alias-escaping mutation, unknown calls, or plugin-declared effects.
- Built-in literal-domain equality is trusted only for finite literal sets of `String`, `Symbol`, `Integer`, booleans, and `nil`, and only when the receiver dispatch target is known and the receiver domain is already compatible.
- `Float` literal narrowing is refused by default. `NaN`, signed zero, infinities, and numeric coercion make exhaustiveness over float literals unsafe; relational facts may still be kept for diagnostics.
- `Range`, `Regexp`, `Module`, `Class`, and `===`-based case behavior do not produce general value-narrowing facts on their own. They require specific narrowing rules or RBS/plugin effects before they can refine value domains.
- User-defined `==`, `eql?`, and `===` are promoted from relational facts to value facts only through explicit RBS metadata, `RBS::Extended` flow effects, or plugin-declared true-edge and false-edge facts together with any required stability or purity assumptions.

### Fact Stability and Mutation Effects

Flow facts are not all of the same kind, and they invalidate at different rates:

- Local binding facts are about which value a name refers to in this scope.
- Captured-local facts are about locals that may be written by an outer or inner closure.
- Object-content facts cover hash entries, instance variables, object-shape members, and other heap state.
- Global-storage facts cover constants, globals, class variables, and similar shared state.
- Dynamic-origin facts retain a `Dynamic[T]` marker even after narrowing.
- Relational facts record comparisons that have not yet been reduced to a value type.

Invalidation is targeted rather than scope-wide:

- Unknown method calls may invalidate heap facts for targets that could have escaped, such as object shapes, hash entries, instance variables, constants, globals, and class variables. They do not invalidate every local binding fact in scope.
- Local binding facts survive ordinary method calls until assignment to that local. A call may mutate the object referenced by `x`, but it cannot rebind `x` unless `x` is captured by a closure that writes it.
- Closure writes are explicit effects. When a block, proc, or lambda writes an outer local, Rigor records a captured-local write. Immediate known invocation applies that write at the call edge; escaping or deferred closures make writable captured-local facts unstable after the escape point.
- Higher-order calls need call-timing effects rather than a blanket "yield invalidates everything" rule. The initial categories are no block invocation, immediate non-escaping invocation with known count, immediate non-escaping invocation with unknown count, deferred or escaping block storage, and unknown block behavior.
- Core methods such as `tap`, `then`, `yield_self`, and `each_with_object` should eventually have summaries for block timing, return behavior, and receiver or argument mutation. Until those summaries exist, Rigor may weaken object-content facts touched by such calls but should preserve unrelated local binding facts.

The first proof obligations for stable facts are concrete:

- A non-reassigned local that is not writable by any escaping closure.
- Immutable singleton or immediate values.
- Values proven frozen for the relevant operation.
- Fresh allocations that have not escaped.
- RBS, `RBS::Extended`, or plugin effects that declare read-only, pure, or targeted mutation behavior.

The minimal first implementation pairs a category-bucketed fact store with immutable per-edge `Scope` snapshots:

- Each `Scope` is an immutable snapshot keyed by control-flow edge. Joins, narrowing, and invalidation produce new snapshots through structural sharing rather than in-place mutation.
- Within a snapshot, facts are partitioned into buckets that mirror the categories above: local-binding, captured-local, object-content, global-storage, dynamic-origin, and relational. Invalidation rules act on a specific bucket, so an unknown method call sweeps object-content without touching local-binding.
- Relational facts that span multiple targets live in their own bucket and are invalidated when any participating target's bucket records a change.
- The public surface of `Scope` does not expose buckets directly. Plugins, narrowing rules, and diagnostics ask `Scope` for facts about a target; the bucket layout is an internal optimization that may evolve.

The pre-plugin purity policy controls how method-call results are remembered or forgotten across re-invocations and how PHPStan-style remembered values map onto Rigor's category buckets:

- Methods are treated as impure by default. Calling an impure method on a receiver invalidates the receiver's object-content bucket and discards remembered value facts for prior calls to the same receiver.
- Purity becomes effective only when an authoritative source declares it. Core Ruby and stdlib RBS distributed with Rigor, accepted ordinary RBS files, and explicit `rigor:v1:pure` annotations on `RBS::Extended` are the initial sources. Generated signatures and plugin contributions may refine purity within their tier.
- A configuration switch should make the default look more like PHPStan's "value-returning is pure unless declared impure" policy for projects that want stronger narrowing across repeated calls. The switch flips the default but never overrides explicit `pure` or mutation declarations.
- `pure` combined with any receiver-mutation, argument-mutation, or fact-invalidation effect remains a contract conflict, as already specified in the `RBS::Extended` merge rules.

The first user-visible milestone (v1) ships built-in mutation, purity, and call-timing summaries for a small, deliberately chosen set of core and stdlib classes. Picking a fixed set keeps the v1 narrowing surface honest: code outside this set falls back to "impure by default" without pretending to know more, and authors who need precision earlier can supply `RBS::Extended` annotations or plugins.

The v1 covered set is:

| Class | Reason |
|---|---|
| `Array` | The most commonly mutated container in Ruby code; clear distinction between `<<`, `push`, `pop`, `replace` (mutate) and `map`, `select`, `+` (pure). |
| `Hash` | Same role as `Array` for keyed storage; needed for `merge!` versus `merge`, `[]=` versus `dup`-then-modify patterns. |
| `String` | Frequent target of in-place mutation (`<<`, `gsub!`, `replace`) where mistaking a pure call for impure produces real false positives. |
| `Set` | The only widely used non-core collection where in-place semantics differ from immutable composition; `add`, `delete`, `merge` versus `|`, `&`, `-`. |
| `IO` | Effect-heavy class whose call timing (`each_line`, `read`, `write`) directly drives flow stability for real file-descriptor-backed code. |
| `StringIO` | Used as a stand-in for `IO` in tests and pipelines; needs the same call-timing model so capability roles behave consistently. |
| `File` | Adds path-bound side effects on top of `IO`; `File.open` block timing and `File.write` are common enough that missing them weakens v1 noticeably. |
| `Tempfile` | Has lifetime effects (creation, unlink) that pair naturally with `_ClosableStream` and `_FileDescriptorBacked` roles. |
| `Pathname` | Common boundary for filesystem-touching code; mostly pure transformations with a small set of effectful methods (`mkdir`, `rmtree`). |
| `Logger` | Representative effect-only API; useful for validating that pure/impure separation does not regress diagnostics for side-effect-only callers. |

The v1 summaries cover, for each class:

- per-method receiver-mutation status, argument-mutation status, and fact-invalidation effect;
- per-method block call timing (no block, immediate non-escaping known-count, immediate non-escaping unknown-count, deferred or escaping, unknown);
- per-method purity declaration where it can be made without overpromising.

Classes outside this set are not silently assumed pure or impure. They follow the default impure policy until ordinary RBS, `RBS::Extended`, or plugin facts say otherwise.

The v1.1 roadmap extends coverage along three axes, behind feature flags so v1 behavior stays stable as the larger surface lands:

- additional core classes (`Numeric` and its descendants, `Symbol`, `Range`, `Regexp`, `Proc`, `Method`, `Time`, `Date`, `DateTime`);
- additional widely used stdlib (`Date`, `JSON`, `URI`, `OpenStruct`, `Forwardable`, `Comparable`-bearing classes that need explicit mutation summaries);
- selected metaprogramming-adjacent core APIs (`Module`, `Class`, `BasicObject`) once their analyzer-side modeling is stable.

Built-in mutation summaries are not a closed list. New entries may be added in any minor release as long as their addition does not change the meaning of code that does not call them; the published roadmap is a planning aid, not a contract.

### `void` Is a Return-Position Marker

RBS treats `void` as top-like but context-limited. Rigor should model `void` internally as a result marker that says the return value should not be used.

Rigor's value-context recovery is consistent with RBS's "top-like" treatment: when a `void` result reaches a value position the recovered type is `top`, not a stricter or weaker substitute. Rigor's contribution on top of the RBS rule is to record that the value reached the position by recovery from `void` and to surface that as a primary diagnostic, so the analyzer can explain *why* a `top` appeared and the user can fix the call site rather than learning to live with a generic `top`. Generated RBS continues to spell `void` only in the positions RBS allows.

This enables diagnostics such as assigning the result of a `void` method call. In statement context, `void` is fine. In value context, Rigor reports a diagnostic and recovers with `top`.

In normalized result summaries, `void | bot` collapses to `void`. A path that always raises is acceptable in a `void` context, so the union does not weaken the marker.

### Inline RBS Annotations and Inference Boundaries

Rigor's "no Rigor-specific inline type syntax" goal is about keeping Ruby code readable for humans and low-noise for AI-assisted editing. It does not mean Rigor ignores existing Ruby ecosystem annotation conventions.

Rigor should be 100% compatible with RBS and rbs-inline annotation syntax, and should follow Steep 2.0 behavior for inline annotation interpretation and precedence. RBS and rbs-inline are the primary norms for inline type syntax; Steep's implementation is the secondary norm where behavior is not fully specified in prose. TypeScript, PHPStan, and Python typing remain reference material for missing concepts, not compatibility targets.

When the three sources differ, the resolution order is:

1. RBS prose specification wins.
2. rbs-inline documentation wins for inline-syntax questions that the RBS prose does not address.
3. Steep 2.0 behavior wins only when neither RBS prose nor rbs-inline documentation specifies the behavior.

Where Steep diverges from a higher-priority source, Rigor follows the higher-priority source and treats the divergence as documented behavior. Such cases should be called out individually in `docs/types.md` so users migrating from Steep see the difference instead of discovering it through a diagnostic.

Rigor should read existing rbs-inline and Steep-compatible annotations as official type sources. It should not rewrite them, warn only because they are complex, or require `# rbs_inline: enabled`. Only the rbs-inline configuration directives such as `# rbs_inline: enabled` and `# rbs_inline: disabled` are ignored; the rbs-inline annotation comments themselves (for example `#: String`, `# @rbs`, parameter annotations) are always parsed and used as type sources whenever present.

Standalone `.rbs` files and generated stubs remain the preferred place for complete type definitions. Inline annotations are nevertheless real contracts when present. They are not merely hints.

Contract checking is independent of where the contract came from. A return type written as inline `#: void`, a method type written with `# @rbs`, parameter types written in rbs-inline style, a generated stub, and an external `.rbs` declaration all constrain the implementation in the same way. Rigor should report implementation-side diagnostics when the method body contradicts any accepted signature source.

**Recommendation level.** Rigor's style guidance is only about whether authors should write a type in `.rb` source:

- `#: void` and `#: bot` are strongly recommended when they express intent and create useful inference boundaries.
- Short returns such as `#: bool`, `#: String`, or `#: User` are neutral; authors may write them when they make intent clearer.
- Complex inline types, such as unions, generics, records, and nested method types, are valid RBS/rbs-inline input and must be accepted. Rigor's style guidance prefers moving them to `.rbs` or generated stubs, but Rigor should not report diagnostics merely for using them.

**Inference boundary contract.** When a return contract is available from any accepted signature source, callers use that declared return and Rigor can stop recursive return inference at the method boundary. The implementation body is still checked against the contract. If the body can return a value outside the declared return, Rigor reports a diagnostic on the implementation side.

This boundary is especially valuable for deep, recursive, or expensive methods. It prevents analysis from fanning out into the method body when the author has already supplied the return contract.

**Bottom type in signatures.** A `bot` return contract means the call never returns normally. Callers treat it as `bot` for reachability and dead-code analysis. If implementation analysis finds a normal return path, Rigor reports a diagnostic against the method body, regardless of whether the `bot` came from inline `#: bot`, `# @rbs`, generated RBS, or external `.rbs`.

**Example.**

```ruby
def print(foo) #: void
  puts '====='
  p foo
  puts '====='
end
```

**Why a `void` contract can matter for Ruby.** A `void` return contract tells the analyzer to treat the return as `void` and not to **propagate** a more precise inferred return from the last expression. The last line is still a Ruby value (implicit return), but the **type contract** is “no meaningful return for typing,” matching RBS’s `void` meaning. Writing `#: void` in `.rb` is strongly recommended when that inline marker makes the author's side-effect-only intent clearer, but the static meaning is the same as `void` from any other accepted signature source.

**Interaction with implicit return at runtime.** Ruby’s last-expression return means a value almost always **exists** in the VM. Rigor’s obligation remains **static** (value context, assignment, chains, boundary behavior), not a proof that the runtime value is never observed.

**Relation to `bot`.** A `bot` implementation satisfies a `void` return contract because no normal value is produced. A `void` result does not satisfy a `bot` return contract because the call may still return normally at runtime.

**Value-context recovery.** If a `void` result is assigned, chained, interpolated, passed as an argument, or otherwise used as a value, Rigor reports a primary "use of void value" diagnostic and then recovers with `top`. Immediate follow-on diagnostics caused only by that recovery, such as "method on `top`", should be suppressed for the same expression unless cascading diagnostics are explicitly requested.

**Imported RBS slots.** Existing RBS can place `void` in generic or callback slots, such as `Enumerator[Elem, void]` or a block parameter whose value is intentionally ignored. Rigor preserves these signatures for compatibility. If substitution makes such a slot appear in a value-producing position, the result is handled as a `void` result marker rather than as an ordinary value-set type.

**Interactive inference cutoffs (target behavior, not current scaffold).** This subsection describes Rigor's intended CLI behavior once the analyzer ships an interactive surface. The current scaffold does not yet implement these prompts; the description is normative for the target product, not a checklist of features that already exist. Some methods are not worth inferring from implementation alone. Recursive code with unconstrained operators is the clearest case:

```ruby
def tarai(x, y, z)
  if x <= y
    y
  else
    tarai(
      tarai(x - 1, y, z),
      tarai(y - 1, z, x),
      tarai(z - 1, x, y)
    )
  end
end
```

Many Ruby classes implement `<=` and `-`, so without a parameter or return contract this method does not have a unique useful inferred domain. The recursive calls also make return inference fan out. Rigor should stop early when operator ambiguity and recursion exceed a budget. In non-interactive mode it reports an incomplete-inference diagnostic and suggests adding a boundary contract. In interactive CLI mode it may ask the user for a compatible type source, such as `#: Integer` for a return-only cutoff, a full `# @rbs` method type, or an external `.rbs` declaration. The chosen contract is trusted by callers and checked against the implementation like any other accepted signature source.

The initial budget categories are explicit so cutoffs are predictable:

- Recursion depth on the same method or mutually recursive cluster.
- Call-graph expansion width when a body fans out into many callees without contracts.
- Overload candidate count for argument-sensitive dispatch.
- Operator ambiguity per call when an operator like `<=` or `-` accepts many receiver types.
- Union size for joined inferred returns.
- Structural requirement growth when a capability summary keeps acquiring new members.

Each budget produces an incomplete-inference result with a reason rather than a fabricated precise type. This keeps the inference compatible with the "no Rigor-specific inline type syntax in Ruby code" goal: the user resolves the cutoff with an accepted RBS-shaped contract, not with a Rigor-only DSL.

Every budget category is configurable through `.rigor.yml` under a single `budgets:` namespace, with healthy ranges enforced by the analyzer. Values outside the accepted range produce a configuration diagnostic rather than silent acceptance. The first implementation defaults and ranges are:

| Category | Default | Accepted range |
|---|---|---|
| Recursion depth | 5 | 1–32 |
| Call-graph expansion width | 16 | 1–256 |
| Overload candidate count | 8 | 1–64 |
| Operator ambiguity per call | 4 | 1–32 |
| Union size for inferred returns | 24 | 4–256 |
| Structural requirement growth | 16 | 1–256 |
| Named-interface candidate matches | 8 | 1–64 |

The same `budgets:` namespace also carries the hash-shape erasure key budget (default 16) and value budget (default 8); see `Hash Shape Erasure`. The negative-fact display budget for difference and complement diagnostics defaults to 3 retained exclusions; see `Type Operators Are Provisional`.

### Diagnostic Identifiers, Display, and Suppression

Diagnostics use hierarchical identifiers so plugin authors, RBS metadata, and user suppression markers can address them without colliding with internal numbering. The first implementation prefixes are:

| Prefix | Use |
|---|---|
| `dynamic.*` | `untyped` and `Dynamic[T]` boundary crossings, unchecked generic leaks, and method calls whose proof depends on dynamic origin |
| `static.*` | Static checks that stop short of a proof, including incomplete-inference cutoffs |
| `flow.*` | Control-flow narrowing failures, equality and predicate refinement issues, fact-stability violations |
| `compat.*` | RBS, rbs-inline, and Steep-compatible signature compatibility |
| `rbs_extended.*` | `RBS::Extended` payload validity, version compatibility, and conflict reports |
| `plugin.<plugin-id>.*` | Plugin-contributed diagnostics, as already specified in ADR-2 |
| `generated.<provider>.*` | Generated-signature provider diagnostics |

Identifiers are stable within a major version. New diagnostics may be added under any prefix; renames or removals are breaking changes that require a deprecation window.

`Dynamic[T]` provenance is displayed conservatively. Ordinary diagnostics show the narrowed static facet `T` with a small `from untyped` provenance note rather than the wrapped `Dynamic[T]` form. Diagnostics in the `dynamic.*` category, and explanations requested through `rigor explain`, show the full `Dynamic[T]` form so the dynamic origin is visible at the point where it actually matters. Internal traces and cache keys always retain the wrapped form regardless of display rules.

Suppression markers are recognized in three families to balance ecosystem migration with a clean Rigor-native form:

- Steep-style markers such as `# steep:ignore` are recognized by default. Rigor maps them to its own diagnostic suppression so existing Steep-using projects can adopt Rigor without rewriting suppression comments. The mapping is intentionally conservative: only line-scoped Steep markers are accepted, and nothing in Steep's marker grammar is reinterpreted as Rigor-specific configuration.
- Sorbet-style file-level markers (`# typed:`) and RuboCop-style suppression comments are opt-in. Projects enable them through `compat.sorbet_ignore` and `compat.rubocop_disable` switches in `.rigor.yml`. Defaulting them on would conflate Sorbet's typed-mode policy and RuboCop's lint scope with Rigor's diagnostic suppression.
- Rigor-native markers use a Ruby comment grammar that mirrors PHPStan's annotation feel without inventing application-side type DSL. The line form is `# rigor:ignore[<diagnostic.id>]`; the block form is `# rigor:ignore-start[<diagnostic.id>]` and `# rigor:ignore-end`. The diagnostic identifier list uses the prefixes defined above.

Markers that name an unknown diagnostic identifier produce a warning so dead suppressions are visible. Markers without an identifier list are diagnostics by default; strict mode rejects them entirely.

### RBS Context Rules Are Preserved

`self`, `instance`, `class`, and `void` have context restrictions in RBS. Rigor may carry richer contextual information internally, but exported RBS must obey those restrictions.

### Refinements Are Internal

Rigor can infer refined types such as non-empty strings, positive integers, literal sets, truthiness-narrowed types, and hash/object shapes. These refinements improve diagnostics and flow analysis, but they erase to ordinary RBS.

### Numeric Refinement Scope

The initial scalar refinement surface intentionally stops at `Integer`. The reserved names `positive-int`, `negative-int`, `non-positive-int`, `non-negative-int`, and `non-zero-int` are exact integer refinements, not generic sign refinements for arbitrary `Numeric` values.

- `Float` keeps the conservative rule: equality and exhaustiveness narrowing are refused by default. Comparisons may produce relational facts, but float-specific value refinements require a proof that excludes `NaN` and handles infinities and signed zero explicitly. A future `finite-float` or non-`NaN` predicate may unlock narrower facts.
- `Rational` may eventually receive exact ordered refinements, but those refinements must be Rational-specific. Rigor should not silently treat a Rational sign fact as an integer-range fact.
- `Complex` does not participate in positive, negative, or interval refinements because Ruby does not provide a total ordering for complex numbers. Useful `Complex` facts need explicit predicates or plugin/RBS effects.
- Refinements do not automatically transit `coerce` boundaries. Mixed numeric operations follow Ruby dispatch and the relevant RBS or plugin signature. If Rigor cannot prove the operation and promotion path, it preserves a relational or dynamic-origin fact and widens to the conservative nominal result.

Non-integer numeric precision is therefore opt-in through future built-ins, trusted predicates, or plugin and RBS effects, not through silent promotion of `*-int` refinements across nominal numeric boundaries.

### Pre-Plugin Inference Surface

Many Ruby code bases are dominated by `Dynamic[top]` until plugins, generated stubs, or RBS files fill in shapes. The pre-plugin surface should still produce useful facts:

- Stable Ruby guards narrow `Dynamic[top]` to `Dynamic[T]` whenever Ruby semantics or existing signatures justify the static facet. The initial useful checks include nilability, truthiness, `is_a?`, `kind_of?`, `instance_of?`, literal equality for trusted built-in domains, and `respond_to?` member-existence facts.
- Method calls on raw `Dynamic[top]` remain allowed by default so gradual code can be analyzed incrementally. They are traceable, and strict modes may report them as dynamic-to-precise crossings without changing the core relation.
- Diagnostics should explain whether a `Dynamic[T]` came from a missing signature, an explicit `untyped`, or an analyzer or plugin limit, even when no plugin is loaded.

This is the analyzer's baseline before framework- or library-specific plugins ship. Plugin-specific behavior remains deferred to ADR-2.

When this ADR refers to "v1," it means the *first user-visible product release* of the Rigor analyzer. v1 is a shipping milestone, not the entire type-model specification. The full specification described in this ADR and `docs/types.md` is normative for the long-term analyzer; v1 ships a deliberately scoped slice of that specification so the first release does not over-promise. The boundary is:

- The full specification — fact-stability buckets, capability-role catalog, mutation summary set, Dynamic[T] algebra, type operators, RBS::Extended schema — is normative. Internal data structures may be present in v1 even when the user-visible narrowing surface does not yet exploit them.
- The v1 narrowing surface is the subset of derivation rules that are turned on for end users in the first release.
- v1.1 is the next user-visible release; it expands the narrowing surface using rules that the data structures already support, behind feature flags so v1 behavior is preserved.

The v1 narrowing surface ships:

- Literal narrowing for `nil`, `true`, `false`, integer and string literals, and finite literal-union refinements produced by equality checks against trusted built-in domains.
- Syntax-level guards: `is_a?`, `kind_of?`, `instance_of?`, `nil?`, truthiness, `respond_to?`, equality with literal sets, and class- and pattern-matching narrowing in `case` and `case/in` forms that do not require dataflow across statements.
- Method-call resolution that uses RBS or `RBS::Extended` for core Ruby and a curated subset of stdlib without requiring user plugins. Generated signatures from `RBS::Extended` may participate.
- Direct application of the bundled mutation summaries described in `Fact Stability and Mutation Effects` at call sites where the receiver is statically known. The summaries drive bucket invalidation locally; cross-statement propagation of those effects is a v1.1 surface.

The v1 narrowing surface does *not* yet expose:

- Intra-procedural propagation of facts and mutation effects across statements, joins, and loops.
- Inference of capability-role *requirements* from method bodies (the catalog and explicit conformance directives are available; inferring "what role does this body require" is v1.1).
- Plugin-supplied flow contributions, which depend on ADR-2.

Each v1.1 surface ships behind a feature flag so the v1 release behaves consistently while the larger surface lands.

### Imported Built-Ins Follow Ruby Semantics

Rigor should import PHPStan, TypeScript, and Python typing ideas by semantic value, not by syntax compatibility.

Reserved built-in refinement names use `kebab-case` spellings when they are recognizable and map cleanly to Ruby, such as `non-empty-string`, `positive-int`, `lowercase-string`, `literal-string`, `numeric-string`, `decimal-int-string`, and `non-empty-array[T]`. The hyphen is intentional because it cannot appear in Ruby constants or RBS alias names, so these names are visibly Rigor-reserved.

Parameterized type functions should use one canonical lower_snake Rigor spelling with square brackets. For example, `key_of[T]` is preferred over accepting both PHPStan-style `key-of<T>` and TypeScript-style `keyof T`. Type functions compute, project, or transform another type or literal set; they avoid hyphens because `-` is also the difference operator in Rigor's type syntax. Additional spellings should require a concrete migration or readability benefit.

RBS names remain canonical when they already exist. `bot` is the bottom type; PHPStan aliases such as `never`, `noreturn`, `never-return`, `never-returns`, and `no-return`, and Python aliases such as `Never` and `NoReturn`, should not be added as initial aliases.

Class-name string types are deferred. Ruby can pass class and module objects directly, and RBS already has `singleton(C)`. A PHPStan `new`-like type operation or Python `type[C]`-like projection remains a future candidate, but it should be designed around Ruby class objects and factory APIs rather than class-name strings.

### Type Operators Are Provisional

Rigor should support the semantics of complement, difference, indexed access, shape projection, and possibly conditional types. The final syntax is undecided.

The candidate `~T` operator means the complement of `T` within the current known domain, not necessarily every Ruby object except `T`.

The current known domain is the left-hand side's already-established positive domain, not a domain inferred from the excluded value. For example, `v != "foo"` narrows `v: String` to `String - "foo"`, but it does not narrow `v: untyped` to `String - "foo"`. With raw `untyped`, Rigor keeps `Dynamic[top]` plus a dynamic-origin relational fact.

The working notation policy is:

- Use `~T` as the concise display form for CFA-produced negative facts.
- Use `T - U` as the preferred explicit authoring form for difference types in `RBS::Extended` annotations.
- Allow the implementation to normalize `T - U` to `T & ~U`.

Retention follows finite-domain precision and a budget for open domains:

- Finite domains normalize exactly. `"foo" | "bar"` minus `"foo"` becomes `"bar"`; removing every alternative becomes `bot`.
- Large or unknown domains keep negative facts under a budget. When the budget is exceeded, Rigor records that exclusions were omitted and falls back to the positive domain rather than rendering unstable chains such as `Integer - 0 - 1 - 2 - ...`.
- Negative facts follow the same stability rules as other flow facts: assignment, mutation, unknown calls, yielded blocks, and plugin-declared invalidation may weaken or remove them.

Diagnostic display follows a domain-aware contract so users do not misread negative facts as global complements:

- Internal normalization may continue to use `T & ~U`, but diagnostics should render with the current positive domain visible.
- Small finite domains display as their normalized positive union. For example, `"foo" | "bar" - "foo"` displays as `"bar"`.
- Broad known domains display as `D - U`, such as `String - "foo"` or `Integer - 0`, rather than a bare complement.
- Multiple retained exclusions display as a flattened difference, such as `String - ("" | "foo")`, rather than nested differences or repeated intersections.
- Bare `~U` is allowed only for compact branch-local display when the surrounding diagnostic already states the domain. Otherwise Rigor prefers `D - U`, `top - U`, or prose that names the domain.
- Dynamic-origin provenance does not replace the domain display. A diagnostic may show `String - "foo"` with a dynamic-origin note, while technical traces may show `Dynamic[String - "foo"]`.
- When the exclusion budget is exceeded, Rigor displays the positive domain plus an omission note instead of a long unstable chain.

The omission contract is concrete enough that diagnostics stay short by default and remain explorable on demand:

- The default display budget keeps the top three retained exclusions and ends with `+N more` when more were retained internally. Selection prefers values that participated most recently in narrowing decisions, then literal values over nominal bases, then lexicographic order to keep output stable.
- The `+N more` note links to the diagnostic identifier so users know they can ask for the full breakdown.
- `rigor explain <diagnostic-id>` (and the equivalent `--explain` CLI flag) prints the full domain difference, including every retained exclusion and the budget that was exceeded, in the spirit of PHPStan's analysis explanation. The full form is also available to plugins through the `Scope` API for higher-tier diagnostics that want to render the whole reasoning chain.
- The default budget is configurable through `.rigor.yml` (`budgets.negative_fact_display`) within the same healthy-range enforcement as other budgets.

### `RBS::Extended` Is an Annotation-Based Metadata Layer

Advanced types may be attached to ordinary RBS declarations, members, and overloads using RBS `%a{...}` annotations. This preserves compatibility with standard RBS tooling while giving Rigor a place to read refinements such as `String - ""`, `~"foo"`, or `String where non_empty`.

`RBS::Extended` is Rigor's name for the convention of carrying its metadata inside ordinary RBS `%a{...}` annotations under a reserved key namespace. The reserved keys for the first version are `rigor:v1:<directive>` payloads. Other tools' annotations under unrelated keys are not consumed by Rigor and pass through analysis unchanged. Rigor never rewrites another tool's `%a{...}` annotations during erasure.

The canonical directive form is a versioned `rigor:v1:` key followed by a payload. The schema lives in `docs/types.md` `RBS::Extended Annotations`; ADR-1 defines design decisions and uses `docs/types.md` as the single source of truth for the directive grammar. The canonical predicate example referenced from this ADR is:

```rbs
%a{rigor:v1:predicate-if-true value is String}
def string?: (untyped value) -> bool
```

Predicate targets are initially limited to RBS parameter names and `self`. RBS parameter names use the `_var-name_ ::= /[a-z]\w*/` grammar, so Rigor does not need to encode arbitrary Ruby Symbol names in directive identifiers. Hyphenated directive names such as `predicate-if-true` are safe because they are parsed from the annotation payload by Rigor. Other directive spellings live in `docs/types.md`.

The version prefix is part of the compatibility contract. Rigor-generated annotations must use `rigor:v1:`. Unversioned `rigor:` directives should be invalid for now rather than silently treated as v1. Unsupported future versions such as `rigor:v2:` are preserved by ordinary RBS tooling, but Rigor should report unsupported metadata when it analyzes the node.

Conformance can be checked implicitly or explicitly. Implicit conformance is the default: ordinary assignments, parameter passing, and method calls trigger structural compatibility checks against the relevant interface or capability role. No author-visible opt-in is required. In addition, Rigor accepts an explicit *design assertion* directive:

```rbs
%a{rigor:v1:conforms-to _RewindableStream}
class MyBuffer
end
```

The directive instructs Rigor to verify that `MyBuffer` satisfies `_RewindableStream` regardless of whether any current call site exercises that requirement. It is useful for libraries that want to guarantee a class meets a structural interface as part of their public contract. The directive is purely additive: it does not change the semantics of implicit conformance, and a class that already satisfies the interface continues to type-check without the annotation.

If `RBS::Extended` metadata conflicts with the ordinary RBS signature, Rigor should report a diagnostic.

Multiple annotations on the same node are combined by directive kind, target, and flow edge. Exact duplicates are idempotent. Compatible effects compose; for example, true-edge and false-edge predicate annotations occupy different effect slots. Conflicts are always diagnostics, never first-wins or last-wins. This includes incompatible payload syntax, incompatible versions on the same node, two non-identical singleton directives for the same effect slot, contradictory refinements whose intersection is `bot`, refinements that exceed the ordinary RBS signature, and effect declarations that cannot both be true such as a "pure" effect combined with a receiver-mutation effect.

Type guard and assertion effects should be modeled as flow effects, not as ordinary return types. This keeps signatures RBS-compatible while still allowing TypeScript-style narrowing, PHPStan-style assertion behavior, and Python `TypeGuard`/`TypeIs`-style predicates.

ADR-1 owns the semantic schema for flow effect bundles: the field set, target-path meaning, certainty rules, and how effects change scopes. ADR-2 owns the extension API packaging, registration, service lifetime, and plugin provenance for those bundles. The product specification in `docs/types.md` is the detailed normative table both ADRs should reference.

### Erasure Must Be Conservative

If `T` is a Rigor type and `erase(T)` is the generated RBS type, every value accepted by `T` must be accepted by `erase(T)`.

Erasure can lose precision. It must not become narrower than the internal type.

### Hash Shape Erasure

Hash shapes carry more information than RBS records and `Hash[K, V]` can express. Rigor's erasure rule preserves what RBS can spell and falls back deterministically when it cannot. The detailed algorithm lives in `docs/types.md`; the strategic decisions are:

- Exact closed shapes erase to RBS records when every key can be represented by RBS record syntax. Required entries become required record fields, optional entries become optional fields when spellable, and values erase recursively.
- Optional-key absence is not a stored `nil`. Rigor must not add `nil` to a value type merely because a key is optional.
- Read-only, provenance, stability, key-presence, and open/closed markers are erased. Losing them is reportable in strict export or explanation mode.
- Shapes that cannot be represented exactly as records erase to `Hash[K, V]`.
- `K` is the union of known literal keys, widened nominal key classes when literal unions exceed the export budget, and the extra-key bound for open shapes. Statically unknown extra keys use `top`; dynamic-origin extra keys use `untyped`.
- `V` is the union of known required values, known optional values, and the extra-value bound for open shapes. Statically unknown extra values use `top`; dynamic-origin extra values use `untyped`.
- For open shapes, the extra-value bound wins over the current observed value union. Rigor does not infer that all future extra keys have values drawn only from already-seen entries.
- Exact empty closed records erase to `{}` when the target RBS output supports it; otherwise the conservative fallback is `Hash[bot, bot]`, which preserves the "no entries possible" fact.

Key and value export budgets are configured separately because hash keys carry more identifier-like meaning than values do. The first implementation defaults are 16 for the literal-key union and 8 for the literal-value union, both configurable through `.rigor.yml` (`budgets.hash_erasure_keys`, `budgets.hash_erasure_values`). When a budget is exceeded, the corresponding axis widens to the nearest nominal base while the other axis stays as a literal union if it still fits.

## Feedback from the Resulting Type Specification

Reconstructing `docs/types.md` as the ideal type model adds several requirements that this ADR should carry forward:

- Structural typing should be explicit but limited. RBS classes and modules remain nominal; RBS interfaces and Rigor object shapes are the bridge for Ruby duck typing.
- IO-like compatibility should be modeled through inferred capability roles, not by treating unrelated nominal classes as subtypes or by requiring ad hoc unions at every call site.
- Object-shape facts need member kind, call signature, visibility, provenance, stability, and certainty. A `respond_to?` guard can prove member existence, but it is not enough to prove full interface compatibility.
- The type engine needs expression-edge scopes. Each expression should be able to produce normal, truthy, falsey, exceptional, and unreachable output scopes so short-circuiting conditions can update facts between operands.
- Negative and difference types need a current-domain model. `~"foo"` inside `String | Symbol` is not the same as global `top - "foo"` unless the current domain is `top`.
- Equality narrowing must respect Ruby dispatch. Rigor needs trusted equality facts for built-ins, RBS effects, or plugins; otherwise it should keep relational facts instead of silently pretending `==` is identity.
- Gradual facts need provenance. Narrowing an `untyped` value can be useful inside a branch, but diagnostics, generic slots, and joins should still know that the value crossed an unchecked boundary. The working internal form is `Dynamic[T]`, with raw `untyped` represented as `Dynamic[top]`.
- Shape, member, and hash-key facts need invalidation rules. Assignments, mutation, unknown calls, yielded blocks, and plugin-declared effects may weaken or remove facts.
- RBS erasure is part of the type design, not a presentation layer. Every internal refinement, relation, and provenance marker needs a conservative erasure rule.

## Rejected and Deferred Candidate Decisions

This ADR keeps explicit notes for candidate ideas that were discussed but not accepted as the current direction.

| Candidate | Status | Reason |
| --- | --- | --- |
| Treating `untyped` as another name for `top` | Rejected | `untyped` marks a gradual boundary and loss of precision; `top` is the greatest static value type. Collapsing them would lose diagnostics and provenance. |
| Writing gradual consistency as `A ~ B` | Rejected | The `~T` form is reserved for negative or complement types, so gradual consistency is written as `consistent(A, B)`. |
| Free-form `# @rigor ...` comments in `*.rbs` | Rejected | RBS `%a{...}` annotations are parsed into the RBS AST and attach to declarations, members, and overloads. Free-form comments would require a parallel attachment model. |
| Encoding type predicates as ordinary return types | Rejected | Predicate and assertion behavior changes the flow environment, not the runtime return value. Rigor records those effects through `RBS::Extended` annotations. |
| Arbitrary predicate target syntax in the first version | Rejected for now | Initial targets are limited to RBS parameter names and `self`; shape paths, instance variables, and block parameters can be added later with explicit path syntax. |
| Importing `class-string`, `interface-string`, `trait-string`, or `enum-string` | Deferred | Ruby can pass class and module objects directly, and RBS already has `singleton(C)`. String-based class names are less central than they are in PHP. |
| Importing PHPStan's `new` operation as a class-name-string operation | Deferred | A `new`-like projection may be useful for factory APIs, but it should be designed around Ruby class objects rather than class-name strings. |
| Adding `never`, `noreturn`, `never-return`, `never-returns`, and `no-return` as aliases for `bot` | Rejected for now | RBS already provides `bot`; adding aliases would increase notation without improving expressiveness. |
| Adding Python `Never` and `NoReturn` as aliases for `bot` | Rejected for now | They map conceptually to `bot`, but Rigor should keep RBS spelling canonical at the boundary. |
| Importing TypeScript `any`, `unknown`, `object`, `undefined`, `null`, or `never` spellings | Rejected | RBS already provides `untyped`, `top`, `nil`, and `bot`; TypeScript's names are tied to JavaScript's runtime value model. |
| Importing Python `Any` and `object` spellings | Rejected | RBS already provides `untyped` for the dynamic type and `top` for the greatest static type. |
| Importing Python `Protocol`, `TypedDict`, `Annotated`, `TypeGuard`, `TypeIs`, `Final`, or `ClassVar` syntax directly | Rejected | Their useful ideas map to RBS interfaces, records, `%a{...}` annotations, flow effects, and separate symbol or member facts. |
| Treating all class compatibility as TypeScript-style structural assignment | Rejected | RBS class and module names are nominal. Structural checking belongs to RBS interfaces, object shapes, and explicit shape-like facts. |
| Requiring explicit protocol inheritance or registration for structural interface assignability | Rejected for now | Ruby duck typing works best when structural compatibility can be inferred from members. Explicit declarations may still be useful as verification requests. |
| Accepting both `key-of<T>` and `keyof T` | Rejected for now | Rigor should use one canonical type-function spelling, currently `key_of[T]`, unless compatibility aliases show concrete value. |
| Importing PHPStan-style integer ranges such as `int<1, 10>` | Rejected for now | Rigor should use its own range notation, such as `Integer[1..10]`, to stay closer to Ruby and RBS naming. |
| Adding lower_snake aliases for built-in refinement names, such as `non_empty_string` | Rejected for now | Hyphenated refinement names are intentionally reserved for Rigor built-ins. Lower_snake names should remain available for ordinary RBS type aliases. |
| Adding `lower-string` as an alias | Rejected for now | `lowercase-string` is the established spelling and is clearer. |
| Adding `non-falsy-string` or `truthy-string` | Rejected | Every Ruby `String` value is truthy, so these types do not add precision. |
| Importing PHP truthiness types such as `empty`, `empty-scalar`, `non-empty-scalar`, and `non-empty-mixed` | Rejected | They are tied to PHP's truthiness model. Rigor models Ruby truthiness through `false | nil` flow facts and explicit string/collection refinements. |
| Importing `list<T>` and `non-empty-list<T>` as separate surface types | Rejected for now | Ruby `Array[T]` already has list-like indexing semantics; `non-empty-array[T]` provides the useful additional refinement. |
| Adding `non-decimal-int-string` as a named built-in | Rejected for now | It can be expressed as `String - decimal-int-string` without adding another built-in name. |
| Adding `Exclude`, `Extract`, and `NonNullable` as surface aliases | Rejected for now | Rigor can express them directly as `T - U`, `T & U`, and `T - nil`. |
| Adding TypeScript utility or mapped type aliases such as `Partial`, `Required`, `Readonly`, `Pick`, `Omit`, `Record`, `Parameters`, `ReturnType`, or `InstanceType` | Rejected for now | These are useful reference designs, but Rigor should first expose smaller Ruby/RBS-shaped shape facts and type functions. |
| Using TypeScript syntax `T extends U ? X : Y` as the canonical conditional type syntax | Rejected for now | Rigor should avoid copying TypeScript syntax unless it fits the rest of the type language. The current candidate is `if T <: U then X else Y`. |

## Consequences

Positive:

- Rigor can produce precise diagnostics while remaining compatible with RBS.
- Generated RBS can be consumed by existing RBS-aware tools.
- `untyped`, `top`, `bot`, and `void` retain distinct meanings internally.
- PHPStan-, TypeScript-, and Python-style flow analysis becomes part of the core design.
- Advanced library facts can be added in `.rbs` annotations without modifying Ruby application code.
- Future plugins can contribute precise facts without requiring new user-facing syntax.

Negative:

- The type engine needs more than a direct wrapper around RBS ASTs.
- RBS export requires loss-of-precision handling.
- Documentation must clearly explain why Rigor may infer more than it can export.
- `RBS::Extended` needs a careful annotation payload grammar and conflict rules.
- Negative and complement types require domain-aware normalization.

## Open Questions

- Which Rigor-only refinements should be implemented first after the MVP union/no-method diagnostic?
- How much of the `~T` and `T - U` notation should be accepted in user-authored `RBS::Extended` annotations in the first implementation?
- Which imported built-in refinements should be accepted in the first parser milestone beyond `non-empty-string` and integer ranges?
- How quickly should predicate targets grow beyond `parameter-name` and `self`?
- Which Python `TypedDict`-inspired shape facts, such as read-only keys and open or closed extra-key policies, should ship first?
- Should Rigor model finality and read-only member facts separately from value types in the first signature metadata grammar?
- Should generated RBS preserve `RBS::Extended` annotations that explain erased refinements when users request an annotated export?
- Which dynamic-origin sources should be classified as explicit user intent, missing signatures, analyzer limits, or plugin-declared dynamic behavior?
- What plugin API is needed for framework-specific object shapes and dynamic method resolution?
- What exact `RBS::Extended` or plugin payload should declare custom equality effects?
- What cache keys and invalidation rules should capability requirement summaries use across edits and dependency signature changes?
- How should interactive CLI prompts choose between inline `#:`, full `# @rbs`, generated stubs, and external `.rbs` persistence targets?
- Which generic variance cases require special handling for `Dynamic[T]` slots in the first implementation?
- What exact trusted predicate or effect payload should prove finite, non-`NaN`, and signed-zero behavior if float refinements are introduced later?
- What exact effect payload should encode block call timing, closure escape, receiver or argument mutation, and read-only/pure behavior?
- Which non-predicate `rigor:v1:` directives should be standardized first, and which should remain plugin-only metadata?
- Which non-integer numeric refinement names, if any, should be accepted after the integer refinement milestone?
- How exactly should Rigor model Ruby protected-call receiver restrictions in structural interface and object-shape checks?

## Resulting Specification

The current draft specification is maintained in `docs/types.md`.
