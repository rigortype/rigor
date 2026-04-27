# ADR-1: Type Model and RBS Superset Strategy

## Status

Draft

## Context

Rigor is an inference-first static analyzer for Ruby. It must interoperate with the existing RBS ecosystem while supporting internal types that are more precise than RBS can express.

RBS already defines a rich type syntax, including nominal types, singleton class types, literal types, unions, intersections, optionals, records, tuples, proc types, type variables, `self`, `instance`, `class`, `bool`, `untyped`, `nil`, `top`, `bot`, and `void`.

Rigor should also learn aggressively from PHPStan, TypeScript, and Python's typing specification. Those systems demonstrate that practical static analysis benefits from literal types, finite unions, control-flow narrowing, negative facts, shape-like types, gradual typing discipline, and expressive type operators. Rigor should adapt those ideas to Ruby and RBS rather than copying their syntax uncritically.

The initial design requirement is:

- Every RBS type is a valid Rigor type.
- Rigor may infer richer types than RBS.
- Every Rigor-inferred type can be conservatively erased to valid RBS.
- Special RBS types such as `untyped`, `top`, `bot`, and `void` must be handled with type-theoretic clarity rather than as ad hoc aliases.
- Types that exceed RBS may be recorded in RBS annotations under a provisional `RBS::Extended` convention.

The compatibility hierarchy is:

- RBS and rbs-inline are first-order norms for type syntax and inline annotation compatibility.
- Steep 2.0 behavior is the second-order norm for how existing annotations are interpreted when prose specifications leave behavior open.
- TypeScript, PHPStan, and Python typing are design references used to find missing concepts and practical analyzer features; they are not syntax compatibility targets.

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

## Key Design Points

### Subtyping and Gradual Consistency Are Separate

Rigor should distinguish ordinary subtyping from gradual consistency.

`top` is the greatest static value type. `bot` is the empty type. `untyped` is the dynamic type and should not be collapsed into `top`, even though RBS describes it as both a subtype and supertype of all types for gradual typing purposes.

This separation lets Rigor keep track of unchecked boundaries while still allowing gradual code to type-check.

Internally, dynamic-origin values should be represented as `Dynamic[T]`, where `T` is the currently known static facet. Raw `untyped` is `Dynamic[top]`. This is not user-facing RBS syntax; it is the implementation device that lets Rigor narrow an unchecked value without losing the fact that the value came from a gradual boundary.

The documentation should write the gradual-consistency relation as `consistent(A, B)`, not `A ~ B`, because `~T` is reserved for negative or complement types.

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
| Type predicates | TypeScript writes predicates as return types such as `parameter is Type`, and classes may use `this is Type`. | RBS has no equivalent return type form. Rigor should express these as annotations such as `rigor:predicate-if-true value is T` on ordinary RBS signatures. |
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

### Capability Roles Beat Ad Hoc Mock Unions

Ruby libraries often accept objects that are not related by inheritance but share the capability required by a method body. `IO` and `StringIO` are the central example: `StringIO` is useful as an in-memory test double for many stream consumers, but it is not a subclass of `IO` and does not expose the full `IO` method surface.

Rigor should not model this by declaring `StringIO <: IO`. It should also avoid pushing users toward repetitive declarations such as `IO | StringIO` when the implementation merely needs a small stream capability. Instead, Rigor should infer and support structural capability roles such as readable, writable, rewindable, closable, seekable, and file-descriptor-backed.

This keeps three facts separate:

- `IO` is the nominal type for real `IO` objects and APIs that require file-descriptor-backed behavior.
- `StringIO` is a separate nominal type that can satisfy some stream roles.
- A method's inferred parameter requirement may be a smaller object shape or named interface, such as readable and rewindable stream behavior.

Explicit RBS declarations still define public contracts. If a signature says `IO`, passing `StringIO` should not be silently accepted as a subtype. Rigor may instead report that the implementation appears to require only a smaller capability role and suggest generalizing the signature to an interface. Unions remain appropriate when the implementation genuinely branches on or uses class-specific behavior from both `IO` and `StringIO`.

