# Rigor Type Specification

## Status

Draft. This document defines the intended type model for Rigor. It is a product specification, not an implementation status report.

## Core Principle

Rigor's type language is a strict superset of RBS.

Every RBS type must have a lossless representation in Rigor. Every Rigor-inferred type must also have an RBS erasure so Rigor can export an approximation as ordinary RBS. Erasure may lose precision, but it must not invent a narrower type than Rigor proved.

Rigor uses RBS as the interoperability surface and a richer internal type model for inference, control-flow analysis, and diagnostics.

Rigor should aggressively learn from PHPStan, TypeScript, and Python's typing specification. In particular, it should support precise literal types, finite unions, flow-sensitive narrowing, negative facts, refined scalar domains, object and hash shapes, gradual typing discipline, and type operators that make practical static analysis expressive without requiring Rigor-specific inline annotations in Ruby application code.

The borrowed ideas must remain Ruby-shaped:

- RBS classes and modules stay nominal.
- RBS interfaces and Rigor object shapes provide structural duck typing.
- Ruby truthiness means only `false` and `nil` are falsey.
- Ruby equality, case equality, `respond_to?`, `method_missing`, singleton methods, and module inclusion are runtime behaviors that must be modeled through Ruby semantics, RBS signatures, or plugin facts rather than copied from another language.
- Application Ruby code stays free of Rigor-only annotation syntax. Existing RBS-, rbs-inline-, and Steep-compatible annotations are accepted as type sources, not treated as Rigor-specific syntax.

## Design Priorities

This document is organized around the ideal type model, not the first implementation milestone. The priorities are:

1. Preserve every RBS type and every RBS export rule.
2. Keep Ruby runtime behavior as the source of truth for narrowing and member availability.
3. Make gradual loss of precision explicit through `untyped` provenance.
4. Treat control-flow facts as scope transitions at expression edges, not only as block-level branch labels.
5. Support Ruby duck typing through structural interfaces and object shapes without making all class compatibility structural.
6. Let plugins and `RBS::Extended` contribute facts, effects, and dynamic reflection while the analyzer keeps ownership of scope application and normalization.

## Relations

Rigor distinguishes two relations:

- Subtyping, written `A <: B`, describes value-set inclusion.
- Gradual consistency, written `consistent(A, B)`, describes compatibility when `untyped` participates.

This distinction is required because `untyped` is not simply `top`. `top` is the greatest static value type. `untyped` is the dynamic type: it suppresses precise static checking at a boundary, while preserving the fact that precision was lost.

The specification avoids using `~` as the gradual-consistency relation because `~T` is reserved as the candidate notation for negative or complement types.

## Value Lattice

The ordinary value lattice has:

- `top` as the greatest type for all Ruby values.
- `bot` as the empty type for unreachable or impossible values.
- Nominal, structural, literal, union, intersection, tuple, record, proc, and refined types between them.

Important identities:

```text
bot <: T
T <: top
T | bot = T
T & top = T
T | top = top
T & bot = bot
```

`untyped` is deliberately outside this pure lattice. Internally, Rigor represents values that crossed a dynamic boundary as `Dynamic[T]`, where `T` is the currently known static facet. Raw RBS `untyped` is `Dynamic[top]`.

Dynamic-origin joins preserve the marker instead of pretending the value is purely static:

```text
Dynamic[A] | Dynamic[B] = Dynamic[A | B]
T | Dynamic[U] = Dynamic[T | U]
```

When `U` is `top`, the result may be displayed as `untyped`, but the internal form still records dynamic-origin provenance. In flow refinements, a guard may refine an `untyped` value inside the guarded region, but the value keeps the `Dynamic[...]` marker for diagnostics and later joins.

## Control-Flow Analysis

Rigor performs flow-sensitive type analysis in the style of PHPStan, TypeScript, and Python type checkers.

The type environment is refined by guards, returns, raises, loop exits, pattern matches, equality comparisons, predicate methods, and plugin-provided facts. Each expression is analyzed with an input `Scope` and produces output scopes for the relevant edges:

- normal completion;
- truthy condition result;
- falsey condition result;
- exceptional or non-returning exit;
- unreachable result, represented by `bot`.

These scopes carry both positive facts and negative facts. Joins merge those facts conservatively.

This is finer than assigning one scope to the whole `if` condition. Short-circuiting expressions update the scope between operands:

- `a && b` analyzes `b` in the truthy scope produced by `a`.
- `a || b` analyzes `b` in the falsey scope produced by `a`.
- `!a` swaps truthy and falsey scopes.
- `unless a` uses the same condition facts as `if a`, then swaps branch destinations.
- `case`, pattern matching, and chained `elsif` expressions pass negative facts from earlier arms to later arms.

```ruby
def contradictory(foo)
  # Assume `foo` has a finite literal domain and ordinary String equality.
  if foo == "foo" && foo == "bar"
    p foo # Rigor type: bot; this edge is unreachable.
  end
end
```

The right side of `&&` is analyzed after the left side's true fact has refined `foo` to `"foo"`. The true edge of `foo == "bar"` then intersects `"foo"` with `"bar"`, normalizes to `bot`, and marks the body as unreachable. Rigor should be able to report the contradiction at the comparison or at the unreachable body, depending on diagnostic policy.

For `||`, the same precision applies in the opposite direction:

```ruby
def impossible_after_or(foo)
  # Assume `foo` has a finite literal domain and ordinary String equality.
  if foo == "foo" || foo == "bar"
    p foo # Rigor type includes only the "foo" and "bar" alternatives.
  else
    p foo # Rigor type excludes both "foo" and "bar".
  end
end
```

Supported narrowing sources should include:

- Trusted equality and inequality checks against literals and singleton values.
- `nil?` checks and nil comparisons.
- Truthiness checks, where `nil` and `false` narrow the false branch.
- `is_a?`, `kind_of?`, `instance_of?`, and class/module comparisons.
- `respond_to?` checks when the method name is statically known.
- Pattern matching and case analysis.
- Predicate methods registered by Rigor plugins.
- Assertions and guards described in `RBS::Extended` annotations.

Negative facts are first-class scope facts. Rigor should preserve facts such as "not nil", "not false", "not this literal", and "does not have this nominal class" when they improve later diagnostics.

A negative fact is domain-relative: it removes values from the value's already-known positive domain. It must not introduce a new positive domain from the right-hand side of a comparison. For example:

```text
v: String
v != "foo" => v: String - "foo"

v: "foo" | "bar"
v != "foo" => v: "bar"

v: String | Symbol
v != "foo" => v: (String - "foo") | Symbol

v: untyped
v != "foo" => v: Dynamic[top] with a dynamic-origin relational fact `v != "foo"`
```

The final case is intentionally not `Dynamic[String - "foo"]`. A comparison with a string literal does not prove that an unchecked Ruby value is a `String`, and Ruby equality is method dispatch. Rigor may keep the negative relation for later diagnostics or contradictions, but it should not turn a dynamic or unknown value into a narrower positive type unless an independent guard proves that domain.

When the current domain is finite, negative facts should normalize precisely. When the current domain is large or unknown, negative facts should be retained with a budget rather than expanded into unbounded difference chains. If the budget is exceeded, Rigor should widen the display and retain provenance that additional negative facts were omitted.

