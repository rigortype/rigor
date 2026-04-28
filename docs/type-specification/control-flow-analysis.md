# Control-Flow Analysis

Rigor performs flow-sensitive type analysis in the style of PHPStan, TypeScript, and Python type checkers. The analyzer refines types by guards, returns, raises, loop exits, pattern matches, equality comparisons, predicate methods, and plugin-provided facts.

This document defines:

- the structure of edge-aware scopes;
- supported narrowing sources;
- Ruby equality semantics for narrowing;
- fact stability, invalidation, and mutation effects;
- the pre-plugin v1 narrowing surface and what is deferred to v1.1.

The flow-effect bundle schema used by `RBS::Extended` annotations and plugin contributions is in [rbs-extended.md](rbs-extended.md).

## Edge-aware scopes

The type environment is refined by guards, returns, raises, loop exits, pattern matches, equality comparisons, predicate methods, and plugin-provided facts. Each expression is analyzed with an input `Scope` and produces output scopes for the relevant edges:

- normal completion;
- truthy condition result;
- falsey condition result;
- exceptional or non-returning exit;
- unreachable result, represented by `bot`.

These scopes carry both **positive facts** and **negative facts**. Joins merge those facts conservatively.

Edge-aware scopes are finer than assigning one scope to the whole `if` condition. Short-circuiting expressions update the scope between operands:

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

The right side of `&&` is analyzed after the left side's true fact has refined `foo` to `"foo"`. The true edge of `foo == "bar"` then intersects `"foo"` with `"bar"`, normalizes to `bot`, and marks the body as unreachable. Rigor SHOULD be able to report the contradiction at the comparison or at the unreachable body, depending on diagnostic policy.

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

## Supported narrowing sources

Supported narrowing sources include:

- Trusted equality and inequality checks against literals and singleton values.
- `nil?` checks and nil comparisons.
- Truthiness checks, where `nil` and `false` narrow the false branch.
- `is_a?`, `kind_of?`, `instance_of?`, and class/module comparisons.
- `respond_to?` checks when the method name is statically known. See [structural-interfaces-and-object-shapes.md](structural-interfaces-and-object-shapes.md) for the visibility rules.
- Pattern matching and case analysis.
- Predicate methods registered by Rigor plugins.
- Assertions and guards described in `RBS::Extended` annotations (see [rbs-extended.md](rbs-extended.md)).

## Negative facts

Negative facts are first-class scope facts. Rigor SHOULD preserve facts such as "not nil", "not false", "not this literal", and "does not have this nominal class" when they improve later diagnostics.

A negative fact is **domain-relative**: it removes values from the value's already-known positive domain. It MUST NOT introduce a new positive domain from the right-hand side of a comparison. The complete semantic and display rules for negative facts are in [type-operators.md](type-operators.md).

Python's `TypeGuard` and `TypeIs` are useful reference points for predicate effects. A predicate that refines only the true branch is `TypeGuard`-like. A predicate that refines both true and false branches is `TypeIs`-like; internally, the false branch SHOULD be modeled as intersection with a complement, such as `A & ~R`, or as an equivalent difference type.

## Ruby equality semantics

Ruby equality is method dispatch. A syntactic comparison such as `foo == "foo"` calls `foo.==("foo")`, and arbitrary classes MAY override that method. Rigor MUST therefore distinguish:

- **identity facts**, such as `x.equal?(obj)`, which can prove singleton identity;
- **nil and boolean checks**, which are stable Ruby value tests;
- **equality facts for known built-in domains** whose dispatch target is stable, such as finite `String`, `Symbol`, `Integer`, `true`, `false`, and `nil` alternatives already present in the receiver domain;
- **comparison facts contributed by RBS or plugins** for trusted predicate and equality methods;
- **unknown equality methods**, which SHOULD produce at most a relational fact unless the analyzer has enough method information to refine the value type;
- **floating-point comparisons**, which MUST NOT produce literal narrowing by default because `NaN`, signed zero, infinities, and coercion make exhaustiveness and equality reasoning easy to misstate.

Equality narrowing MUST NOT introduce a positive domain from the compared value alone. If `foo` is raw `untyped`, `foo == "foo"` keeps `foo` as `Dynamic[top]` with a dynamic-origin relational fact unless Rigor also knows that the dispatched equality method has a trusted narrowing effect. If `foo` is already known to be `"foo" | "bar"`, the same comparison MAY narrow the true branch to `"foo"` and the false branch to `"bar"`.

### Equality trust levels

Rigor SHOULD classify equality facts by trust level:

- **Identity facts from `equal?`** are value facts as long as the observed reference itself remains stable.
- **Built-in literal-domain equality** can narrow only inside an already-compatible receiver domain with a known core dispatch target.
- **`Module`, `Class`, `Range`, `Regexp`, and `===`-based case behavior** need explicit per-kind rules or plugin facts rather than being treated as general equality.
- **User-defined `==`, `eql?`, `===`, and coercion-sensitive comparisons** remain relational facts until RBS metadata or a plugin declares true-edge and false-edge effects.

The initial trusted equality surface is intentionally narrow:

- `equal?` produces an identity fact bound to the observed reference. The fact is invalidated by reassignment, alias-escaping mutation, unknown calls, or plugin-declared effects.
- Built-in literal-domain equality is trusted only for finite literal sets of `String`, `Symbol`, `Integer`, booleans, and `nil`, and only when the receiver dispatch target is known and the receiver domain is already compatible.
- `Float` literal narrowing is refused by default. Relational facts MAY still be kept for diagnostics.
- `Range`, `Regexp`, `Module`, `Class`, and `===`-based case behavior MUST NOT produce general value-narrowing facts on their own. They require specific narrowing rules or RBS/plugin effects before they can refine value domains.
- User-defined `==`, `eql?`, and `===` are promoted from relational facts to value facts only through explicit RBS metadata, `RBS::Extended` flow effects, or plugin-declared true-edge and false-edge facts together with any required stability or purity assumptions.

## Fact stability and mutation

Flow facts are valid only while the analyzer can trust the path they describe. Rigor MUST invalidate or weaken facts when Ruby behavior can mutate, replace, or escape the observed target.

Facts MUST carry a target and a stability reason. The first implementation distinguishes at least:

- **local binding facts**, such as "local `x` currently refers to a non-nil value";
- **captured local facts**, where a block, proc, or lambda may write the local from another lexical scope;
- **object-content facts**, such as hash keys, instance variables, singleton methods, and object-shape members;
- **global storage facts**, such as constants, class variables, and globals;
- **dynamic-origin and relational facts**, which may survive local calls but still need target invalidation.

### Targeted invalidation

Local binding facts are stable across ordinary method calls until assignment to that local. A call MAY mutate the object referenced by the local, but it MUST NOT rebind the local variable itself unless the local is captured by a closure that writes it. Therefore:

- `x.is_a?(String)` remains a local binding fact after an unknown call that cannot write `x`;
- `x[:key]` or `x.foo` shape facts MAY be weakened by a call that can mutate `x` or escape it;
- facts about instance variables, class variables, globals, and constants are heap or global-storage facts and are invalidated more aggressively.

Unknown method calls remain conservative for heap facts. They MAY invalidate object-shape, hash-entry, instance-variable, constant-object, and global-storage facts for any target that may have escaped to the call. They MUST NOT invalidate every local binding fact in the current scope.

### Closure captures

Closure-captured locals need explicit handling. When a block, proc, or lambda writes an outer local, Rigor MUST record a captured-local write effect. If the closure is invoked immediately and its body is available, Rigor applies the write at the call edge. If the closure escapes or may be invoked later, facts about locals it can write become unstable after the escape point and before any unknown invocation of that closure.

### Block call timing

Block and higher-order method calls SHOULD be modeled through call-timing and mutation effects instead of a blanket "yield invalidates everything" rule. Useful first categories are:

- no block invocation;
- immediate non-escaping invocation, once or a known bounded number of times;
- immediate non-escaping invocation, unknown number of times;
- deferred or escaping block storage;
- unknown block behavior.

Known Ruby methods such as `tap`, `then`, `yield_self`, and `each_with_object` SHOULD eventually receive summaries for block timing, return behavior, and receiver or argument mutation. Without such a summary, Rigor MAY be conservative for object-content facts, but it SHOULD still preserve unrelated local-binding facts.

### Proof obligations for stronger fact retention

The first implementation can use these proof obligations for stronger fact retention:

- a local binding has not been assigned and is not writable by an escaping closure;
- the value is an immutable singleton or immediate value, such as `nil`, `true`, `false`, a symbol, or an integer;
- the value is proven frozen for the relevant operation;
- the value is freshly allocated, has not escaped, and has not been passed to a call that may mutate or store it;
- a RBS, `RBS::Extended`, or plugin effect declares that the call is read-only, pure for the relevant target, or mutates only specific receivers or arguments.

Plugins MAY return explicit mutation, escape, call-timing, purity, or invalidation effects rather than mutating `Scope` directly. The bundle schema is in [rbs-extended.md](rbs-extended.md).

## Scope snapshots and fact buckets

The first implementation pairs a category-bucketed fact store with immutable per-edge `Scope` snapshots:

- Each `Scope` is an immutable snapshot keyed by control-flow edge. Joins, narrowing, and invalidation produce new snapshots through structural sharing rather than in-place mutation.
- Within a snapshot, facts are partitioned into buckets that mirror the categories above: local-binding, captured-local, object-content, global-storage, dynamic-origin, and relational. Invalidation rules act on a specific bucket, so an unknown method call sweeps object-content while leaving local-binding intact.
- Relational facts that span multiple targets live in their own bucket and are invalidated when any participating target's bucket records a change.
- The public surface of `Scope` MUST NOT expose buckets directly. Plugins, narrowing rules, and diagnostics ask `Scope` for facts about a target; the bucket layout is an internal optimization that MAY evolve.

## Purity policy

The pre-plugin purity policy controls how method-call results are remembered or forgotten across re-invocations:

- Methods are treated as **impure by default**. Calling an impure method on a receiver invalidates the receiver's object-content bucket and discards remembered value facts for prior calls to the same receiver.
- Purity becomes effective only when an authoritative source declares it: core Ruby and stdlib RBS distributed with Rigor, accepted ordinary RBS files, or explicit `rigor:v1:pure` annotations on `RBS::Extended`. Generated signatures and plugin contributions MAY refine purity within their tier.
- A configuration switch makes the default look more like PHPStan's "value-returning is pure unless declared impure" policy for projects that want stronger narrowing across repeated calls. The switch flips the default but never overrides explicit `pure` or mutation declarations.
- `pure` combined with any receiver-mutation, argument-mutation, or fact-invalidation effect is a contract conflict, as specified in [rbs-extended.md](rbs-extended.md).

## Built-in mutation summaries

The first user-visible milestone (v1) ships built-in mutation, purity, and call-timing summaries for a fixed set of core and stdlib classes. The covered set is `Array`, `Hash`, `String`, `Set`, `IO`, `StringIO`, `File`, `Tempfile`, `Pathname`, and `Logger`. Each summary records:

- per-method receiver-mutation status, argument-mutation status, and fact-invalidation effect;
- per-method block call timing using the categories above;
- per-method purity declaration where it can be made without overpromising.

Classes outside this set follow the impure-by-default policy until ordinary RBS, `RBS::Extended`, or plugin facts say otherwise. Rigor MUST NOT silently assume purity or mutation behavior for them.

The v1.1 roadmap extends coverage to additional core classes (`Numeric` and its descendants, `Symbol`, `Range`, `Regexp`, `Proc`, `Method`, `Time`, `Date`, `DateTime`), broadly used stdlib (`Date`, `JSON`, `URI`, `OpenStruct`, `Forwardable`, `Comparable`-bearing classes that need explicit mutation summaries), and selected metaprogramming-adjacent core APIs (`Module`, `Class`, `BasicObject`). Each addition ships behind a feature flag so v1 behavior is not perturbed as the larger surface lands.

Built-in mutation summaries are not a closed list. New entries MAY be added in any minor release as long as their addition does not change the meaning of code that does not call them; the published roadmap is a planning aid, not a contract.

## Pre-plugin narrowing surface

The pre-plugin narrowing surface is the set of facts Rigor produces in heavily `Dynamic[top]` code before any user plugin is loaded.

This specification describes the full pre-plugin surface that the analyzer ultimately supports. The first user-visible product release (v1) is a scoped slice of that surface; it does not redefine the spec. Internal data structures such as fact buckets, the capability-role catalog, and built-in mutation summaries are normative from v1; the *derivation rules* exposed to users are tightened in v1 and broaden in v1.1.

### v1 narrowing surface

- Literal narrowing for `nil`, `true`, `false`, integer and string literals, and finite literal-union refinements produced by equality checks against trusted built-in domains.
- Syntax-level guards: `is_a?`, `kind_of?`, `instance_of?`, `nil?`, truthiness, `respond_to?`, equality with literal sets, and class- or pattern-matching narrowing in `case` and `case/in` forms that do not require dataflow across statements.
- Method-call resolution that uses RBS or `RBS::Extended` for core Ruby and a curated subset of stdlib without requiring user plugins. Generated signatures from `RBS::Extended` MAY participate.
- Direct application of the bundled core/stdlib mutation summaries at call sites where the receiver is statically known. Summaries drive bucket invalidation locally; cross-statement propagation of those effects is a v1.1 surface.

### Deferred to v1.1

- intra-procedural propagation of facts and mutation effects across straight-line code, joins, and loops;
- capability-role *requirement inference* from method bodies (the catalog and explicit `conforms-to` directives are already available; deriving "what role does this body require" is v1.1);
- plugin-supplied flow contributions.

Each v1.1 surface ships behind a feature flag so v1 behavior stays stable while the larger surface lands.

## Diagnostics

Diagnostics that arise from control-flow analysis live primarily in the `flow.*` family. Strict modes that depend on dynamic-origin provenance live in the `dynamic.*` family. Cutoff diagnostics live in `static.*`. The full identifier taxonomy is in [diagnostic-policy.md](diagnostic-policy.md).
