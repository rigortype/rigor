# ADR-5: Robustness Principle for Rigor Types

## Status

Draft.

ADR-5 records the design rationale for adopting Postel's law — *be conservative in what you produce, be liberal in what you accept* — as a guiding principle for Rigor's type catalog and inferred signatures. The companion normative document is [`docs/type-specification/robustness-principle.md`](../type-specification/robustness-principle.md). When the two documents diverge in observable behavior, the specification binds and ADR-5 should be amended.

ADR-5 is a refinement of ADR-1 (type model and RBS-superset strategy) and ADR-3 (internal type representation). It does not introduce new carriers; it tunes how the existing carriers are chosen at the two boundaries every Rigor type crosses: returns and parameters.

## Context

Rigor's value to a user is the product of two things: the precision of the type it computes and the friction it introduces at call sites. The two compete:

- A **strict** signature on a return position propagates more useful facts downstream. `Integer#abs` typed as `non-negative-int` lets the next `if abs > 0` narrow precisely; the same method typed as `Integer` collapses every downstream comparison to `false | true`.
- A **lenient** signature on a parameter position avoids forcing callers to manufacture conversions, defensive copies, or wrapper coercions just to satisfy a type checker that demands the exact shape. A method that requires `String` but accepts `_ToStr` in practice should declare `_ToStr` so callers do not paste `.to_s` everywhere.

Rigor already infers types more precisely than RBS can express (for example `IntegerRange[1, 10]`, `Tuple[Constant<Integer>, ...]`, `HashShape{name: "Alice", age: 30}`). The stricter the inferred return is, the more useful work the inference engine does for the user. Conversely, parameter positions sit at user-controlled call sites where the analyzer cannot rewrite the callers — over-strict parameter types create noise that callers paper over with redundant conversions.

This ADR makes the asymmetry explicit so future catalog work (numeric, string, array, hash, …) and future inference rules consistently bias the same way at every signature boundary.

## Goals

- Document the asymmetry as a normative principle rather than a case-by-case judgement call.
- Constrain catalog authors and inference-rule authors to the same standard so the catalog stays coherent as it grows.
- Give users a single mental model for "why does Rigor's return type look more specific than RBS says it is" and "why didn't Rigor narrow the parameter to the form I happened to pass".
- Preserve every existing RBS interoperability rule. Rigor MUST NOT widen returns or narrow parameters in ways that break the RBS round-trip.

## Non-Goals

- Making parameter checking permissive in the sense of accepting unrelated types. The principle does not weaken safety; it favors structural / capability-rooted parameter contracts over nominal-only ones, and a precise return facet over an RBS-widened one.
- Mandating that every inferred return type be a refinement. Rigor's existing carriers (`Constant`, `IntegerRange`, `Tuple`, `HashShape`, `Union`) ARE the precision tools; the principle does not introduce new ones.
- Changing the lattice operations (subtyping, gradual consistency, narrowing). Those rules are in [ADR-1](1-types.md) and the specification under `docs/type-specification/`.

## Working Decision

Adopt Postel's law as the default asymmetric design rule for Rigor types:

1. **Returns SHOULD be the most precise carrier the analyzer can prove.** When a built-in catalog entry, an inferred user-method body, or an RBS::Extended annotation can express a stricter return without false positives, prefer it over the RBS-declared shape.
2. **Parameters SHOULD be the most permissive carrier the analyzer can correctness-justify.** When a parameter contract can be satisfied by a structural interface, a capability role, or a wider union without weakening safety at the call site, prefer it over a nominal-only spelling.

Both clauses are SHOULD, not MUST: correctness ALWAYS trumps the principle. A return type Rigor cannot prove without compromising soundness MUST NOT be tightened just to satisfy clause 1; a parameter type that is genuinely required to be a specific class MUST NOT be widened just to satisfy clause 2.

The principle is observed at three places:

- **Built-in catalog generation** (`tool/extract_builtin_catalog.rb`): per-method `purity` and effect facets gate which methods participate in folds; the resulting return type is the most precise lattice value the fold can prove. Catalog parameter widening (clause 2) is delegated to the underlying RBS signature: catalog entries only override the *return* tier; parameter typing remains RBS's responsibility unless an `RBS::Extended` annotation overrides it.
- **User-method inference**: the analyzer re-types a user method's body at the call site with the call's argument types bound to the parameters. The inferred return is the precise lattice value of the body; the inferred parameter contract is whatever the callers actually pass (a union of the call-site types). When the user has supplied an RBS signature, the signature binds in both directions — clause 1 and clause 2 apply to *new* signatures, not to override existing ones.
- **RBS::Extended annotation authorship**: when an annotation carries a tighter return facet (`%a{rigor:v1:return-refinement: …}`) it is preferred over the RBS-declared return; when an annotation carries a looser parameter facet (a capability-role or `_ToS` interface in place of a nominal `String`), it is preferred over the RBS-declared parameter.

## Rationale

### Strict returns make precision propagate

Rigor's inference engine threads carriers through call chains. Every place the engine can substitute `Integer` with `IntegerRange[1, 10]`, the next predicate, comparison, or arithmetic node sees a more useful answer:

```ruby
n = items.size                # non-negative-int (not Integer)
if n > 0
  middle = n / 2              # non-negative-int / Constant[2] -> non-negative-int
  ...
end
```

If `Array#size` had been declared as `Integer`, neither `n > 0` nor `n / 2` would benefit from the bound. The downstream loss compounds: every comparison, every loop bound, every `if size.zero?` that depends on the receiver-side fact loses precision. A single strict return replaces dozens of redundant downstream defensive checks.

PHPStan's experience is the same: literal-typed returns (`array{name: string, age: int}`) flow through the codebase and surface exact errors at the consumer site rather than at the boundary.

### Lenient parameters avoid coercion noise

Conversely, an over-strict parameter type at a public boundary creates a tax on every caller. If a method declared `def render(content: String)` rejects `String | nil` callers — even when the method internally guards against nil — the callers are forced to write `render(content || "")`. The workaround multiplies across the codebase, hides intent, and creates a maintenance burden as the wrapper expression drifts from the caller's actual semantics.

The right tool is a structural interface or a capability role: `_ToStr`, `_ConvertibleToString`, or simply `String | nil` if the method handles nil. The analyzer's job at the call site is to verify that the argument *can be used* by the method, not that it carries a particular nominal carrier.

This is not the same as lowering safety. The method's body still has to be correct under the wider parameter type — and Rigor's narrowing tier is exactly the mechanism that lets the body recover the precise type it needs:

```ruby
def render(content)              # parameter: String | nil
  return "" if content.nil?      # narrowed to String inside the body
  content.upcase                 # safe: receiver is String here
end
```

### Avoiding the workaround-multiplication anti-pattern

A common failure mode in over-strict static analysis: a single false positive at a parameter boundary leads users to copy-paste a workaround at every call site (`x.to_s`, `x || default`, `T.cast(x, U)`). The workarounds then become load-bearing — removing them later is hard because nobody remembers which one was a real conversion and which was a placeholder. The principle's clause 2 prevents this anti-pattern by erring toward parameter widening at design time rather than coercion-by-paper-cuts at call sites.

### Boundary case: the RBS round-trip

The principle does not change the RBS round-trip rules from ADR-1:

- RBS → Rigor remains lossless. A user-supplied RBS signature binds; Rigor MUST NOT widen its parameters or strict-narrow its returns just to apply this principle.
- Rigor → RBS remains conservatively erasing. A precise inferred return MAY erase to a wider RBS form when exporting; the principle does not force tighter exports.

The principle therefore only sets the *default* the analyzer reaches for when it has authorship of the signature: in built-in catalog entries, in inferred user-method types when no RBS signature is present, and in `RBS::Extended` payloads. RBS authorship that already exists is respected.

### Platform-host correctness wins over precision

Clause 1 directs the analyzer toward the strictest correctness-preserving carrier. "Correctness-preserving" includes preserving the answer the user's *deployment target* would observe — not just the analyzer host's answer.

Path-manipulation methods on `File` (`basename`, `dirname`, `extname`, `join`, `split`, `absolute_path?`) read `File::SEPARATOR` / `File::ALT_SEPARATOR` and produce different answers on Windows vs POSIX hosts:

```
File.basename("a\\b.rb")       # "a\\b.rb" on POSIX, "b.rb" on Windows
File.absolute_path?("/foo")    # true on POSIX, false on Windows (no drive letter)
```