### Control-Flow Narrowing Is Central

Rigor should run appropriate CFA and data-flow analysis, similar in spirit to PHPStan, TypeScript, and Python type checkers.

For example, after `value == "foo"`, the true branch can narrow `value` to `"foo"` and the false branch can carry the negative fact displayed as `~"foo"` when `value` already has a compatible trusted domain. The comparison does not create that positive domain by itself. The exact operator syntax is provisional, but the semantic capability is required.

Python's `TypeGuard` and `TypeIs` distinction supports the same design direction: predicate behavior is a flow effect. A true-only predicate is enough for `TypeGuard`-like behavior; paired true and false facts, or a false fact expressed as `T & ~U`, provide `TypeIs`-like behavior.

CFA must be fine-grained enough to update scope inside a condition expression, not only after the whole condition has been evaluated. For `if foo == "foo" && foo == "bar"`, the right side of `&&` is analyzed in the scope produced by the left side's true edge. If the current domain makes `"foo" & "bar"` impossible, the whole true branch becomes `bot`. The same principle applies to `||`, `!`, `unless`, `elsif`, `case`, and pattern matching.

Ruby equality is method dispatch, so equality narrowing cannot be a purely syntactic rule. `equal?`, `nil?`, boolean checks, trusted built-in literal domains, and predicate effects declared by RBS or plugins can produce type facts. Unknown `==` implementations should produce a weaker relational fact unless Rigor has method information that justifies a value-type refinement.

Raw `untyped` equality remains dynamic-origin relational information. `v: untyped` followed by `v == "foo"` does not become `Dynamic["foo"]` unless an independent guard or trusted equality effect proves that narrowing.

### `void` Is a Return-Position Marker

RBS treats `void` as top-like but context-limited. Rigor should model `void` internally as a result marker that says the return value should not be used.

This enables diagnostics such as assigning the result of a `void` method call. In statement context, `void` is fine. In value context, Rigor reports a diagnostic and recovers with `top`.

### Inline RBS Annotations and Inference Boundaries

Rigor's "no Rigor-specific inline type syntax" goal is about keeping Ruby code readable for humans and low-noise for AI-assisted editing. It does not mean Rigor ignores existing Ruby ecosystem annotation conventions.

Rigor should be 100% compatible with RBS and rbs-inline annotation syntax, and should follow Steep 2.0 behavior for inline annotation interpretation and precedence. RBS and rbs-inline are the primary norms for inline type syntax; Steep's implementation is the secondary norm where behavior is not fully specified in prose. TypeScript, PHPStan, and Python typing remain reference material for missing concepts, not compatibility targets.

Rigor should read existing rbs-inline and Steep-compatible annotations as official type sources. It should not rewrite them, warn only because they are complex, or require `# rbs_inline: enabled`. The `rbs_inline` magic comments are ignored for Rigor analysis; compatible annotations are read whenever present.

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

**Interactive inference cutoffs.** Some methods are not worth inferring from implementation alone. Recursive code with unconstrained operators is the clearest case:

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

### RBS Context Rules Are Preserved

`self`, `instance`, `class`, and `void` have context restrictions in RBS. Rigor may carry richer contextual information internally, but exported RBS must obey those restrictions.

### Refinements Are Internal

Rigor can infer refined types such as non-empty strings, positive integers, literal sets, truthiness-narrowed types, and hash/object shapes. These refinements improve diagnostics and flow analysis, but they erase to ordinary RBS.

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

### `RBS::Extended` Is an Annotation-Based Metadata Layer

Advanced types may be attached to ordinary RBS declarations, members, and overloads using RBS `%a{...}` annotations. This preserves compatibility with standard RBS tooling while giving Rigor a place to read refinements such as `String - ""`, `~"foo"`, or `String where non_empty`.

The canonical form should use a `rigor:` annotation key followed by a payload, for example:

```rbs
%a{rigor:predicate-if-true value is String}
def string?: (untyped value) -> bool
```

Predicate targets should initially be limited to RBS parameter names and `self`. RBS parameter names use the `_var-name_ ::= /[a-z]\w*/` grammar, so Rigor does not need to encode arbitrary Ruby Symbol names in directive identifiers. Hyphenated directive names such as `predicate-if-true` are safe because they are parsed from the annotation payload by Rigor.

If `RBS::Extended` metadata conflicts with the ordinary RBS signature, Rigor should report a diagnostic.

Type guard and assertion effects should be modeled as flow effects, not as ordinary return types. This keeps signatures RBS-compatible while still allowing TypeScript-style narrowing, PHPStan-style assertion behavior, and Python `TypeGuard`/`TypeIs`-style predicates.

### Erasure Must Be Conservative

If `T` is a Rigor type and `erase(T)` is the generated RBS type, every value accepted by `T` must be accepted by `erase(T)`.

Erasure can lose precision. It must not become narrower than the internal type.

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

## Identified Concerns from Critical Review

A critical review of the type specification and the decisions above surfaced the following risks. They are not blockers for the current draft, but each will need either a working decision or an explicit deferral before the type engine can be implemented end to end.

### Gradual Typing Rules around `untyped` Need More Than Joins

The earlier spec covered `T | untyped = untyped` and `consistent(untyped, T)`, but several supporting rules were missing:

- The result of `untyped & T` is not stated. Treating it as `T` discards dynamic-origin provenance; treating it as `untyped` discards information already carried by `T`.
- `untyped` in generic positions (`Array[untyped]`, `Hash[Symbol, untyped]`, proc parameters) interacts with variance and member-access narrowing. Top-level join rules do not extrapolate to those positions.
- Rigor's strict-mode story for `untyped` propagation is unspecified. Without one, every union with `untyped` collapses, and the dynamic-origin marker offers little leverage to users actively shrinking their gradual surface.

Working response:

- Rigor should use an internal `Dynamic[T]` wrapper. Raw RBS `untyped` is `Dynamic[top]`.
- Joins, intersections, and differences transform the static facet while preserving dynamic provenance: `Dynamic[A] | Dynamic[B] = Dynamic[A | B]`, `T | Dynamic[U] = Dynamic[T | U]`, `Dynamic[T] & U = Dynamic[T & U]`, and `Dynamic[T] - U = Dynamic[T - U]`.
- Generic positions preserve dynamic-origin slots. `Array[untyped]` becomes `Array[Dynamic[top]]`, so element reads, writes, and leaks can be explained precisely.
- Gradual consistency allows `Dynamic[T]` to cross typed boundaries, but subtyping and member lookup still use the static facet when one is available.
- Strict modes should use the provenance rather than changing the core relation: one level can report dynamic-to-precise boundary crossings and unchecked generic leaks; a stricter level can report operations whose proof depends on dynamic-origin facts.

This resolves the shape of `untyped` propagation while leaving user-facing diagnostic policy, displayed type notation, and strict-mode names as implementation design tasks.

### `void` Interacts with the Lattice but Is Described Only in Return Position

`void` is placed outside the value lattice, but the critical review identified several follow-up rules:

- The relation between `void` and `bot` is not stated. A method that always raises has return type `bot`; whether such a value is acceptable in a `void` context should be explicit.
- RBS allows `void` as a generic argument in some library signatures. Internal queries on shapes such as `Array[void]` and `Hash[K, void]` need defined behavior even if user-authored Rigor types forbid them.
- Because a `void` value materializes to `top` in value context, the diagnostic precedence between "use of `void` value" and "method on `top` without proof" must be picked.

Working response:

- `void` remains a no-use result marker, not an ordinary value-set type.
- `bot` satisfies `void` because a non-returning path produces no usable value. `void` does not satisfy `bot` because a `void` call may return normally.
- In result summaries, `void | bot` normalizes to `void`.
- Imported RBS signatures may contain `void` in generic, block, or callback slots. Rigor preserves those slots for compatibility. If substitution exposes such a slot in an ordinary value-producing position, the expression has a `void` result marker and follows the normal value-context rule.
- A value-context use of `void` is the primary diagnostic. Recovery uses `top`, but immediate diagnostics caused only by recovery should be suppressed to avoid noisy cascades.