Python's `TypeGuard` and `TypeIs` are useful reference points for predicate effects. A predicate that refines only the true branch is `TypeGuard`-like. A predicate that refines both true and false branches is `TypeIs`-like; internally, the false branch should be modeled as intersection with a complement, such as `A & ~R`, or as an equivalent difference type.

### Equality and Ruby Runtime Semantics

Ruby equality is method dispatch. A syntactic comparison such as `foo == "foo"` calls `foo.==("foo")`, and arbitrary classes may override that method. Rigor must therefore distinguish:

- identity facts, such as `x.equal?(obj)`, which can prove singleton identity;
- nil and boolean checks, which are stable Ruby value tests;
- equality facts for known built-in domains whose dispatch target is stable, such as finite `String`, `Symbol`, `Integer`, `true`, `false`, and `nil` alternatives already present in the receiver domain;
- comparison facts contributed by RBS or plugins for trusted predicate and equality methods;
- unknown equality methods, which should produce at most a relational fact unless the analyzer has enough method information to refine the value type;
- floating-point comparisons, which should not produce literal narrowing by default because `NaN`, signed zero, infinities, and coercion make exhaustiveness and equality reasoning easy to misstate.

Equality narrowing must not introduce a positive domain from the compared value alone. If `foo` is raw `untyped`, `foo == "foo"` keeps `foo` as `Dynamic[top]` with a dynamic-origin relational fact unless Rigor also knows that the dispatched equality method has a trusted narrowing effect. If `foo` is already known to be `"foo" | "bar"`, the same comparison may narrow the true branch to `"foo"` and the false branch to `"bar"`.

Rigor should classify equality facts by trust level:

- identity facts from `equal?` are value facts as long as the observed reference itself remains stable;
- built-in literal-domain equality can narrow only inside an already-compatible receiver domain with a known core dispatch target;
- `Module`, `Class`, `Range`, `Regexp`, and `===`-based case behavior need explicit per-kind rules or plugin facts rather than being treated as general equality;
- user-defined `==`, `eql?`, `===`, and coercion-sensitive comparisons remain relational facts until RBS metadata or a plugin declares true-edge and false-edge effects.

This rule keeps TypeScript- and PHPStan-style equality narrowing useful without pretending that Ruby `==` is a built-in identity operator.

### Fact Stability and Mutation

Flow facts are valid only while the analyzer can trust the path they describe. Rigor should invalidate or weaken facts when Ruby behavior can mutate, replace, or escape the observed target.

Facts should carry a target and a stability reason. The first implementation should distinguish at least:

- local binding facts, such as "local `x` currently refers to a non-nil value";
- captured local facts, where a block, proc, or lambda may write the local from another lexical scope;
- object-content facts, such as hash keys, instance variables, singleton methods, and object-shape members;
- global storage facts, such as constants, class variables, and globals;
- dynamic-origin and relational facts, which may survive local calls but still need target invalidation.

Local binding facts are stable across ordinary method calls until assignment to that local. A call can mutate the object referenced by the local, but it cannot rebind the local variable itself unless the local is captured by a closure that writes it. Therefore:

- `x.is_a?(String)` remains a local binding fact after an unknown call that cannot write `x`;
- `x[:key]` or `x.foo` shape facts may be weakened by a call that can mutate `x` or escape it;
- facts about instance variables, class variables, globals, and constants are heap or global-storage facts and are invalidated more aggressively.

Closure-captured locals need explicit handling. When a block, proc, or lambda writes an outer local, Rigor should record a captured-local write effect. If the closure is invoked immediately and its body is available, Rigor applies the write at the call edge. If the closure escapes or may be invoked later, facts about locals it can write become unstable after the escape point and before any unknown invocation of that closure.

Block and higher-order method calls should be modeled through call-timing and mutation effects instead of a blanket "yield invalidates everything" rule. Useful first categories are:

- no block invocation;
- immediate non-escaping invocation, once or a known bounded number of times;
- immediate non-escaping invocation, unknown number of times;
- deferred or escaping block storage;
- unknown block behavior.

Known Ruby methods such as `tap`, `then`, `yield_self`, and `each_with_object` should eventually receive summaries for block timing, return behavior, and receiver or argument mutation. Without such a summary, Rigor may be conservative for object-content facts, but it should still preserve unrelated local binding facts.

The first implementation can use these proof obligations for stronger fact retention:

- a local binding has not been assigned and is not writable by an escaping closure;
- the value is an immutable singleton or immediate value, such as `nil`, `true`, `false`, a symbol, or an integer;
- the value is proven frozen for the relevant operation;
- the value is freshly allocated, has not escaped, and has not been passed to a call that may mutate or store it;
- a RBS, `RBS::Extended`, or plugin effect declares that the call is read-only, pure for the relevant target, or mutates only specific receivers or arguments.

Unknown calls are still conservative for heap facts. They may invalidate object-shape, hash-entry, instance-variable, constant-object, and global-storage facts for any target that may have escaped to the call. They should not invalidate every local binding fact in the current scope.

A plugin may return explicit mutation, escape, call-timing, purity, or invalidation effects rather than mutating `Scope` directly.

This is especially important for structural object shapes and hash shapes. A guard can prove that a key or method is present at one program point, but ordinary Ruby mutation can remove or redefine it later unless Rigor has a stability fact.

## RBS-Compatible Types

Rigor supports every type form documented by RBS syntax.

| RBS form | Rigor interpretation | RBS erasure |
| --- | --- | --- |
| `C`, `C[A]` | Nominal instance type | Same |
| `_I`, `_I[A]` | Interface type | Same |
| `alias`, `alias[A]` | Alias reference, expanded on demand | Same or expanded alias |
| `singleton(C)` | Singleton class object type | Same |
| string, symbol, integer, `true`, `false` | Literal singleton type | Same |
| `A | B` | Union type | Same after erased operands |
| `A & B` | Intersection type | Same after erased operands |
| `T?` | `T | nil` | Optional syntax when valid, otherwise union |
| `{ key: T }` | Hash record with known keys | Same |
| `[A, B]` | Array tuple with fixed arity | Same |
| type variable | Scoped type variable with bounds and variance | Same |
| `self` | Open-recursive receiver type in self-context | Same when the RBS context allows it |
| `instance` | Current class instance type in classish-context | Same when the RBS context allows it |
| `class` | Current class singleton type in classish-context | Same when the RBS context allows it |
| `bool` | Alias for `true | false` | `bool` |
| `nil` | The singleton `nil` value | `nil` |
| `untyped` | Dynamic type | `untyped` |
| `top` | Greatest static value type | `top` |
| `bot` | Empty type | `bot` |
| `void` | Return-position no-use result marker | `void` where valid, otherwise `top` with a diagnostic |
| proc type | Callable object type | Same after erased operands |

Rigor preserves RBS contextual limitations for export. For example, `self`, `instance`, `class`, and `void` must only be emitted where RBS accepts them. If an internal type contains one of these markers in an invalid RBS context, the erasure pass must rewrite it to the nearest valid conservative type and report the loss of precision.

