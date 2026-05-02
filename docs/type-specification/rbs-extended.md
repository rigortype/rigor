# RBS::Extended Annotations

Rigor MAY read Rigor-specific metadata from RBS annotations in `*.rbs` files under the provisional name `RBS::Extended`.

RBS already supports `%a{...}` annotations on declarations, members, and method overloads. `RBS::Extended` is Rigor's name for the convention of attaching Rigor metadata to those annotations under a reserved key namespace; the first version reserves `rigor:v1:<directive>` payloads. Annotations on the same node that use unrelated keys belong to other tools and are not consumed by Rigor. Rigor MUST preserve them unmodified during analysis and erasure.

These annotations let users and plugin authors describe types that exceed standard RBS without changing Ruby application code and without breaking ordinary RBS parsers. Standard RBS tools MUST be able to preserve or ignore these annotations. This follows the same compatibility principle as Python's `Annotated[T, metadata]`: the base type remains meaningful to tools that do not understand the metadata.

## Worked examples

```rbs
%a{rigor:v1:return: non-empty-string}
def read_name: () -> String

%a{rigor:v1:param: value is non-empty-string}
def normalize: (String value) -> String

%a{rigor:v1:assert value is non-empty-string}
def assert_present!: (String value) -> void

%a{rigor:v1:assert-if-true value is "foo"}
%a{rigor:v1:assert-if-false value is ~"foo"}
def check: (untyped value) -> bool
```

The right-hand side of `return:`, `param:`, `assert*`, and `predicate-if-*` accepts either an RBS-style class name (`String`, `::Foo::Bar`) or a kebab-case refinement payload from the imported-built-in catalogue ([`imported-built-in-types.md`](imported-built-in-types.md)). The refinement payload supports the parameterised forms `non-empty-array[Integer]`, `non-empty-hash[Symbol, Integer]`, and `int<min, max>` through `Builtins::ImportedRefinements::Parser`. Class-name directives MAY use `~T` negation; refinement-form directives currently MUST NOT (the difference-against-refinement algebra is reserved for a future slice).

## Authoring rules

- The ordinary RBS signature remains the compatibility contract.
- `RBS::Extended` annotations refine or explain that contract for Rigor.
- Annotation keys use a versioned `rigor:v1:` namespace, for example `rigor:v1:return` or `rigor:v1:predicate-if-true`.
- The annotation key comes first; the remaining text is a Rigor-specific payload.
- Rigor-generated annotations MUST use the explicit `rigor:v1:` prefix. Unversioned `rigor:` directives MUST NOT be emitted and SHOULD be treated as invalid until a compatibility migration need exists.
- The version prefix is part of the directive identity. Rigor v1 reads only `rigor:v1:` directives; an unsupported `rigor:vN:` directive is preserved by RBS tooling but reported by Rigor as unsupported metadata when it is on a node Rigor analyzes.
- Multiple annotations on the same RBS node MUST be interpreted deterministically and independently of source order.
- Exact duplicate annotations are idempotent.
- Compatible annotations compose by directive kind, target, and flow edge. For example, true-edge and false-edge predicate facts on the same parameter are different effect slots.
- Conflicting annotations are diagnostics. Rigor MUST NOT use first-wins or last-wins behavior. A conflict includes incompatible payload syntax, incompatible versions on the same node, two non-identical singleton directives for the same effect slot, contradictory refinements whose intersection is `bot`, and any annotation whose refinement exceeds the ordinary RBS contract.
- Authors SHOULD prefer `T - U` for explicit user-authored difference types and use `~T` primarily for negative facts and compact diagnostic display (see [type-operators.md](type-operators.md)).
- If an annotation conflicts with the RBS signature, Rigor MUST report a diagnostic.
- Exported plain RBS MUST drop or erase Rigor-only annotations unless the user asks to preserve them.
- The annotation grammar is versioned and SHOULD remain small until implementation experience proves it out. Incompatible grammar changes require a new version prefix rather than changing `rigor:v1:` semantics.

## Type predicates and assertions

Rigor models Python `TypeGuard`/`TypeIs`-style predicates, TypeScript-style type guards, and PHPStan-style assertions as **flow effects** attached to RBS method signatures.

### Predicate examples

```rbs
%a{rigor:v1:predicate-if-true value is String}
%a{rigor:v1:predicate-if-false value is ~String}
def string?: (untyped value) -> bool

%a{rigor:v1:predicate-if-true self is LoggedInUser}
def logged_in?: () -> bool
```

### Assertion examples

```rbs
%a{rigor:v1:assert value is String}
def assert_string!: (untyped value) -> void

%a{rigor:v1:assert-if-true value is String}
def valid_string?: (untyped value) -> bool
```

### Directive meanings

| Directive | Effect |
| --- | --- |
| `rigor:v1:return: T` | Overrides the RBS-declared return type with `T` at every call site. |
| `rigor:v1:param: name [is] T` | Tightens the RBS-declared type of parameter `name` to `T`, both at overload selection / argument-type checks AND inside the method body during inference. The `is` glue word is optional. |
| `rigor:v1:predicate-if-true target is T` | Refines `target` to `T` on the **true** branch of a call used as a condition. |
| `rigor:v1:predicate-if-false target is T` | Refines `target` to `T` on the **false** branch. |
| `rigor:v1:assert target is T` | Refines `target` after the method returns normally. |
| `rigor:v1:assert-if-true target is T` | Refines `target` when the method returns a truthy value. |
| `rigor:v1:assert-if-false target is T` | Refines `target` when the method returns `false` or `nil`. |