The Ruby process running the analyzer hosts ONE platform. Folding to a `Constant<String>` would silently bake the analyzer-host's answer into the inferred type and mis-report it on a host with a different separator policy. Clause 1's "as strict as proven" therefore EXCLUDES platform-specific Constants by default — the platform-agnostic envelope (`Nominal[String]` / `Tuple[Nominal[String], Nominal[String]]` / `bool`) is the strictest *correctness-preserving* result.

Single-platform projects (most internal tooling, Rails apps deployed to Linux containers, scripts that only run on developer machines) opt in via configuration:

```
# .rigor.yml
fold_platform_specific_paths: true
```

The opt-in trades platform-portability for the precision payoff. The default refuses the trade so the analyzer is safe to use on any host without producing answers the deployment target will not see.

The future `non-empty-string` refinement carrier (see [imported-built-in-types.md](../type-specification/imported-built-in-types.md)) will tighten the path-method returns *without* leaking platform specifics: `File.basename(p)` of a non-empty path is always non-empty regardless of separator. Today the carrier is documented but not yet implemented; the platform-agnostic default lands at `Nominal[String]` until that infrastructure exists.

### Correctness still wins

When clause 1 and correctness conflict, correctness wins. Examples:

- `Integer#==(Object) -> bool` MUST NOT be tightened to `Constant[true]` even when the analyzer can fold a specific call to `5 == 5`. The signature describes the method's contract for *all* callers; the fold tightens *the call site* via `ConstantFolding` instead.
- `Array#each` MUST NOT advertise its block-return type as the array's element type — the block runs for side effect, the return is the receiver itself. Strict-returning what the C body actually returns is the principle's ask, not strict-returning the most-specific facet imaginable.

When clause 2 and correctness conflict, correctness wins. Examples:

- `Integer#bit_length() -> non_negative_int` MUST NOT widen its receiver to `Numeric` — `bit_length` is genuinely Integer-only. Widening to `Numeric` would let `1.5.bit_length` type-check and fail at runtime.
- A method that mutates `self.@data` cannot widen its receiver to a structural interface that lacks the `@data` slot.

The principle directs the *default* choice when several correctness-preserving options exist. It is not a license to weaken correctness in either direction.

## Implementation Notes

The principle is observable in the existing codebase:

- `MethodDispatcher::ShapeDispatch` returns `non_negative_int` for `Array#size`, `String#length`, `Hash#size`, `Range#size`, and `Set#size` even though the RBS-declared return is `Integer` — clause 1.
- `MethodDispatcher::IteratorDispatch` types `5.times { |i| ... }`'s block parameter as `int<0, 4>` rather than `Integer`, propagating the precise iteration domain into the body — clause 1.
- `ConstantFolding` widens cartesian Union folds to `IntegerRange[min, max]` rather than returning `nil` when the deduped result exceeds `UNION_FOLD_OUTPUT_LIMIT` — clause 1 (precision-preserving graceful degradation).
- `Type::IntegerRange` accepts `Constant[n]` and narrower `IntegerRange` values without forcing callers to widen to `Integer` first — clause 2.
- The future capability-role catalog (`_ReadableStream`, `_RewindableStream`, …) and the structural-shape rules in `docs/type-specification/structural-interfaces-and-object-shapes.md` are the dedicated tools for clause 2 at user-defined method boundaries.

## Open Questions

- Should the diagnostic surface report a *suggestion* when a user-supplied parameter is nominally typed but every call site passes a structural-interface-compatible value? This would be a clause-2 advisory rather than an error.
- How should the principle interact with `RBS::Extended` capability-role conformance (`%a{rigor:v1:conforms-to: _Frobbable}`)? Conformance annotations are clause-2 enabling tools; the open question is whether the analyzer should auto-generate them when inferring a user method's parameter type.
- Should the catalog generator emit *both* the strict-return inferred form and the RBS-declared return so consumers can see the precision delta? Today only the inferred form is recorded.

These are deferred for v0.1.0+ and tracked alongside the related slices.

## Related ADRs

- [ADR-1: Type Model and RBS Superset Strategy](1-types.md) — establishes the RBS round-trip rules ADR-5 refines.
- [ADR-3: Internal Type Representation](3-type-representation.md) — defines the carriers (`Constant`, `Nominal`, `Union`, `Tuple`, `HashShape`, `IntegerRange`) that ADR-5 picks between.
- [ADR-4: Type Inference Engine](4-type-inference-engine.md) — the engine that observes the principle when inferring user-method types.