## Structural Interfaces and Object Shapes

Rigor models Python `Protocol`-style structural subtyping through RBS interfaces and internal object shapes.

An RBS interface type, such as `_Closable`, is a named structural contract. An internal object shape is an anonymous structural type inferred from local definitions, singleton methods, module members, included modules, plugin facts, or control-flow guards. A nominal type or object shape is assignable to an interface when Rigor can prove that it provides all required members with compatible types.

This is the structural part of Ruby duck typing. Rigor should not make ordinary class-to-class compatibility TypeScript-style structural by default. Class and module names remain nominal because RBS uses those names as declarations about Ruby constants and because Ruby runtime checks such as `is_a?` and `kind_of?` depend on class/module relationships. Structural typing lives at these boundaries:

- assigning or passing a value where an RBS interface is expected;
- checking whether an inferred object shape satisfies an interface;
- checking a direct method send against a known shape;
- using plugin-provided dynamic reflection to add members to a shape or nominal type.

This gives Rigor a pseudo-protocol model without adding Python syntax:

```rbs
interface _Closable
  def close: () -> void
end
```

```ruby
class Resource
  def close
    @handle.close
  end
end

def close_all(items)
  items.each(&:close)
end
# If Rigor knows `items` is `Array[_Closable]`, `Resource` can satisfy `_Closable`
# structurally. No Ruby inheritance or runtime marker is required.
```

Structural assignability rules:

- A concrete nominal type is assignable to an interface if its instance method shape satisfies every interface member.
- An object shape is assignable to an interface if the shape contains every required member with an assignable signature.
- One interface is assignable to another when the source interface provides all members required by the target interface.
- Interface unions behave like ordinary unions.
- Interface intersections require all members from all intersected interfaces.
- Callable object shapes may satisfy proc-like or interface-like call contracts through a known `call` method when the signature is compatible.
- Singleton class and module object shapes may satisfy interfaces through singleton methods and module-level members, but this should be implemented after instance-side structural checks.

Member compatibility follows method type compatibility, not just name existence. Rigor must compare visibility, arity, positional parameters, keyword parameters, blocks, overloads, return types, and receiver constraints through the ordinary method-assignability rules once those exist.

Reader and writer capabilities matter:

- A read-only member is represented by a reader method and is covariant in its return type.
- A write-only member is represented by a writer method and is contravariant in its accepted value type.
- A read-write member, such as an `attr_accessor` pair, combines reader and writer requirements and is effectively invariant in the value type.

This mirrors Python's protocol-attribute lesson without importing Python attributes directly. In Ruby, attributes are methods, so Rigor should reason about the reader and writer methods that actually exist.

Accessor syntax is only one source of those method facts:

- `attr_reader :x` contributes a public reader method `x` unless the surrounding Ruby visibility state changes it.
- `attr_writer :x` contributes a writer method `x=` without implying a reader.
- `attr_accessor :x` contributes both methods, but Rigor should still model them as two method entries.
- A manually defined or overridden `x` or `x=` method replaces or refines the method fact according to ordinary Ruby method lookup and source order.
- Reader and writer capability does not imply purity. A reader can mutate state, and a writer can return any Ruby value unless a signature or implementation proves otherwise.

Visibility is a first-class facet of every method-shape entry. Rigor should track at least `public`, `protected`, and `private`, plus the call context in which a member can be used:

- external explicit receiver sends require a public method;
- private methods may be called only in private-call contexts, not as ordinary explicit receiver sends;
- protected methods have Ruby's protected receiver restriction and should not satisfy public structural interface requirements by default;
- public structural interfaces require public members unless the interface or internal check explicitly asks for another visibility.

`respond_to?` checks can refine an object to an existence-only shape, for example "has public method `close`". That fact is useful for diagnostics and guarded sends, but it does not prove full signature compatibility with an interface unless Rigor also knows the method type. The optional `include_private` argument must affect the visibility fact:

- `obj.respond_to?(:foo)` records a public existence fact for `foo` on the true branch.
- `obj.respond_to?(:foo, false)` is the same as the default when the second argument is statically false.
- `obj.respond_to?(:foo, true)` records an existence fact whose visibility may be public, protected, or private. It does not by itself prove that `obj.foo` is legal with an explicit receiver.
- If the second argument is not statically known, Rigor should record a weaker maybe-private visibility fact.

If the method exists only through `respond_to_missing?` or `method_missing`, the fact should be recorded with dynamic provenance and an unknown or plugin-provided signature so diagnostics can explain why the call was accepted.

Object-shape entries should carry enough metadata to avoid confusing Ruby's dynamic surface with a static protocol proof:

- member kind, such as method, reader, writer, constant, or index operation;
- call signature or readable/writable value type;
- visibility and valid call context;
- source and provenance, such as source definition, RBS, plugin, `respond_to?`, or `method_missing`;
- stability and mutation information;
- certainty, such as yes, maybe, or no.

### Capability Roles and IO-Like Objects

Rigor should model common Ruby "IO-like" relationships as capability roles, not as global class equivalence.

`IO` and `StringIO` are the motivating example. A `StringIO` is often a good test double for an `IO` object when the code only reads, writes, rewinds, or closes a stream. It is not a subclass of `IO`, and it does not have the same complete method set. Treating `StringIO` as a subtype of `IO` would erase real runtime differences. Requiring every implementation to write `IO | StringIO` would also miss the point of Ruby duck typing.

The better model is:

- `IO` remains a nominal type for APIs that require an actual `IO` object or file-descriptor-backed behavior.
- `StringIO` remains a separate nominal type.
- Both classes may satisfy smaller structural interfaces such as readable, writable, seekable, flushable, or closable stream roles.
- A method that only calls stream capability methods should be inferred as requiring the corresponding object shape or named interface, not the whole nominal `IO` type.
- A method that calls `IO`-specific members such as file-descriptor operations should require `IO` or a more specific file-descriptor-backed role.

The role names and method signatures below are illustrative, not final standard-library signatures:

```rbs
interface _ReadableStream
  def read: (*untyped) -> String?
end

interface _RewindableStream
  def rewind: () -> untyped
end
```

```ruby
def slurp(stream)
  stream.rewind
  stream.read
end
# Inferred requirement: _ReadableStream & _RewindableStream
# `IO` and `StringIO` can both satisfy that requirement if their signatures match.
```

This also avoids comparing total method sets. Structural subtyping asks whether a value provides the target role's required members; it does not require the source object and target object to expose the same complete surface.

Explicit declarations still matter. If an external RBS signature says a parameter is `IO`, Rigor should treat that as the public nominal contract. If the implementation and observed call sites only require `_ReadableStream`, Rigor may report that the declared type is narrower than the inferred capability requirement and suggest generalizing the signature to a structural interface. It should not silently rewrite a public `IO` contract into a structural one.

When a method returns the same stream object it receives, Rigor should preserve the concrete input type through generics rather than widening to a role:

```rbs
def reset: [S < _RewindableStream] (S stream) -> S
```

Unions remain useful when the implementation genuinely has class-specific behavior. If the method branches on `IO` versus `StringIO`, calls members unique to each class, or returns class-specific values, then `IO | StringIO` is a faithful type. For ordinary duck-typed stream consumption, capability roles are the preferred model.