A true-branch-only predicate is sufficient for Python `TypeGuard`-like behavior. A predicate pair that describes both branches is sufficient for Python `TypeIs`-like behavior. The false branch MAY be written as an explicit negative type when that is clearer:

```rbs
%a{rigor:v1:predicate-if-true value is String}
%a{rigor:v1:predicate-if-false value is ~String}
def string?: (untyped value) -> bool
```

### Target grammar

The initial target grammar is intentionally small:

```text
target ::= parameter-name | self
```

`parameter-name` refers to an RBS method parameter name, not an arbitrary Ruby Symbol. RBS parameter names follow `_var-name_ ::= /[a-z]\w*/`, so predicate targets follow that existing identifier style. The hyphenated words in directives such as `predicate-if-true` live inside the annotation payload and are parsed by Rigor, not as Ruby Symbols.

If a predicate needs to refer to an argument, the RBS method type MUST name that argument:

```rbs
# Good: `value` can be referenced.
%a{rigor:v1:predicate-if-true value is String}
def string?: (untyped value) -> bool

# Not enough information for a predicate target.
def string?: (untyped) -> bool
```

Future versions MAY extend targets to instance variables, record keys, shape paths, and block parameters, but those SHOULD use explicit path syntax rather than overloading the annotation directive name.

## Explicit conformance directive

Implicit structural conformance is the default. Ordinary assignments, parameter passing, and method calls trigger structural compatibility checks against the relevant interface or capability role without requiring author-visible opt-in (see [structural-interfaces-and-object-shapes.md](structural-interfaces-and-object-shapes.md)).

In addition, an explicit conformance directive lets a class declare that it satisfies a structural interface as part of its public contract:

```rbs
%a{rigor:v1:conforms-to _RewindableStream}
class MyBuffer
end
```

The directive instructs Rigor to verify the conformance regardless of whether any current call site exercises that requirement, which is useful for libraries that want their structural contract to be a checked design assertion rather than an emergent property of usage. Multiple `conforms-to` directives on the same class are allowed and combine like an intersection of interfaces. Rigor MUST report a diagnostic when a declared `conforms-to` interface is not satisfied; satisfied directives are silent.

The directive is purely additive. Implicit structural compatibility continues to apply, and a class that already satisfies the interface continues to type-check without the annotation.

## Flow effects and extension contributions

This section is the canonical semantic schema for flow-effect bundles. Extension API documents (ADR-2 and onward) MUST reference this schema when describing how plugins package and return contributions.

The type specification depends on the extension API exposing facts, not direct scope mutation. A plugin or `RBS::Extended` annotation MAY contribute a flow-effect bundle with:

- normal return type;
- truthy-edge facts;
- falsey-edge facts;
- post-return assertion facts;
- exceptional or non-returning effects;
- block call-timing effects;
- escape effects for receivers, arguments, blocks, and captured locals;
- receiver and argument mutation effects;
- fact invalidation effects;
- dynamic reflection members introduced by the call;
- provenance and certainty for the contributed facts and effects.

The analyzer applies these contributions through the same control-flow machinery it uses for built-in guards (see [control-flow-analysis.md](control-flow-analysis.md)). This keeps short-circuiting expressions precise. For example, a plugin-defined predicate used on the left side of `&&` MUST refine the scope used to analyze the right side, and its negative fact MUST flow into the right side of `||`.

### Contribution merging

Contribution merging is deterministic and analyzer-owned:

- Contributions carry **provenance**, including whether they came from core Ruby semantics, an accepted signature or `RBS::Extended` annotation, generated metadata, or a plugin.
- Core Ruby semantics and accepted signature contracts are authoritative. `RBS::Extended`, generated metadata, and plugins MAY refine compatible facts, but they MUST NOT weaken or contradict the ordinary Ruby/RBS contract.
- Compatible facts on the same target, flow edge, and effect kind are composed. Positive type facts intersect, negative facts and relational facts accumulate under their normal budgets, and mutation, escape, and invalidation effects are unioned conservatively.
- Contradictory contributions are diagnostics, not first-wins or last-wins behavior. Rigor SHOULD keep the nearest non-conflicting authoritative fact and ignore or weaken the conflicting contribution for that target and edge.
- Truthy-edge and falsey-edge facts remain edge-local. A plugin MAY contribute one-sided facts, but Rigor MUST NOT infer the opposite edge unless the contribution explicitly provides it or the core analyzer can derive it.
- Dynamic return contributions are checked against the selected signature or default return contract. A plugin MAY narrow a compatible return, but an incompatible return contribution is a conflict diagnostic rather than an override of the contract.
- Repeated `maybe` evidence does not become `yes` merely by count. Certainty changes only when a contribution supplies a stronger proof or the core analyzer can derive one from compatible facts.

### Future targets

Future target grammar SHOULD grow only with clear stability rules. Plausible targets include:

- `self`;
- named parameters;
- local variables visible at the call site;
- receiver members, such as `self.name`;
- instance variables, such as `@name`;
- hash or record keys, such as `config[:mode]`;
- tuple or array elements with literal indexes;
- method-result paths on the same receiver, when the method is known to be pure or stable.

Targets that can be mutated behind the analyzer's back SHOULD either be rejected in annotations, treated as `maybe`, or paired with explicit stability metadata.
