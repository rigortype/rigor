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

## Goals

- Preserve RBS compatibility for input and output.
- Keep application code free of Rigor-specific inline type syntax.
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

The documentation should write the gradual-consistency relation as `consistent(A, B)`, not `A ~ B`, because `~T` is reserved for negative or complement types.

### PHPStan Compared with RBS

The PHPStan documentation in `references/phpstan/website/src/writing-php-code/` is useful because it describes the feature surface of a mature analyzer for a dynamic language. PHPStan is not a compatibility target, and PHPDoc syntax should not become Rigor syntax, but its features are a strong checklist for what users eventually expect from precise static analysis.

| Area | PHPStan | RBS and Rigor implication |
| --- | --- | --- |
| Annotation boundary | PHPStan combines PHP native typehints with PHPDoc tags on functions, methods, properties, classes, local variables, and vendor stub files. PHPDocs augment native hints when PHP syntax is too weak. | Rigor keeps Ruby application code annotation-free. RBS is the boundary format, and `RBS::Extended` annotations or external signatures are the place for extra facts. Inline Ruby comments should not become the main correction mechanism. |
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
| Signature boundary | TypeScript normally mixes implementation code and type annotations in `.ts` files, and also supports declaration-only `.d.ts` files for JavaScript libraries. Type annotations are erased from emitted JavaScript. | Rigor keeps Ruby application code annotation-free. RBS, not `.d.ts`, is the boundary format, and Rigor-only internal precision must erase conservatively to ordinary RBS. |
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
| Signature boundary | Python allows inline annotations and separate stubs. | Rigor keeps Ruby application code annotation-free and uses RBS as the external signature format. |
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

For example, after `value == "foo"`, the true branch can narrow `value` to `"foo"` and the false branch can carry the negative fact displayed as `~"foo"`. The exact operator syntax is provisional, but the semantic capability is required.

Python's `TypeGuard` and `TypeIs` distinction supports the same design direction: predicate behavior is a flow effect. A true-only predicate is enough for `TypeGuard`-like behavior; paired true and false facts, or a false fact expressed as `T & ~U`, provide `TypeIs`-like behavior.

CFA must be fine-grained enough to update scope inside a condition expression, not only after the whole condition has been evaluated. For `if foo == "foo" && foo == "bar"`, the right side of `&&` is analyzed in the scope produced by the left side's true edge. If the current domain makes `"foo" & "bar"` impossible, the whole true branch becomes `bot`. The same principle applies to `||`, `!`, `unless`, `elsif`, `case`, and pattern matching.

Ruby equality is method dispatch, so equality narrowing cannot be a purely syntactic rule. `equal?`, `nil?`, boolean checks, trusted built-in literal domains, and predicate effects declared by RBS or plugins can produce type facts. Unknown `==` implementations should produce a weaker relational fact unless Rigor has method information that justifies a value-type refinement.

### `void` Is a Return-Position Marker

RBS treats `void` as top-like but context-limited. Rigor should model `void` internally as a result marker that says the return value should not be used.

This enables diagnostics such as assigning the result of a `void` method call. In statement context, `void` is fine. In value context, Rigor reports a diagnostic and recovers with `top`.

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
- Gradual facts need provenance. Narrowing an `untyped` value can be useful inside a branch, but diagnostics and joins should still know that the value crossed an unchecked boundary.
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
- How should Rigor display dynamic-origin narrowed types such as `untyped & ~"foo"`?
- How aggressively should literal unions widen for performance and diagnostic readability?
- Which Python `TypedDict`-inspired shape facts, such as read-only keys and open or closed extra-key policies, should ship first?
- Should Rigor model finality and read-only member facts separately from value types in the first signature metadata grammar?
- What minimal method-shape representation is needed for structural interface assignability in the first implementation?
- Should Rigor add an explicit `RBS::Extended` conformance annotation, or rely on ordinary assignments and calls to trigger interface conformance checks?
- Should generated RBS preserve `RBS::Extended` annotations that explain erased refinements when users request an annotated export?
- Should `untyped` operations produce optional informational diagnostics in strict mode?
- What plugin API is needed for framework-specific object shapes and dynamic method resolution?
- What is the smallest fact-stability model that makes shape and hash-key narrowing useful without becoming unsound around mutation?
- Which equality methods are trusted by default for literal narrowing, and how should custom equality effects be declared?
- How should diagnostics distinguish a proven type fact from a relational or dynamic-origin fact?
- Which standard Ruby capability roles, such as readable stream, writable stream, rewindable stream, closable, enumerable, callable, and file-descriptor-backed, should Rigor ship as named interfaces?
- Should Rigor emit a signature-generalization hint when a public nominal annotation such as `IO` is stricter than the method body's inferred capability role?

## Resulting Specification

The current draft specification is maintained in `docs/types.md`.