RBS erasure should prefer a matching named interface when one exists. Anonymous object shapes that do not match a known interface erase to a conservative nominal base or `top`.

Capability-role inference must be bounded. Rigor should infer a per-method requirement summary for each parameter and receiver rather than repeatedly reanalyzing every call site. A summary contains the members that the method body actually requires, including method names, visibility, arity, keyword and block requirements, return-use constraints, mutation requirements, and provenance. It is an anonymous object-shape requirement until Rigor proves that a named interface or small intersection of named interfaces is a good representation.

The first implementation should keep the inference local and monotone:

- Analyze the method body once per relevant method version and cache the requirement summary.
- Use existing signatures or cached summaries for direct calls; do not recursively inline callees by default.
- For recursive methods or mutually recursive summaries, start with an unknown or widening placeholder and iterate only to a small fixed-point budget.
- Treat `send`, `public_send`, unknown `method_missing`, and dynamic delegation as dynamic requirements unless a plugin or signature provides a precise target.
- Widen large requirement shapes by keeping the member set needed for diagnostics and dropping low-value details such as long overload expansions when they exceed a budget.

Named-interface matching should be indexed, not a scan of every interface. Rigor can maintain an index from required member names and visibility to candidate interfaces. A candidate interface is compared only when it shares at least one required member and passes cheap arity or visibility filters. If the candidate set is too large, Rigor should keep the anonymous shape and avoid a generalization hint instead of performing an expensive global search.

When multiple named interfaces match, selection must be deterministic and conservative:

- Prefer an exact member-signature match.
- Prefer a configured standard-library role over an unrelated coincidental interface.
- Prefer fewer extra required members, then a stable lexical name order.
- If several candidates remain meaningfully ambiguous, keep the anonymous shape internally and do not emit a named-interface suggestion.

Intersections of named roles are useful, but Rigor should not solve an unbounded set-cover problem to find the mathematically smallest role expression. The first implementation may use only exact single-interface matches, explicit standard role bundles, or a small greedy intersection under a strict candidate limit. Otherwise it keeps the anonymous shape.

Generic preservation is a separate rule from role extraction. If a method returns the same parameter object it received, Rigor should prefer a type variable such as `[S < _RewindableStream] (S stream) -> S` when the body preserves object identity. It should not widen the return to `_RewindableStream` merely because the parameter requirement is structural. If the body may replace the value, branch between unrelated objects, or return a delegated object, Rigor should fall back to the ordinary inferred return type.

## Special Types

### `top`

`top` means any Ruby value. It is useful when a value exists but Rigor has no useful static structure for it.

Using a value of type `top` is still checked. A method call on `top` is accepted only when the method is known to be available for every possible inhabitant, or when a plugin supplies a stronger fact.

### `bot`

`bot` means no value can exist. It appears in unreachable branches, methods that always raise, exits, failed pattern matches, and contradictory refinements.

`bot` is useful for control-flow analysis because joining `bot` with a real branch leaves the real branch unchanged.

For return contracts, `bot` satisfies every result contract because no normal value is produced. A method body that always raises, exits, or loops forever is therefore compatible with a `void` return contract. The reverse is not true: a `void` result is not a proof of non-returning control flow and does not satisfy a `bot` return contract.

### `untyped` and `Dynamic[T]`

`untyped` is the dynamic type. It is consistent with every type:

```text
consistent(untyped, T)
consistent(T, untyped)
```

Rigor's internal representation is more precise:

```text
untyped = Dynamic[top]
```

`Dynamic[T]` is not surface RBS syntax and should not be accepted as an ordinary user-authored type. It is an implementation form that combines two facts:

- the value crossed a gradual boundary or otherwise came from unchecked information;
- current control-flow analysis can still prove the static facet `T`.

Gradual consistency treats the dynamic-origin wrapper as compatible with every target while preserving its provenance:

```text
consistent(Dynamic[T], U)
consistent(U, Dynamic[T])
```

This is not ordinary subtyping. Subtyping and method availability are checked against the static facet `T` when Rigor has one, while consistency explains why a dynamic value may cross a typed boundary.

Dynamic-origin intersection and difference preserve both precision and provenance:

```text
Dynamic[T] & U = Dynamic[T & U]
Dynamic[T] - U = Dynamic[T - U]
```

Thus `untyped & String` becomes `Dynamic[String]`, not plain `String` and not raw `untyped`. A trusted guard may narrow `Dynamic[top]` to `Dynamic[String]`; a method call such as `upcase` may then use `String` method facts. The receiver remains traceable to the unchecked source, and diagnostics can record that the call was enabled by a dynamic-origin fact.

Operations on raw `Dynamic[top]` should not create false precision. A method call on raw `untyped` returns `Dynamic[top]` unless Rigor has an explicit refinement, signature, or plugin-provided rule. Assigning a dynamic-origin value to a precise type is allowed at a gradual boundary, but Rigor must retain enough provenance to explain that the value passed through unchecked code.

Generic positions preserve dynamic-origin slots. For example, `Array[untyped]` is internally `Array[Dynamic[top]]`, not `Array[top]`. Reading an element returns `Dynamic[top]`. Writing an element follows gradual consistency, and stricter modes may report that the collection stores unchecked values. The same rule applies to hashes, tuples, records, proc parameters and returns, and shape members.

Rigor should distinguish dynamic-origin sources:

- explicit `untyped` in RBS, rbs-inline, or Steep-compatible annotations;
- missing external signatures or implicit unknown library facts;
- analyzer limits, failed inference, or plugin-declared dynamic behavior.

The type relation is the same for all of them, but diagnostics can distinguish deliberate gradual boundaries from places where users may want better signatures.

### `void`

`void` is not an ordinary value type in Rigor. It is a result marker for expressions whose return value should not be used.

RBS treats `void`, `boolish`, and `top` equivalently for many type-system purposes, but Rigor keeps `void` distinct internally so it can diagnose value use:

```ruby
result = puts("hello")
# `puts` returns void; assigning or sending methods to the value is suspicious.
```

Rules:

- `void` is valid in method and proc return positions.
- A `bot` implementation path is compatible with `void`; a `void` implementation path is not compatible with `bot`.
- `void | bot` normalizes to `void` in result summaries because the `bot` path contributes no normal value.
- `void` is valid as a generic argument, block parameter, or callback return only when preserving an existing RBS signature.
- Rigor should not infer or author new `void` slots inside ordinary unions, optionals, records, tuples, or parameter types.
- When imported RBS places `void` in a generic slot, Rigor preserves the slot. Reading from that slot produces a `void` result marker, and using that result follows the ordinary `void` value-context rule.
- In statement context, a `void` result is accepted.
- In value context, a `void` result produces a primary "use of void value" diagnostic and is materialized as `top` for downstream recovery.
- Recovery from a `void` value should suppress immediate cascading diagnostics such as "method on `top`" for the same expression unless the user has requested cascading output.

### `nil`, `NilClass`, and Optional Types

`nil` is the singleton nil value. `T?` is normalized to `T | nil`.

