# Structural Interfaces and Object Shapes

Rigor models Ruby duck typing through RBS interfaces, internal object shapes, and a curated catalog of capability roles. Class and module names remain nominal; structural typing applies only at specific boundaries.

An RBS interface type, such as `_Closable`, is a **named structural contract**. An **internal object shape** is an anonymous structural type inferred from local definitions, singleton methods, module members, included modules, plugin facts, or control-flow guards. A nominal type or object shape is assignable to an interface when Rigor can prove that it provides all required members with compatible types.

This document defines:

- the boundary at which structural typing applies;
- assignability and member-compatibility rules;
- visibility, reader/writer capability, and `respond_to?` semantics;
- the schema for object-shape entries and `MethodEntry` records;
- the capability-role catalog and the discipline that bounds role inference;
- the diagnostic-versus-hint escalation rule.

The specific rules for plugin-supplied facts and `RBS::Extended` annotations are in [rbs-extended.md](rbs-extended.md).

## Where structural typing applies

Rigor MUST NOT make ordinary class-to-class compatibility TypeScript-style structural by default. Class and module names remain nominal because RBS uses those names as declarations about Ruby constants and because Ruby runtime checks such as `is_a?` and `kind_of?` depend on class/module relationships.

Structural typing applies at these boundaries:

- assigning or passing a value where an RBS interface is expected;
- checking whether an inferred object shape satisfies an interface;
- checking a direct method send against a known shape;
- using plugin-provided dynamic reflection to add members to a shape or nominal type.

This gives Rigor a pseudo-protocol model without adding new surface syntax:

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

## Assignability rules

- A concrete nominal type is assignable to an interface when its instance method shape satisfies every interface member.
- An object shape is assignable to an interface when the shape contains every required member with an assignable signature.
- One interface is assignable to another when the source interface provides all members required by the target interface.
- Interface unions behave like ordinary unions.
- Interface intersections require all members from all intersected interfaces.
- Callable object shapes MAY satisfy proc-like or interface-like call contracts through a known `call` method when the signature is compatible.
- Singleton class and module object shapes MAY satisfy interfaces through singleton methods and module-level members. This SHOULD be implemented after instance-side structural checks.

Member compatibility follows method-type compatibility, not just name existence. Rigor MUST compare visibility, arity, positional parameters, keyword parameters, blocks, overloads, return types, and receiver constraints through the ordinary method-assignability rules once those exist.

## Reader and writer capabilities

Reader and writer capabilities are method capabilities, not field declarations. `attr_reader`, `attr_writer`, and `attr_accessor` are sources of method facts; Rigor models the resulting `x` and `x=` methods as separate entries on the shape.

- A read-only member is represented by a reader method and is **covariant** in its return type.
- A write-only member is represented by a writer method and is **contravariant** in its accepted value type.
- A read-write member, such as an `attr_accessor` pair, combines reader and writer requirements and is effectively **invariant** in the value type.

Accessor syntax is one source of these method facts:

- `attr_reader :x` contributes a public reader method `x` unless surrounding Ruby visibility state changes it.
- `attr_writer :x` contributes a writer method `x=` and does not imply a reader.
- `attr_accessor :x` contributes both methods, but Rigor MUST still model them as two method entries.
- A manually defined or overridden `x` or `x=` method replaces or refines the method fact according to ordinary Ruby method lookup and source order.

Reader and writer capability does **not** imply purity. A reader MAY mutate state, and a writer MAY return any Ruby value unless a signature or implementation proves otherwise.

## Visibility

Visibility is a first-class facet of every method-shape entry. Rigor MUST track at least `public`, `protected`, and `private`, plus the call context in which a member can be used:

- External explicit-receiver sends require a public method.
- Private methods MAY be called only in private-call contexts, not as ordinary explicit-receiver sends.
- Protected methods follow Ruby's protected-receiver restriction and MUST NOT satisfy public structural interface requirements by default.
- Public structural interfaces require public members unless the interface or internal check explicitly asks for another visibility.

## `respond_to?` and method-missing facts

`respond_to?` checks MAY refine an object to an existence-only shape, for example "has public method `close`". That fact is useful for diagnostics and guarded sends, but it does not prove full signature compatibility with an interface unless Rigor also knows the method type.

The optional `include_private` argument MUST affect the visibility fact:

- `obj.respond_to?(:foo)` records a public existence fact for `foo` on the true branch.
- `obj.respond_to?(:foo, false)` is the same as the default when the second argument is statically false.
- `obj.respond_to?(:foo, true)` records an existence fact whose visibility may be public, protected, or private. By itself it does not prove that `obj.foo` is legal as an external explicit-receiver call.
- If the second argument is not statically known, Rigor MUST record a weaker maybe-private visibility fact.

If the method exists only through `respond_to_missing?` or `method_missing`, the fact MUST be recorded with dynamic provenance and an unknown or plugin-provided signature so diagnostics can explain why the call was accepted.

## Object-shape entry schema

Object-shape entries MUST carry enough metadata to avoid confusing Ruby's dynamic surface with a static protocol proof:

- **member kind**, such as method, reader, writer, constant, or index operation;
- **call signature** or readable/writable value type;
- **visibility** and valid call context;
- **source and provenance**, such as source definition, RBS, plugin, `respond_to?`, or `method_missing`;
- **stability and mutation** information;
- **certainty**, such as `yes`, `maybe`, or `no` (see [relations-and-certainty.md](relations-and-certainty.md)).

## Method entries (`MethodEntry`)

The first implementation pairs one method-shape entry with one resolved Ruby method body:

- A `MethodEntry` is one record per `(class-or-module, method name)` and corresponds to the runtime-resolved method body for that name on that class or module. Ruby has no per-signature overloading at runtime, so multiple `def foo` definitions in the same class collapse to a single entry.
- Visibility is stored at the entry level. `private :foo` and similar visibility toggles act on the whole method, not on a particular signature variant.
- Signature variants from RBS overloads, `RBS::Extended` payloads, or plugin contributions are stored as a list of branches inside the entry. Branches share the entry's visibility but MAY carry different argument shapes, return types, predicate effects, and mutation effects.
- Conditional `def`, conditional `private`, and other dynamically constructed method definitions are out of scope for the first implementation. They surface as ordinary diagnostics or dynamic-origin facts.

Open classes, reopens, and monkey patches contribute to the same entry rather than producing parallel ones:

- Each `def foo` across files contributes a candidate definition. The default merge policy follows Ruby's runtime resolution: the candidate that Ruby would actually dispatch wins. Among ordinary same-class redefinitions this is source order with a last-definition-wins resolution; among ancestor chains this is the lookup order Ruby uses for `prepend` over the class over `include`d modules over the superclass chain.
- Strict mode raises a diagnostic when a re-definition changes RBS-visible signature or visibility without an explicit override marker (working name `rigor:v1:override=replace`; see [rbs-extended.md](rbs-extended.md)). Until that marker exists, strict mode reports the suspected silent monkey patch.
- Module includes and refinements are not flattened into the host class's entry. They remain on their owning module and participate in lookup through the ancestor chain.

## Capability roles

Rigor models common Ruby "IO-like" relationships as capability roles, not as global class equivalence.

`IO` and `StringIO` are the motivating example. A `StringIO` is often a good test double for an `IO` object when the code only reads, writes, rewinds, or closes a stream. It is not a subclass of `IO` and does not have the same complete method set. Treating `StringIO` as a subtype of `IO` would erase real runtime differences. Requiring every implementation to write `IO | StringIO` would also miss the point of Ruby duck typing.

The model is:

- `IO` remains a nominal type for APIs that require an actual `IO` object or file-descriptor-backed behavior.
- `StringIO` remains a separate nominal type.
- Both classes MAY satisfy smaller structural interfaces such as readable, writable, seekable, flushable, or closable stream roles.
- A method that only calls stream capability methods SHOULD be inferred as requiring the corresponding object shape or named interface, not the whole nominal `IO` type.
- A method that calls `IO`-specific members such as file-descriptor operations SHOULD require `IO` or a more specific file-descriptor-backed role.

### Core role catalog

Rigor MUST ship an opinionated core catalog of common standard-library capability roles. The catalog reuses existing RBS-defined interfaces wherever Ruby and the standard library already provide them, and adds a small set of Rigor-specific roles only where existing interfaces are missing or would conflate distinct capabilities.

Reused RBS interfaces (matched by their existing RBS shape, not redefined by Rigor):

| Interface | Use |
|---|---|
| `_Each[T]` | Enumerable iteration over `T` |
| `_Reader` | Stream-like read access |
| `_Writer` | Stream-like write access |
| `_ToS` | Implicit string conversion through `to_s` |
| `_ToStr` | Explicit string coercion through `to_str` |
| `_ToInt` | Explicit integer coercion through `to_int` |
| `_ToProc` | Block conversion through `to_proc` |
| `_ToHash[K, V]` | Hash coercion through `to_hash` |
| `_ToA[T]` | Array conversion through `to_a` |
| `_ToAry[T]` | Strict array coercion through `to_ary` |
| `Enumerable[T]` | Broad collection protocol, treated as a nominal interface for role matching |
| `Comparable` | Ordering protocol, treated as a nominal interface for role matching |

Rigor-specific roles added in the first milestone, each shipped with an explicit RBS interface in Rigor's bundled signatures:

| Role | Purpose | Required members |
|---|---|---|
| `_RewindableStream` | Stream-like objects that can be replayed from the start | `read`, `rewind` |
| `_ClosableStream` | Stream-like objects whose lifetime can be closed | `close`, `closed?` |
| `_FileDescriptorBacked` | Real OS-backed streams that justify diagnostics requiring an actual `IO` | `fileno` |
| `_Callable[**A, R]` | Anything that responds to `call`, distinct from `_ToProc` | `call(*A) -> R` |

Plugins MAY add framework roles, additional conformance facts, role-specific exclusions, and `maybe` conformance, but they MUST NOT silently replace either the reused RBS interfaces or the Rigor-specific roles in this catalog.

The role names and method signatures below are illustrative, not final standard-library signatures:

```rbs
interface _Reader
  def read: (*untyped) -> String?
end

interface _RewindableStream
  def read: (*untyped) -> String?
  def rewind: () -> untyped
end
```

```ruby
def slurp(stream)
  stream.rewind
  stream.read
end
# Inferred requirement: _RewindableStream
# `IO` and `StringIO` can both satisfy that requirement if their signatures match.
```

This avoids comparing total method sets. Structural subtyping asks whether a value provides the target role's required members; it does not require the source object and target object to expose the same complete surface.

### Generic preservation

When a method returns the same stream object it receives, Rigor SHOULD preserve the concrete input type through generics rather than widening to a role:

```rbs
def reset: [S < _RewindableStream] (S stream) -> S
```

Generic preservation is a separate rule from role extraction. If a method returns the same parameter object it received, Rigor SHOULD prefer a type variable such as `[S < _RewindableStream] (S stream) -> S` when the body preserves object identity. It MUST NOT widen the return to `_RewindableStream` merely because the parameter requirement is structural. If the body MAY replace the value, branch between unrelated objects, or return a delegated object, Rigor SHOULD fall back to the ordinary inferred return type.

Unions remain useful when the implementation genuinely has class-specific behavior. If the method branches on `IO` versus `StringIO`, calls members unique to each class, or returns class-specific values, then `IO | StringIO` is a faithful type. For ordinary duck-typed stream consumption, capability roles are the preferred model.

### Erasure

RBS erasure SHOULD prefer a matching named interface when one exists. Anonymous object shapes that do not match a known interface erase to a conservative nominal base or `top`. The erasure algorithm is in [rbs-erasure.md](rbs-erasure.md).

## Capability-role inference discipline

Capability-role inference MUST be bounded. Rigor SHOULD infer a per-method requirement summary for each parameter and receiver rather than repeatedly reanalyzing every call site. A summary contains the members the method body actually requires, including method names, visibility, arity, keyword and block requirements, return-use constraints, mutation requirements, and provenance. It is an anonymous object-shape requirement until Rigor proves that a named interface or small intersection of named interfaces is a good representation.

The first implementation SHOULD keep the inference local and monotone:

- Analyze the method body once per relevant method version and cache the requirement summary.
- Use existing signatures or cached summaries for direct calls; do not recursively inline callees by default.
- For recursive methods or mutually recursive summaries, start with an unknown or widening placeholder and iterate only to a small fixed-point budget.
- Treat `send`, `public_send`, unknown `method_missing`, and dynamic delegation as dynamic requirements unless a plugin or signature provides a precise target.
- Widen large requirement shapes by keeping the member set needed for diagnostics and dropping low-value details such as long overload expansions when they exceed a budget.

### Named-interface matching

Named-interface matching SHOULD be indexed, not a scan of every interface. Rigor MAY maintain an index from required member names and visibility to candidate interfaces. A candidate interface is compared only when it shares at least one required member and passes cheap arity or visibility filters. If the candidate set is too large, Rigor SHOULD keep the anonymous shape and avoid a generalization hint instead of performing an expensive global search.

When multiple named interfaces match, selection MUST be deterministic and conservative:

1. Prefer an exact member-signature match.
2. Prefer a configured standard-library role over an unrelated coincidental interface.
3. Prefer fewer extra required members.
4. Then a stable lexical name order.
5. If several candidates remain meaningfully ambiguous, keep the anonymous shape internally and do not emit a named-interface suggestion.

Intersections of named roles are useful, but Rigor MUST NOT solve an unbounded set-cover problem to find the mathematically smallest role expression. The first implementation MAY use only exact single-interface matches, explicit standard role bundles, or a small greedy intersection under a strict candidate limit. Otherwise it keeps the anonymous shape.

The candidate limit is `budgets.interface_candidates`; see [inference-budgets.md](inference-budgets.md).

## Escalation rule

Explicit declarations still matter. If an external RBS signature says a parameter is `IO`, Rigor MUST treat that as the public nominal contract. If the implementation and observed call sites only require `_Reader`, Rigor MAY report that the declared type is narrower than the inferred capability requirement and suggest generalizing the signature to a structural interface. It MUST NOT silently rewrite a public `IO` contract into a structural one.

The escalation rule used when the inferred role and the declared type disagree is explicit:

- **Diagnostic.** A call that does not satisfy the declared parameter type is always reported, regardless of how the body is implemented. This level is independent of any configuration.
- **Hint.** When the body's inferred role is strictly smaller than the declared nominal type and a generalization to a structural interface would still type-check, Rigor MAY emit a `hint.role-generalization.*` diagnostic. Hints are gated by the `style.suggest_role_generalization` configuration switch and default to off so libraries that intentionally chose a nominal contract are not nudged out of it.
- **Silent.** Otherwise the inference result is retained internally and available to callers, refactor tooling, and the plugin `Scope` API, but no diagnostic is emitted.

The three levels are mutually exclusive at any given site. Rigor MUST never both reject a call and offer a hint for the same parameter, and MUST never silently rewrite a public nominal contract into a structural one.
