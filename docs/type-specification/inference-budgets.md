# Inference Budgets and User-Supplied Boundaries

Rigor MUST stop inference before hard cases become global searches. Recursive methods, mutually recursive call graphs, overloaded operators, dynamic dispatch, large unions, and unconstrained structural inference all need explicit budgets. When a budget is exceeded, Rigor MUST produce an incomplete-inference result with a reason instead of silently inventing precision.

This document defines the budget categories, defaults, configuration, and the boundary-contract rule for user-supplied cutoffs. Cutoff diagnostics live in the `static.*` family (see [diagnostic-policy.md](diagnostic-policy.md)).

## Motivating example

Operator-heavy recursive code is the motivating case:

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

Without a parameter or return contract, `<=` and `-` are too polymorphic to infer a unique domain by enumerating every Ruby class that implements them. The recursive calls also make return inference fan out. Rigor MUST detect this shape early and ask for a boundary rather than expanding the search.

## Boundary contracts

Accepted signature contracts are inference cutoffs. A simple return annotation such as `#: Integer`, a full inline `# @rbs` method type, a generated stub, or an external `.rbs` declaration all let callers use the declared return and stop recursive return inference at the method boundary. The implementation body is still checked against the contract.

This boundary is especially valuable for deep, recursive, or expensive methods. It prevents analysis from fanning out into the method body when the author has already supplied the return contract.

A `bot` return contract means the call never returns normally. Callers MUST treat it as `bot` for reachability and dead-code analysis. If implementation analysis finds a normal return path, Rigor MUST report a diagnostic against the method body, regardless of whether the `bot` came from inline `#: bot`, `# @rbs`, generated RBS, or external `.rbs`.

Implementation-side checking is independent of where the contract came from. See [overview.md](overview.md) for the inline-annotation policy that backs this rule.

## CLI behavior

CLI behavior MUST have two modes:

- **Non-interactive mode** reports an incomplete-inference diagnostic, the reason for stopping, and one or more compatible ways to add a boundary contract.
- **Interactive mode** MAY prompt the user for a boundary type, such as an rbs-inline return `#: Integer`, a full method signature, or an external RBS entry. Rigor MUST only write or modify files after explicit user confirmation.

The prompt SHOULD prefer small, ecosystem-compatible annotations. For return-only recursive cutoffs, `#: Integer` MAY be enough. When receiver or operator parameter domains are also unconstrained, Rigor MAY ask for a full method type such as `(Integer x, Integer y, Integer z) -> Integer` or suggest adding the contract in `.rbs`.

If no boundary is supplied, callers MUST NOT receive a fabricated precise type. Rigor MAY use `Dynamic[top]`, `top`, or another conservative incomplete-inference marker internally, but diagnostics and exports MUST preserve the fact that inference stopped.

The interactive prompt surface is target behavior, not a current scaffold feature. The non-interactive cutoff path is normative from v1.

## Budget table

Every budget category is configurable through `.rigor.yml` under `budgets:`, and the analyzer MUST enforce a healthy range for each entry. Values outside the accepted range produce a configuration diagnostic and the analyzer falls back to the default for that key.

| Key | Category | Default | Range |
|---|---|---|---|
| `recursion_depth` | Recursion depth | 5 | 1–32 |
| `call_graph_width` | Call-graph expansion | 16 | 1–256 |
| `overload_candidates` | Overload candidate count | 8 | 1–64 |
| `operator_ambiguity` | Operator ambiguity per call | 4 | 1–32 |
| `union_size` | Union size for joined returns | 24 | 4–256 |
| `structural_growth` | Structural requirement growth | 16 | 1–256 |
| `interface_candidates` | Named-interface candidate matches | 8 | 1–64 |
| `hash_erasure_keys` | Hash-shape literal-key union | 16 | 1–256 |
| `hash_erasure_values` | Hash-shape literal-value union | 8 | 1–256 |
| `negative_fact_display` | Retained negative-fact display | 3 | 0–32 |

The `hash_erasure_values` default is intentionally smaller than `hash_erasure_keys`: hash keys carry more identifier-like meaning than values do, so retaining wider key unions is more useful in diagnostics and erasure than retaining wide value unions. See [rbs-erasure.md](rbs-erasure.md) for how the budgets shape the erased type.

The `negative_fact_display` budget controls the omission contract documented in [type-operators.md](type-operators.md).

## Cutoff categories

The initial budget categories are explicit so cutoffs are predictable:

- **Recursion depth** on the same method or mutually recursive cluster.
- **Call-graph expansion width** when a body fans out into many callees without contracts.
- **Overload candidate count** for argument-sensitive dispatch.
- **Operator ambiguity per call** when an operator like `<=` or `-` accepts many receiver types.
- **Union size** for joined inferred returns.
- **Structural requirement growth** when a capability summary keeps acquiring new members.
- **Named-interface candidate matches**, used when role inference looks for matching named interfaces (see [structural-interfaces-and-object-shapes.md](structural-interfaces-and-object-shapes.md)).

Each budget produces an incomplete-inference result with a reason rather than a fabricated precise type. This keeps the inference compatible with the "no Rigor-specific inline type syntax in Ruby code" goal: the user resolves the cutoff with an accepted RBS-shaped contract, not with a Rigor-only DSL.