This resolves the core `void` lattice concern. Remaining design work is mostly about diagnostic identifiers and UX wording, not the type relation itself.

### Negative Facts Have No Retention or Display Policy

"Negative facts are first-class" gives a direction without bounding cost or readability:

- Sequences such as `Integer - 0 - 1 - 2 - ...` are naturally expressible but can blow up in memory, normalization, and rendered diagnostics.
- The interaction between accumulated negative facts and other narrowing operations such as `is_a?(Integer)`, `respond_to?`, and pattern matching is not described.
- Diagnostic display of large negative-fact sets needs a simplification rule (analogous to TypeScript's literal-set widening) so error output stays usable at scale.

Working response:

- Negative facts are stored as scope facts over an existing positive domain. They remove from what is already known; they do not introduce a positive domain from the excluded expression.
- `v: untyped` followed by `v != "foo"` remains `Dynamic[top]` with a dynamic-origin relational fact. It does not become `Dynamic[String - "foo"]`.
- Finite domains normalize exactly. `"foo" | "bar"` minus `"foo"` becomes `"bar"`, and removing every finite alternative becomes `bot`.
- Large or unknown domains retain negative facts under a budget. Once the budget is exceeded, Rigor should keep provenance that exclusions were omitted and display the positive domain rather than rendering unstable chains like `Integer - 0 - 1 - 2 - ...`.
- Display should prefer domain-bearing forms such as `String - "foo"` when a bare `~"foo"` would be ambiguous. Bare `~T` remains useful for compact branch-local display when the surrounding domain is already visible.
- Negative facts have the same stability rules as other flow facts: assignment, mutation, unknown calls, yielded blocks, and plugin-declared invalidation may weaken or remove them.

This resolves retention at the type-model level. The exact numeric budget and diagnostic wording remain implementation policy.

### Equality Narrowing Trusts a Not-Yet-Enumerated Set of Methods

The spec invokes "trusted built-in immutable domains" and "trusted predicate and equality methods" without naming them:

- `Float` equality is unsound for `NaN`. If literal narrowing is allowed for `Float`, `NaN` becomes a soundness pitfall; if forbidden, the rule should say so.
- `Range`, `Regexp`, `Symbol`, and `Module` have well-defined equality, but their `==` and `===` are not classified as trusted or untrusted.
- `equal?` is the closest thing to identity in Ruby, but identity facts can degrade after `dup`, `freeze`, marshalling, or singleton-class reopen. Pairing identity narrowing with explicit invalidation rules is left implicit.
- The conditions under which a user-defined `==` is promoted from a relational fact to a value-narrowing fact are not defined.

Working response:

- Equality narrowing is trusted only when Rigor knows the dispatched comparison behavior and the narrowed value already has a compatible positive domain. Syntax such as `value == "foo"` is not enough by itself.
- Raw `untyped` equality remains relational. `v: untyped` with `v == "foo"` or `v != "foo"` keeps `Dynamic[top]` plus a dynamic-origin relational fact unless another guard or declared effect proves a positive domain.
- `equal?` produces identity facts, but those facts are tied to the observed reference and follow ordinary stability rules. Reassignment, alias-escaping mutation, unknown calls, or plugin-declared invalidation may weaken them.
- Built-in literal-domain equality is initially trusted for finite domains of `String`, `Symbol`, `Integer`, booleans, and `nil` when the receiver dispatch target is known and the receiver domain is already compatible.
- `Float` literal narrowing is refused by default. Rigor may keep relational facts for diagnostics, but `NaN`, signed zero, infinities, and numeric coercion make default exhaustiveness over float literals too easy to get wrong.
- `Range`, `Regexp`, `Module`, `Class`, and `===`-based case behavior are not general equality facts. They need specific narrowing rules or plugin/RBS effects before they can refine value domains.
- User-defined `==`, `eql?`, and `===` can be promoted from relational facts to value facts only through explicit RBS metadata, `RBS::Extended` flow effects, or plugins that declare true-edge and false-edge facts plus any required stability or purity assumptions.

This keeps useful literal narrowing while avoiding a TypeScript-style assumption that equality syntax is intrinsically value-set comparison.

### Mutation Invalidation Rules Are Too Coarse for Idiomatic Ruby

"Unknown method calls invalidate facts" and "block-yielded code may invalidate facts" cover the worst case, but they are too aggressive for typical Ruby code:

- `each_with_object`, `tap`, `then`, `yield_self`, and similar higher-order patterns run user code in a closure. Without a purity oracle, all member and shape facts collapse on every block.
- Closures can mutate locals from another scope (`-> { x = 1 }.call`). The fact-stability rule for closure-captured locals must mention this case explicitly.
- "Frozen, literal, freshly allocated, or otherwise proven-stable" is a category, not a list. A practical first cut needs concrete proof obligations.

Working response:

- Facts should be targeted, not global. Rigor distinguishes local binding facts, captured-local facts, object-content facts, global-storage facts, dynamic-origin facts, and relational facts.
- Unknown calls may invalidate heap facts for escaped targets, such as object shapes, hash entries, instance variables, constants, globals, and class variables. They should not invalidate every local binding fact in scope.
- Local binding facts survive ordinary method calls until assignment to that local. A call can mutate the object referenced by `x`, but it cannot rebind `x` unless `x` is captured by a closure that writes it.
- Closure writes are explicit effects. If a block, proc, or lambda writes an outer local, Rigor records a captured-local write. Immediate known invocation applies that write at the call edge; escaping or deferred closures make writable captured-local facts unstable after the escape point.
- Higher-order calls need call-timing effects rather than a blanket "yield invalidates everything" rule. Initial categories are no block invocation, immediate non-escaping invocation with known count, immediate non-escaping invocation with unknown count, deferred or escaping block storage, and unknown block behavior.
- Core methods such as `tap`, `then`, `yield_self`, and `each_with_object` should eventually have summaries for block timing, return behavior, and receiver or argument mutation. Before those summaries exist, Rigor may weaken object-content facts touched by the call but should preserve unrelated local binding facts.
- The first proof obligations for stable facts are concrete: a non-reassigned local not writable by an escaping closure; immutable singleton or immediate values; values proven frozen for the relevant operation; fresh non-escaping allocations; and RBS, `RBS::Extended`, or plugin effects that declare read-only, pure, or targeted mutation behavior.

This makes invalidation precise enough for idiomatic blocks without pretending arbitrary Ruby code is pure. Remaining design work is the exact effect payload syntax and the standard-library summary set.

### Capability-Role Inference Has No Tractability Story

Inferring "the minimum structural requirement of a method body" is a centerpiece of the design, but the cost and matching strategy are open:

- The cost of computing capability requirements per method, especially for recursive methods or methods that delegate via `send`, is not analyzed.
- Matching an inferred shape against named interfaces is at least quadratic and can be expensive when many candidates exist. The selection rule (most-specific wins, first-match, user-configurable) is undefined.
- Combining capability-role inference with generics (`def reset: [S < _RewindableStream] (S stream) -> S`) requires bound checking against an inferred shape, but the algorithm choice is open.

Working response:

- Rigor should infer cached per-method requirement summaries, not recompute a "minimum" role expression at every call site. A summary records required member names, visibility, arity, keyword and block requirements, return-use constraints, mutation requirements, and provenance for each parameter and receiver.
- The summary is an anonymous object-shape requirement by default. Naming it as an interface is an export and diagnostic convenience, not the core inference result.
- Requirement inference is local and monotone. Direct calls use existing signatures or cached summaries. Recursive or mutually recursive summaries use an unknown or widening placeholder and iterate only to a small fixed-point budget.
- Dynamic dispatch through `send`, `public_send`, unknown `method_missing`, or unconstrained delegation stops precise role extraction unless a signature or plugin supplies the target. Rigor should record a dynamic requirement instead of trying to infer every possible method.
- Named-interface matching should use an index keyed by member name and visibility. Rigor compares only cheap-filtered candidates. If the candidate set is too large, it keeps the anonymous shape and suppresses the generalization hint rather than scanning the world.
- Candidate selection is deterministic: exact member-signature match first, configured standard-library roles before coincidental user interfaces, fewer extra required members next, then stable lexical name order. Meaningful ambiguity means no named suggestion.
- Intersections of roles are allowed but bounded. The first implementation can use exact single-interface matches, explicit standard role bundles, or a small greedy intersection under a strict candidate limit. It should not solve an unbounded set-cover problem.
- Generic preservation is handled by identity tracking, not by the role matcher. If a method returns the same parameter object it received, Rigor may infer `[S < _Role] (S value) -> S`. If the body may replace the value or return a delegated object, Rigor uses the ordinary inferred return type.

This makes capability roles a bounded summary-and-index feature rather than a global structural search. Remaining design work is choosing the cache keys, budgets, and first standard role bundle.

### Hard Recursive Inference Needs a User Boundary Workflow

Inference-first analysis still needs an escape hatch for code where Ruby's dynamic dispatch makes the search space unhelpfully large:

- Operators such as `<=` and `-` are ordinary methods implemented by many classes. Without a known receiver domain, enumerating every compatible class is the wrong problem.
- Recursive methods can cause return inference to repeatedly re-enter the same body before a useful type boundary exists.
- If Rigor widens silently, users lose trust in the result; if it keeps searching, CLI latency becomes unpredictable.

Working response:

- Rigor should have explicit inference budgets for recursion depth, call-graph expansion, overload candidates, operator ambiguity, union size, and structural requirement growth.
- When a budget is exceeded, Rigor produces an incomplete-inference result with a reason. It should not fabricate a precise type.
- Accepted signature contracts are inference cutoffs. Inline `#: Integer`, full `# @rbs` method types, generated stubs, and external `.rbs` declarations all let callers stop at the boundary while the implementation remains checked against the contract.
- Non-interactive CLI output should explain the cutoff and suggest compatible boundary locations.
- Interactive CLI mode may ask the user to provide a simple boundary type and, with confirmation, insert or generate the chosen type source. Return-only cutoffs should prefer short rbs-inline forms when they are enough; parameter-heavy operator ambiguity may require a full method signature or `.rbs` entry.
- This workflow is compatible with the "no Rigor-specific inline type syntax" goal because it uses existing RBS, rbs-inline, and Steep-compatible annotations rather than a new Rigor DSL.

The remaining design work is the exact prompt UX, the persistence target selection, and how much candidate type information Rigor should propose automatically.

### `RBS::Extended` Annotation Grammar Lacks Versioning and Conflict Semantics

Two aspects of the grammar are user-facing on disk and need an early decision:

- Versioning: a future incompatible directive change cannot reuse the `rigor:` prefix without breaking existing files. A version-prefix scheme such as `rigor:v1:...`, or an out-of-band version declaration in `.rigor.yml`, must be picked.
- Conflict resolution: the spec says conflicts must be reported, but the precedence model (first wins, last wins, severity-based, always error) is not pinned down. Without a single rule, plugin authors cannot predict outcomes.

### Hash Erasure Does Not Specify How `Hash[K, V]` Is Reconstructed

`{ a: 1, b: "str" }` could erase to `Hash[Symbol, Integer | String]`, `Hash[:a | :b, Integer | String]`, or some intersection of those. The choice changes downstream precision and RBS readability:

- Should keys widen to their nominal class or stay as a literal union when finite?
- Should values be unioned, widened to a least common nominal supertype, or both forms be available behind a flag?
- For open shapes, what is the value type when extra keys are accepted but unknown? `untyped`, the current shape's value union, or the user-declared extra-key bound?

### Difference and Complement Notation Needs a Domain-Aware Display Contract

`~T` is "complement of `T` within the current known domain", but display is the only place users see it:

- Diagnostics that print `~"foo"` without the surrounding domain are easy to misread as global complements. A combined display such as `String - "foo"` or `~"foo" : String` would be clearer.
- Nested differences (`(String - "") - "foo"`) and intersections with negative members (`A & ~B & ~C`) need a normalized form so equivalent diagnostics render identically across code paths.
- The rule for when `~T` should be rendered as `T - U` and vice versa is implicit. A single canonical rendering keeps user mental models stable.

### Visibility, Accessor Inference, and Method-Shape Capture Are Under-Specified

The shape model relies on visibility and reader/writer roles, but Ruby's surface is more flexible than the current text:

- `attr_writer :x` without a matching reader, or an overridden accessor that mutates additional state, is not covered by the read-only/read-write/write-only categorization.
- `private` and `protected` boundaries change the set of "visible" members for `respond_to?` and external sends. Shape entries should distinguish all three visibilities, not collapse into public/non-public.
- `respond_to?(:foo, true)` and `respond_to?(:foo)` produce different facts; the difference must propagate into shape entries to avoid silently widening visibility.

### Positioning Relative to Existing Ruby Type Tooling Needed Clarification

Sorbet, Steep, RBS-based linters, and `rbs-inline` occupy adjacent design space. ADR-0 mentions them, but ADR-1 does not articulate Rigor's compatibility and competition story:

- How Rigor consumes the same RBS that Steep consumes, and where divergence is acceptable.
- Whether Rigor intends to read Steep- or Sorbet-style ignore markers, or to define its own.
- How `RBS::Extended` annotations are expected to interact with existing tools that may also place `%a{...}` annotations on the same nodes.

Working response:

- RBS and rbs-inline are first-order compatibility targets for type syntax. Rigor aims to accept them as type sources without warning or rewriting.
- Steep 2.0 behavior is the secondary norm for inline annotation interpretation and for precedence between separate-file RBS and inline annotations.
- `# rbs_inline: enabled` and `# rbs_inline: disabled` do not gate Rigor analysis. Rigor reads compatible annotations whenever present.
- TypeScript, PHPStan, and Python typing remain comparison material for missing concepts and analyzer features, not compatibility targets.
- Ignore-marker compatibility remains open. Rigor should decide separately whether it reads Steep or Sorbet suppression comments, defines its own configuration-only suppression, or supports more than one form.

### Behavior on Annotation-Poor Code Bases Is Not Described

Rails-shaped applications are dominated by `untyped` until plugins fill in shapes. The value of the spec depends heavily on plugins, but ADR-1 does not state the minimum useful behavior when plugins are absent:

- Which narrowing operations remain useful with widespread `untyped` (likely `nil?`, truthiness, `is_a?`, equality against literals)?
- What is the diagnostic policy for "method on `untyped`": always allowed, allowed but reportable in strict mode, or progressively configurable?
- How are common dynamic patterns (ActiveRecord finder chains, Sidekiq workers, RSpec doubles) handled before plugins ship?

Working response:

- Even without plugins, stable Ruby guards should narrow `Dynamic[top]` into `Dynamic[T]` where the static facet is justified by Ruby semantics or existing signatures. Useful first checks include nilability, truthiness, `is_a?`, `kind_of?`, `instance_of?`, literal equality for trusted built-in domains, and `respond_to?` member-existence facts.
- Method calls on raw `Dynamic[top]` remain allowed by default so gradual code can be analyzed incrementally, but they are traceable and reportable in strict modes.
- Plugin-specific framework behavior is still deferred, but the pre-plugin analyzer should explain whether a result came from a missing signature, an explicit `untyped`, or an analyzer/plugin limit.

### Numeric Refinements Stop at `Integer`

The scalar refinement table lists positive/negative/non-zero integer refinements but does not address adjacent cases:

- `Float` (with `NaN`, `+0.0`/`-0.0`, infinities), where ordinary equality and ordering are partial.
- `Rational` and `Complex`, which RBS recognizes as core numeric classes.
- Promotion rules across `Integer | Float`, `Integer | Rational`, and similar unions, which Ruby resolves at runtime through `coerce`. Rigor must decide whether refinements transit `coerce` boundaries or stop at the nominal level.

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
- When should diagnostics display internal `Dynamic[...]` provenance versus only the narrowed static facet?
- How aggressively should literal unions widen for performance and diagnostic readability?
- Which Python `TypedDict`-inspired shape facts, such as read-only keys and open or closed extra-key policies, should ship first?
- Should Rigor model finality and read-only member facts separately from value types in the first signature metadata grammar?
- What minimal method-shape representation is needed for structural interface assignability in the first implementation?
- Should Rigor add an explicit `RBS::Extended` conformance annotation, or rely on ordinary assignments and calls to trigger interface conformance checks?
- Should generated RBS preserve `RBS::Extended` annotations that explain erased refinements when users request an annotated export?
- Which strict-dynamic and strict-static diagnostic identifiers should be attached to dynamic-to-precise crossings, unchecked generic leaks, and method calls whose proof depends on `Dynamic[T]`?
- Which dynamic-origin sources should be classified as explicit user intent, missing signatures, analyzer limits, or plugin-declared dynamic behavior?
- What plugin API is needed for framework-specific object shapes and dynamic method resolution?
- What is the smallest fact-stability model that makes shape and hash-key narrowing useful without becoming unsound around mutation?
- What exact `RBS::Extended` or plugin payload should declare custom equality effects?
- How should diagnostics distinguish a proven type fact from a relational or dynamic-origin fact?
- Which standard Ruby capability roles, such as readable stream, writable stream, rewindable stream, closable, enumerable, callable, and file-descriptor-backed, should Rigor ship as named interfaces?
- Should Rigor emit a signature-generalization hint when a public nominal annotation such as `IO` is stricter than the method body's inferred capability role?
- What cache keys and invalidation rules should capability requirement summaries use across edits and dependency signature changes?
- What candidate and intersection budgets should named-interface matching use before falling back to anonymous shapes?
- What inference budgets should trigger incomplete-inference diagnostics, and which of them should be configurable?
- How should interactive CLI prompts choose between inline `#:`, full `# @rbs`, generated stubs, and external `.rbs` persistence targets?
- Which generic variance cases require special handling for `Dynamic[T]` slots in the first implementation?
- Should `Float` equality narrowing ever be opt-in, and what proof should be required to exclude `NaN` and signed-zero pitfalls?
- What exact effect payload should encode block call timing, closure escape, receiver or argument mutation, and read-only/pure behavior?
- Which Ruby core and stdlib methods should receive built-in call-timing and mutation summaries first?
- What is the canonical algorithm for erasing arbitrary hash shapes to `Hash[K, V]`, including the choice between literal-union and nominal keys?
- Which existing suppression or ignore-marker conventions, if any, should Rigor support beyond ordinary RBS/rbs-inline/Steep type annotations?
- What is the minimum useful narrowing surface in heavily `Dynamic[top]` code before plugins ship?
- Should `RBS::Extended` annotation directives carry an explicit version prefix (`rigor:v1:...`) or be governed by a project-level version declaration?
- What is the deterministic precedence rule when multiple `RBS::Extended` annotations on the same node disagree (first wins, last wins, severity-based, always-error)?
- What exact display budget and wording should diagnostics use when negative-fact exclusions are omitted?
- How should `Float`, `Rational`, `Complex`, and `coerce`-mediated promotions participate in scalar refinements?
- Should visibility (`public`, `protected`, `private`) be a first-class facet of shape entries, or modeled separately as a side fact?

## Resulting Specification

The current draft specification is maintained in `docs/types.md`.