`NilClass` is a nominal RBS type, but Rigor should prefer the singleton `nil` internally whenever it can prove the exact value. Export should prefer `nil` for singleton nil and preserve `NilClass` only when it came from an explicit external signature.

### `bool`, Truthiness, and `boolish`

`bool` is `true | false`.

Ruby conditionals accept any value as a truth value: only `false` and `nil` are falsey. Rigor models this as a flow-sensitive predicate over types, not by widening every condition to `bool`.

RBS `boolish` is an alias of `top`. Rigor should erase truthiness-accepting callback return types to `boolish` when matching an existing RBS signature, but internally it should retain the actual return type when possible.

## Rigor Extensions

Rigor may infer types that RBS cannot spell directly. These types must always erase to RBS.

| Rigor extension | Purpose | RBS erasure |
| --- | --- | --- |
| Refined nominal type, such as `String where non_empty` | Predicate-proven subtype of a nominal type | Nominal base, such as `String` |
| Integer range, such as `Integer[1..]` | Numeric comparisons and bounds | `Integer` |
| Finite set of literals | Precise branch and enum tracking | RBS literal union when possible, otherwise nominal base |
| Truthiness refinement | Branch-sensitive nil/false elimination | Erased underlying type |
| Relational fact, such as `x == "foo"` | Captures a guard that may not be soundly reducible to a value type because Ruby equality is dispatch | Erased marker |
| Object shape | Known methods or singleton-object capabilities inferred locally | Named interface if available, otherwise `top` or nominal base |
| Inferred capability role | Minimum structural interface required by a method body, such as readable and rewindable stream behavior | Named interface when available, otherwise object shape erasure |
| Hash shape refinements beyond RBS records | Required keys, optional keys, read-only entries, open or closed extra-key policy, and key presence after guards | RBS record when exact, otherwise `Hash[K, V]` |
| Fact stability marker | Records whether a local, member, shape entry, or hash key fact survives assignment, calls, or mutation | Erased marker |
| Dynamic-origin wrapper, such as `Dynamic[T]` | Tracks precision lost through `untyped` while preserving the current static facet | `untyped` at unchecked boundaries; marker erased only after a checked non-dynamic contract |
| Negation or complement type, such as `~"foo"` | Represents values in the current domain except a type | Erased domain type |
| Conditional type | Models type-level branching when needed for library signatures | Conservative union or bound |
| Indexed access type | Projects member, tuple, record, or shape component types | Projected RBS type when expressible, otherwise conservative base |
| Template literal-like string refinement | Tracks formatted string families | `String` |

Rigor extensions must not leak into generated RBS syntax.

## Imported Built-In Types

Rigor imports type ideas from PHPStan, TypeScript, and Python typing only when they have a clear Ruby meaning. It should not preserve foreign syntax for compatibility by default.

Naming rules:

- Reserved built-in refinement names use `kebab-case`, such as `non-empty-string`, `positive-int`, and `non-empty-array[T]`.
- Refinement names describe a refined Ruby value domain and are parsed as Rigor-reserved type names, not as Ruby constants or RBS aliases.
- The `-` character is intentional: it is not valid in Ruby constants or RBS alias names, so names such as `non-empty-string` are visually and syntactically marked as Rigor built-ins.
- Rigor should not add lower_snake aliases for refinement names, such as `non_empty_string`, because those names remain available for ordinary RBS type aliases.
- Parameterized type functions and type-level operations use lower_snake names with square bracket arguments, such as `key_of[T]`.
- Type functions compute, project, or transform another type or literal set rather than naming a refined value domain directly.
- Type functions avoid `-` because `-` is also the difference operator in Rigor's type syntax; `int_mask[1, 2, 4]` is less ambiguous than `int-mask[1, 2, 4]`.
- Compatibility aliases should not be accepted unless they solve a concrete migration or readability problem.
- RBS names remain canonical when they already express the concept. For example, `bot` is the bottom type; `never`, `noreturn`, `never-return`, `never-returns`, `no-return`, `Never`, and `NoReturn` should not be added as aliases initially.
- Integer ranges should use Rigor's range notation, such as `Integer[1..10]`; PHPStan-style `int<1, 10>` should not be added as an alias initially.

Initial scalar refinements:

| Rigor type | Meaning | RBS erasure |
| --- | --- | --- |
| `non-empty-string` | `String` except `""` | `String` |
| `literal-string` | String known to come from source literals and literal-only composition | `String` |
| `numeric-string` | String accepted by Rigor's Ruby numeric-string predicate | `String` |
| `decimal-int-string` | String accepted by Rigor's Ruby decimal-integer-string predicate | `String` |
| `lowercase-string` | String equal to its lowercase normalization | `String` |
| `uppercase-string` | String equal to its uppercase normalization | `String` |
| `non-empty-lowercase-string` | `non-empty-string & lowercase-string` | `String` |
| `non-empty-uppercase-string` | `non-empty-string & uppercase-string` | `String` |
| `non-empty-literal-string` | `non-empty-string & literal-string` | `String` |
| `positive-int` | `Integer` greater than `0` | `Integer` |
| `negative-int` | `Integer` less than `0` | `Integer` |
| `non-positive-int` | `Integer` less than or equal to `0` | `Integer` |
| `non-negative-int` | `Integer` greater than or equal to `0` | `Integer` |
| `non-zero-int` | `Integer` except `0` | `Integer` |

The canonical lowercase string name is `lowercase-string`; `lower-string` should not be accepted as a separate alias unless a concrete usability problem appears.

Initial collection and shape refinements:

| Rigor type | Meaning | RBS erasure |
| --- | --- | --- |
| `non-empty-array[T]` | `Array[T]` with at least one element | `Array[T]` |
| hash shape with optional keys | Hash with known required and optional keys | RBS record when exact, otherwise `Hash[K, V]` |
| hash shape with extra-key policy | Hash shape that is open, closed, or open only for extra keys of a known value type | RBS record when exact and closed, otherwise `Hash[K, V]` |
| read-only hash shape entry | Key whose value may be read but should not be written through the current reference | Entry mutability marker erased |
| tuple refinements | Fixed or bounded array positions | RBS tuple when exact, otherwise `Array[T]` |
| object shape | Object with known public methods or singleton capabilities | Named interface when available, otherwise `top` or nominal base |

Python `TypedDict` contributes the vocabulary for shape exactness: required and non-required keys, read-only entries, and open, closed, or typed-extra-key policies. Rigor should adapt those ideas to Ruby hashes, options hashes, and keyword arguments. A read-only entry is a static write restriction on the current view of the value; it does not prove that the underlying Ruby object is frozen.

Rigor should not initially import PHPStan's `list<T>` and `non-empty-list<T>` as separate surface types. Ruby `Array[T]` already has list-like indexing semantics; `non-empty-array[T]` covers the useful refinement without adding another spelling.

Initial type functions and operators inspired by PHPStan, TypeScript, or Python typing:

| Rigor form | Meaning |
| --- | --- |
| `key_of[T]` | Known keys of a record, hash shape, tuple, or shape-like type |
| `value_of[T]` | Union of known values of a record, hash shape, tuple, or shape-like type |
| `T[K]` | Indexed access into tuple, record, object shape, or generic container metadata |
| `int_mask[1, 2, 4]` | Integers representable by bitwise-or over the listed flags, including `0` |
| `int_mask_of[T]` | Bit mask derived from a finite integer literal union or constant-derived set |

`key_of[T]` is the canonical spelling. Rigor should not accept both PHPStan-style `key-of<T>` and TypeScript-style `keyof T` unless there is a concrete benefit that outweighs the extra notation.

Deferred or rejected imports:

- Python `Any` and `object` should not become Rigor spellings. Rigor uses RBS `untyped` for dynamic boundaries and `top` for the greatest static value type.
- Python `Never` and `NoReturn` should not become aliases for `bot`; RBS already provides the canonical bottom type.
- Python `Protocol`, `TypedDict`, `Annotated`, `TypeGuard`, `TypeIs`, `Final`, and `ClassVar` should not become Rigor surface syntax. Their useful ideas map to RBS interfaces, Rigor shape refinements, `%a{...}` annotations, flow effects, and separate symbol or member facts.
- Python `type[C]` should not be imported as syntax. RBS already uses `singleton(C)` for class objects; a future `instance_type[T]` projection should be designed around Ruby factory APIs.
- Python numeric promotions such as `int` assignable to `float` or `complex` should not be imported directly. Ruby numeric behavior should be modeled from Ruby classes and RBS signatures.
- `class-string`, `interface-string`, `trait-string`, and `enum-string` are deferred. Ruby can pass class and module objects directly, and RBS already has `singleton(C)` for class objects.
- A PHPStan `new`-like type operation remains a future candidate, but it should be designed around Ruby class objects rather than class-name strings. For example, a future `instance_type[T]` could project the instance type created by a class object when factory APIs need that precision.
- `non-falsy-string` and `truthy-string` are not useful in Ruby because every `String` value is truthy.
- `non-decimal-int-string` should not be a named built-in initially; use `String - decimal-int-string`.
- PHP truthiness-oriented types such as `empty`, `empty-scalar`, `non-empty-scalar`, and `non-empty-mixed` should not be imported directly. Rigor should model Ruby truthiness with `false | nil` flow facts and explicit collection/string refinements.
- `Exclude`, `Extract`, and `NonNullable` should not be imported as surface aliases initially. Rigor can express them as `T - U`, `T & U`, and `T - nil`.

## Type Operators

The final surface syntax for Rigor-only type operators is not settled. This section records the intended semantics so implementation and documentation can converge later.

Candidate operators:

| Candidate | Meaning |
| --- | --- |
| `~T` | Complement of `T` within the current known domain |
| `T - U` | Difference: values in `T` excluding values in `U` |
| `T & U` | Intersection, already RBS-compatible |
| `T | U` | Union, already RBS-compatible |
| `key_of[T]` | Known keys of a shape-like type |
| `T[K]` | Indexed access into tuple, record, object shape, or generic container metadata |
| `if T <: U then X else Y` | Conditional type, if needed for advanced library modeling |

Rigor should treat `~T` as the compact display notation for negative facts produced by control-flow analysis. It should not be interpreted as "all possible Ruby objects except T" unless the value already has `top` as its positive domain. In flow analysis, it usually means "the previous type after excluding T".

Negative facts never infer the positive domain from the excluded type. `v != "foo"` can refine `String` to `String - "foo"` or `"foo" | "bar"` to `"bar"`, but it leaves raw `untyped` as `Dynamic[top]` with a relational negative fact.

Rigor should treat `T - U` as the preferred explicit authoring form for difference types in `RBS::Extended` annotations. It is often easier to read in library signatures than a bare complement, especially for scalar refinements such as `String - ""`.

Internally, Rigor may normalize difference to intersection with a negative type:

```text
T - U = T & ~U
```

This gives the notations a division of responsibility:

- `~T` is concise and useful for branch-local display, for example `~"foo"`.
- `T - U` is explicit and useful for user-authored extended signatures, for example `String - ""`.
- `T & ~U` is a convenient normalized form for implementation and reasoning.

Diagnostics should use a domain-aware display contract:

- If a finite domain normalizes to a small union, display the positive union. For example, `"foo" | "bar" - "foo"` displays as `"bar"`.
- If the positive domain is known and still broad, display `D - U`, such as `String - "foo"` or `Integer - 0`, rather than a bare complement.
- If multiple exclusions are retained, display a flattened difference such as `String - ("" | "foo")` instead of nested differences.
- If the current domain is `top`, prefer `top - U` or explanatory prose over bare `~U` unless the diagnostic is explicitly about a branch-local complement.
- Bare `~U` may be used only when the surrounding diagnostic already states the domain, for example "within `String`, value is `~\"foo\"`".
- If dynamic-origin provenance matters, display it separately from the domain expression when possible, for example `String - "foo"` with a dynamic-origin note, or `Dynamic[String - "foo"]` in technical traces.
- If the retained-exclusion budget is exceeded, display the positive domain plus an omission note rather than an unstable long chain, such as `Integer with 12 excluded literals omitted`.

Examples:

```text
String - "foo"      # Any String except the literal "foo"
1 | 2 | 3 - 2       # Equivalent to 1 | 3 after normalization
String - ("" | "x") # Any String except the listed literals
top - nil           # Any Ruby value except nil
~"foo"              # Only when the surrounding diagnostic states the domain
```

When the domain is finite, difference and complement should normalize precisely. When the domain is large or unknown, they should become refinements rather than expanding to enormous unions. Implementations should keep a configurable budget for retained negative literals or exclusions. Over budget, diagnostics should prefer the positive domain plus an indication that some exclusions were omitted over rendering a long unstable type.

## RBS::Extended Annotations

Rigor may read Rigor-specific metadata from RBS annotations in `*.rbs` files under the provisional name `RBS::Extended`.

RBS already supports `%a{...}` annotations on declarations, members, and method overloads. `RBS::Extended` should use that mechanism as the canonical attachment point because annotations are parsed into the RBS AST and remain associated with the signature node they describe.

These annotations let users and plugin authors describe types that exceed standard RBS without changing Ruby application code and without breaking ordinary RBS parsers. Standard RBS tools should be able to preserve or ignore these annotations. This follows the same compatibility principle as Python's `Annotated[T, metadata]`: the base type remains meaningful to tools that do not understand the metadata.

Example:

```rbs
%a{rigor:v1:return String where non_empty}
def read_name: () -> String

%a{rigor:v1:param value: String - ""}
def normalize: (String value) -> String

%a{rigor:v1:assert-if-true value is "foo"}
%a{rigor:v1:assert-if-false value is ~"foo"}
def check: (untyped value) -> bool
```

Rules:

- The ordinary RBS signature remains the compatibility contract.
- `RBS::Extended` annotations refine or explain that contract for Rigor.
- Annotation keys use a versioned `rigor:v1:` namespace, for example `rigor:v1:return` or `rigor:v1:predicate-if-true`.
- The annotation key comes first; the remaining text is a Rigor-specific payload.
- Rigor-generated annotations must use the explicit `rigor:v1:` prefix. Unversioned `rigor:` directives should not be emitted and should be treated as invalid until a compatibility migration need exists.
- The version prefix is part of the directive identity. Rigor v1 reads only `rigor:v1:` directives; an unsupported `rigor:vN:` directive is preserved by RBS tooling but reported by Rigor as unsupported metadata when it is on a node Rigor analyzes.
- Multiple annotations on the same RBS node must be interpreted deterministically and independently of source order.
- Exact duplicate annotations are idempotent.
- Compatible annotations compose by directive kind, target, and flow edge. For example, true-edge and false-edge predicate facts on the same parameter are different effect slots.
- Conflicting annotations are diagnostics; Rigor must not use first-wins or last-wins behavior. A conflict includes incompatible payload syntax, incompatible versions on the same node, two non-identical singleton directives for the same effect slot, contradictory refinements whose intersection is `bot`, and any annotation whose refinement exceeds the ordinary RBS contract.
- Prefer `T - U` for explicit user-authored difference types.
- Use `~T` primarily for negative facts and compact diagnostic display.
- If an annotation conflicts with the RBS signature, Rigor must report a diagnostic.
- Exported plain RBS must drop or erase Rigor-only annotations unless the user asks to preserve them.
- The annotation grammar is versioned and should remain small until implementation experience proves it out. Incompatible grammar changes require a new version prefix rather than changing `rigor:v1:` semantics.

### Type Predicates and Assertions

Rigor models Python `TypeGuard`/`TypeIs`-style predicates, TypeScript-style type guards, and PHPStan-style assertions as flow effects attached to RBS method signatures.

Predicate examples:

```rbs
%a{rigor:v1:predicate-if-true value is String}
%a{rigor:v1:predicate-if-false value is ~String}
def string?: (untyped value) -> bool

%a{rigor:v1:predicate-if-true self is LoggedInUser}
def logged_in?: () -> bool
```

Assertion examples:

```rbs
%a{rigor:v1:assert value is String}
def assert_string!: (untyped value) -> void

%a{rigor:v1:assert-if-true value is String}
def valid_string?: (untyped value) -> bool
```

Meanings:

- `rigor:v1:predicate-if-true target is T` refines `target` to `T` on the true branch of a call used as a condition.
- `rigor:v1:predicate-if-false target is T` refines `target` to `T` on the false branch.
- `rigor:v1:assert target is T` refines `target` after the method returns normally.
- `rigor:v1:assert-if-true target is T` refines `target` when the method returns a truthy value.
- `rigor:v1:assert-if-false target is T` refines `target` when the method returns `false` or `nil`.

A true-branch-only predicate is sufficient for Python `TypeGuard`-like behavior. A predicate pair that describes both branches is sufficient for Python `TypeIs`-like behavior. The false branch may be written as an explicit negative type when that is clearer:

```rbs
%a{rigor:v1:predicate-if-true value is String}
%a{rigor:v1:predicate-if-false value is ~String}
def string?: (untyped value) -> bool
```

The initial target grammar should be intentionally small:

```text
target ::= parameter-name | self
```

`parameter-name` refers to an RBS method parameter name, not an arbitrary Ruby Symbol. RBS parameter names follow `_var-name_ ::= /[a-z]\w*/`, so predicate targets should follow that existing identifier style. The hyphenated words in directives such as `predicate-if-true` live inside the annotation payload and are parsed by Rigor, not as Ruby Symbols.

If a predicate needs to refer to an argument, the RBS method type must name that argument:

```rbs
# Good: `value` can be referenced.
%a{rigor:v1:predicate-if-true value is String}
def string?: (untyped value) -> bool

# Not enough information for a predicate target.
def string?: (untyped) -> bool
```

Future versions may extend targets to instance variables, record keys, shape paths, and block parameters, but those should use explicit path syntax rather than overloading the annotation directive name.

### Flow Effects and Extension Contributions

The type specification depends on the extension API exposing facts, not direct scope mutation. A plugin or `RBS::Extended` annotation may contribute a flow effect bundle with:

- normal return type;
- truthy-edge facts;
- falsey-edge facts;
- post-return assertion facts;
- exceptional or non-returning effects;
- block call-timing effects;
- escape effects for receivers, arguments, blocks, and captured locals;
- receiver and argument mutation effects;
- fact invalidation effects;
- dynamic reflection members introduced by the call.

The analyzer applies these contributions through the same control-flow machinery it uses for built-in guards. This keeps short-circuiting expressions precise. For example, a plugin-defined predicate used on the left side of `&&` must refine the scope used to analyze the right side, and its negative fact must flow into the right side of `||`.

Future target grammar should grow only with clear stability rules. Plausible targets include:

- `self`;
- named parameters;
- local variables visible at the call site;
- receiver members, such as `self.name`;
- instance variables, such as `@name`;
- hash or record keys, such as `config[:mode]`;
- tuple or array elements with literal indexes;
- method-result paths on the same receiver, when the method is known to be pure or stable.

Targets that can be mutated behind the analyzer's back should either be rejected in annotations, treated as `maybe`, or paired with explicit stability metadata.

## Normalization

Rigor normalizes types before comparison and reporting.

- Flatten nested unions and intersections.
- Remove duplicate union and intersection operands.
- Drop `bot` from unions.
- Drop `top` from intersections.
- Expand `T?` to `T | nil` internally.
- Normalize finite set difference and complement when the domain is known.
- Preserve negative facts as scope facts over a positive domain; do not introduce a positive domain from the excluded value alone.
- Budget retained negative facts for large domains and widen display when the budget is exceeded.
- Preserve hash shape openness and read-only markers until RBS erasure.
- Collapse `true | false` to `bool` for display when that is clearer.
- Preserve literal precision until it becomes too large or expensive; then widen to the nominal base.
- Preserve dynamic-origin wrappers explicitly rather than normalizing `untyped` to `top`.
- Normalize dynamic-origin unions, intersections, and differences by transforming the static facet and keeping the wrapper.

Normalization must be deterministic so diagnostics, caches, and exported signatures are stable.

## RBS Erasure

RBS erasure converts an internal Rigor type to a valid RBS type.

Erasure rules:

- Exact RBS types erase to themselves.
- Refined types erase to their unrefined base.
- Unsupported literal kinds erase to their nominal class.
- Integer ranges erase to `Integer`.
- Complement and difference refinements erase to their current domain type.
- Hash shape openness, extra-key, and read-only markers are erased by the hash-shape erasure algorithm below.
- Object shapes erase to a matching named interface when one exists, otherwise a conservative nominal or `top`.
- Dynamic-origin wrappers erase to `untyped` when exported as unchecked boundary types. When a value has already been checked against a non-dynamic contract, the contract type is exported and the dynamic marker is not represented in RBS.
- Invalid-context `void`, `self`, `instance`, or `class` forms are rewritten to valid conservative RBS and reported as precision loss.

Erasure is conservative: if `erase(T) = R`, then every value accepted by `T` must be accepted by `R`.

### Hash Shape Erasure

Hash shapes carry more information than RBS records and `Hash[K, V]` can express: required keys, optional keys, read-only entries, open or closed extra-key policy, key presence facts, dynamic-origin provenance, and stability. RBS erasure should lose that information deterministically and conservatively.

Exact closed shapes erase to RBS records when every key can be represented by RBS record syntax:

- Required entries become required record fields.
- Optional entries become optional record fields when RBS can spell the optional key.
- Entry value types erase recursively.
- Read-only, provenance, stability, and key-presence markers are erased.
- Missing optional keys do not add `nil` to the value type. Absence is not a stored value.

For example:

```text
closed { a: 1, b: "str" }
  => { a: 1, b: "str" }

closed { a: Integer, ?b: String }
  => { a: Integer, ?b: String }
```

If the shape cannot be represented as an exact RBS record, it erases to `Hash[K, V]`.

The key type `K` is reconstructed from:

- known literal keys, kept as a literal union while the set is finite and within the export budget;
- widened nominal key classes when the literal-key set is too large for readable RBS;
- the declared extra-key bound for open shapes with typed extra keys;
- `top` for statically open shapes with unknown extra keys;
- `untyped` for dynamic-origin extra keys.

The value type `V` is reconstructed from:

- values of all known required entries;
- values of known optional entries, because they may be present;
- the declared extra-value bound for open shapes with typed extra keys;
- `top` for statically open shapes with unknown extra values;
- `untyped` for dynamic-origin extra values.

Optional-key absence does not contribute `nil` to `V` unless the entry value type itself includes `nil`.

An exact empty closed record erases to `{}`. If a target RBS version or output mode cannot preserve an empty record, the fallback is `Hash[bot, bot]`.

For open shapes, the extra-value bound must be used when known. Rigor should not use only the current known value union for unknown extra keys, because an unseen extra key may hold a value unrelated to the observed entries.

Examples:

```text
open { a: 1, b: "str", **String => bool }
  => Hash[:a | :b | String, 1 | "str" | bool]

open { a: 1, b: "str", **unknown }
  => Hash[top, top]

dynamic-open { a: 1, **untyped }
  => Hash[untyped, untyped]
```

If literal key or value unions exceed the export budget, Rigor widens them to nominal bases deterministically, such as `Hash[Symbol, Integer | String]`. Losing closedness, optional-key precision, read-only status, or literal precision should be reportable in strict export or explanation mode.

## Inference Budgets and User-Supplied Boundaries

Rigor should stop inference before hard cases become global searches. Recursive methods, mutually recursive call graphs, overloaded operators, dynamic dispatch, large unions, and unconstrained structural inference all need explicit budgets. When a budget is exceeded, Rigor should produce an incomplete-inference result with a reason instead of silently inventing precision.

Operator-heavy recursive code is a motivating case:

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

Without a parameter or return contract, `<=` and `-` are too polymorphic to infer a unique domain by enumerating every Ruby class that implements them. The recursive calls also make return inference fan out. Rigor should detect this shape early and ask for a boundary rather than expanding the search.

Accepted signature contracts are inference cutoffs. A simple return annotation such as `#: Integer`, a full inline `# @rbs` method type, a generated stub, or an external `.rbs` declaration all let callers use the declared return and stop recursive return inference at the method boundary. The implementation body is still checked against the contract.

CLI behavior should have two modes:

- Non-interactive mode reports an incomplete-inference diagnostic, the reason for stopping, and one or more compatible ways to add a boundary contract.
- Interactive mode may prompt the user for a boundary type, such as an rbs-inline return `#: Integer`, a full method signature, or an external RBS entry. Rigor should only write or modify files after explicit user confirmation.

The prompt should prefer small, ecosystem-compatible annotations. For return-only recursive cutoffs, `#: Integer` can be enough. When receiver or operator parameter domains are also unconstrained, Rigor may ask for a full method type such as `(Integer x, Integer y, Integer z) -> Integer` or suggest adding the contract in `.rbs`.

If no boundary is supplied, callers should not receive a fabricated precise type. Rigor may use `Dynamic[top]`, `top`, or another conservative incomplete-inference marker internally, but diagnostics and exports must preserve the fact that inference stopped.

## Diagnostic Policy

Rigor should prefer precise diagnostics over silent widening.

- Using `void` as a value is a primary diagnostic; downstream recovery uses `top` and should avoid duplicate cascade reports for the same expression.
- Calling a method on `top` without proof is a diagnostic.
- Calling a method on raw `untyped` is allowed but should be traceable to an unchecked boundary.
- Calling a method on `Dynamic[T]` may use the static facet `T`, but diagnostics should be able to explain that the proof depended on a dynamic-origin value.
- Strict dynamic modes may report dynamic-to-precise assignments, arguments, returns, and generic-slot leaks such as `Array[Dynamic[top]]`.
- Strict static modes may additionally report method calls or branch proofs whose safety depends on dynamic-origin facts rather than checked static facts.
- A branch narrowed by a negative fact should display that fact when it is useful, for example `String - ""` or `~"foo"`.
- Diagnostics should prefer explicit domain-bearing displays such as `String - "foo"` when a bare `~"foo"` would be ambiguous.
- Writing through a read-only shape entry is a diagnostic when Rigor has that fact.
- Passing unexpected keys to a closed keyword or options-hash shape is a diagnostic.
- Invalid or contradictory `RBS::Extended` annotations are diagnostics.
- Method implementations are checked against accepted signature contracts regardless of source: inline `#:`, `# @rbs`, rbs-inline parameter annotations, generated stubs, and external `.rbs` declarations all have the same implementation-side force.
- When inference stops because of recursion, operator ambiguity, dynamic dispatch, or budget exhaustion, Rigor should report the cutoff and suggest a boundary contract rather than pretending the inferred type is precise.
- When an explicit nominal parameter type rejects a call but the method body only requires a smaller inferred capability role, Rigor may suggest generalizing the public signature to an interface rather than adding an ad hoc union.
- Losing precision during RBS export should be reportable when users request explanation or strict export mode.

## Implementation Expectations

The implementation should keep parsing, internal type representation, subtyping, consistency, normalization, scope transition, effect application, and RBS erasure as separate concepts. This keeps RBS compatibility stable while leaving room for inference-oriented internal precision.

The core type engine should expose:

- immutable `Scope` snapshots;
- edge-aware condition analysis for truthy, falsey, normal, exceptional, and unreachable exits;
- inference budgets and incomplete-inference results that preserve the reason inference stopped;
- a fact store that can represent value facts, negative facts, relational facts, member-existence facts, shape facts, dynamic-origin provenance, stability facts, escape facts, and captured-local write facts;
- an effect model for receiver and argument mutation, block call timing, closure escape, purity, and fact invalidation;
- capability-role inference that can cache per-method requirement summaries, match them against indexed named interfaces when available, and keep anonymous shapes when matching is ambiguous or too expensive;
- normalization for unions, intersections, complements, differences, and impossible refinements;
- semantic type queries for extensions so plugin authors ask capability questions rather than inspecting concrete type classes;
- conservative RBS erasure with optional loss-of-precision explanations.

This structure is necessary for the ideal behavior described above: precise Ruby-shaped duck typing, expression-level narrowing inside compound conditions, and a plugin API that can add framework knowledge without taking ownership of the analyzer's control-flow state.
