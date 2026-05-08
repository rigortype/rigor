# ADR-8: Steep-inspired Improvements

## Status

Accepted (working decisions). Companion to the Rigor self-analysis
report (informal) and the v0.0.5 Steep cross-check triage at
[`docs/notes/20260503-steep-cross-check-triage.md`](../notes/20260503-steep-cross-check-triage.md).
Captures the implementation choices for three Steep-inspired
improvements: a diagnostic-ID family hierarchy, severity profiles,
and a `return-type-mismatch` rule family.

## Context

Running Steep 2.0 over `lib/` (per `make steep-check`) surfaced
three structural gaps Rigor's diagnostic surface has compared to
Steep's:

1. Steep's diagnostic IDs are two-segment (`Ruby::MethodParameterMismatch`,
   `RBS::DuplicatedMethodDefinition`); Rigor's are single-segment
   (`undefined-method`, `wrong-arity`). The flat namespace makes
   it harder to target families of related diagnostics
   (e.g. "all call-site rules") via `# rigor:disable` or
   configuration.
2. Steep ships built-in severity profiles (`Steep::Diagnostic::Ruby.lenient`,
   `.strict`); Rigor only supports per-rule on/off via
   `.rigor.yml`'s `disable:` list. CI-vs-development severity
   tuning is awkward as a result.
3. Steep emits `Ruby::MethodBodyTypeMismatch` when a method body's
   inferred return type cannot satisfy the declared return type.
   Rigor has the substrate (slice 4 `FlowContribution::Merger`,
   B1 per-method Reflection cache) but no rule yet — the dual of
   `argument-type-mismatch` on the return side.

This ADR records the chosen direction for each improvement so
the implementation lands without re-opening the surface design.

## Decisions

### 1. Diagnostic ID family hierarchy

**Decision: rule identifiers are normalised to `family.rule-name`
form**, where `family` is one of a small fixed set of
`[a-z][a-z0-9_]*` segments.

Family prefixes:

| family | Rules |
| --- | --- |
| `call`   | `call.undefined-method`, `call.wrong-arity`, `call.argument-type-mismatch`, `call.possible-nil-receiver` |
| `assert` | `assert.type-mismatch` (test-harness assertion), `dump.type` (debug) |
| `flow`   | `flow.always-raises` (proves a flow path ends in raise), `flow.unreachable-branch` (literal-predicate dead branch) |
| `def`    | `def.return-type-mismatch` (slice #1 below), `def.method-visibility-mismatch` (private-method receiver check), `def.ivar-write-mismatch` (per-class ivar concrete-class drift) |

`dump.type` lives under its own `dump` family rather than
`assert.dump-type` because the runtime semantics differ (assertion
fails the run; dump always succeeds with diagnostic side-effect).

**Backward compatibility.** Existing `# rigor:disable
undefined-method` and `disable: ["undefined-method"]` keep working
in v0.1.x. The configuration / suppression layer accepts both:

- `<rule>` (unprefixed, legacy form).
- `<family>.<rule>` (new canonical form).
- `<family>` (wildcard — disables every rule whose identifier
  starts with `<family>.`).

The unprefixed form resolves through a fixed alias table in
`Analysis::CheckRules`. Removing the alias table is a future ADR
once user code has migrated.

**Diagnostic surface.** `Diagnostic#rule` exposes the
canonical (`family.rule-name`) form. `Diagnostic#qualified_rule`
already prefixes with `source_family` when non-default; the
combined form is `<source_family>.<family>.<rule>` for
`source_family ∉ {:builtin}`. `Diagnostic#to_s` keeps the
existing `[<qualified-rule>]` rendering.

### 2. Severity profile

**Decision: introduce three named profiles** — `lenient`,
`balanced` (default), `strict`. Each profile is a fixed table
mapping `family.rule-name` to `:error` / `:warning` / `:info` /
`:off`.

| Profile | Behaviour |
| --- | --- |
| `lenient` | Only `:no`-class diagnostics are errors. `:maybe`-class diagnostics are `:warning`. Useful for incremental adoption on legacy code. |
| `balanced` (**default**) | Current Rigor stance: most rules `:error`; `dump.type` `:info`; uncertain rules `:warning`. |
| `strict` | Every rule (including `flow.*` proof failures) is `:error`. CI-friendly. |

The profile is a **final filter**: rules emit `Diagnostic` rows
with their authored severity; `Analysis::Runner` re-stamps each
diagnostic's severity from the profile before adding it to the
result. Rules do not consult the profile directly.

`.rigor.yml` adds two keys:

```yaml
severity_profile: balanced     # one of lenient | balanced | strict
severity_overrides:
  call.argument-type-mismatch: warning
```

`severity_overrides` is the per-rule escape hatch — the table
matches by canonical rule id (or family wildcard). Unknown rule
ids in `severity_overrides` are silently skipped; per-run drift
is caught by the public-API drift spec instead.

### 3. `def.return-type-mismatch` rule

**Decision: emit a diagnostic when the inferred return type of a
method body cannot satisfy the declared RBS return type.**

Scope (v0.1.x first cut):

- The method has an explicit RBS sig (instance or singleton)
  reachable through `Rigor::Reflection`.
- The method body's last evaluated expression's type is computable
  from `Inference::ExpressionTyper` (no `Dynamic[top]` fallback).
- The comparison is `declared.accepts(inferred)`:
  - `:yes` — silent.
  - `:no` — emit `:error` with rule `def.return-type-mismatch`.
  - `:maybe` — silent in the v0.1.x first cut. Implementation
    discipline: dogfooding revealed 16 warnings on Rigor's own
    `lib/`, all from the same set of analyzer-precision gaps
    (`{}` not recovering its declared element type, `Set.new`
    returning bare `Set` rather than `Set[Symbol]`, …) that the
    body's inferred type does not yet pin precisely enough.
    Lifting `:maybe` to `:warning` (and `:error` under
    `severity_profile: strict`) is queued for a follow-up that
    lands together with the narrowing precision improvements
    those cases require.

Out of scope for the first cut:

- Methods without RBS sigs (no declared contract to compare against).
- Multiple-return-paths analysis. The first cut takes the body's
  last expression as the proxy for the inferred return; explicit
  `return` mid-body, branching returns, `raise` exits, and
  `next`/`break` paths fall through unchanged for now.
- Block return types. Future work on top of `IteratorDispatch` /
  `BlockFolding`.
- Method overloads — the rule consults the method's `method_types`
  array and considers the union of all declared return types as
  the comparison target.

Rationale: this matches Steep's `Ruby::MethodBodyTypeMismatch`
scope. ADR-5 (robustness principle) requires "strict on returns";
this rule is the first concrete consumer of that policy.

### 4. Out-of-scope items (recorded for posterity)

The Steep-inspired list also flagged:

- **LSP / langserver mode.** Defer to v0.1.x or beyond. Cache
  layer is now ready (B1 per-method cache + the Steep-driven
  rescue tightening), but the mode itself needs a separate
  design pass.
- **Detailed text formatter.** Optional `--format=detailed` with
  source-snippet rendering. Defer; default text format keeps the
  single-line layout for grep / count compatibility.
- **`Data.define` override-aware initializer dispatch.** Out of
  this ADR; CURRENT_WORK already tracks it as a parallel-safe
  entry point.

## Consequences

### Positive

- Diagnostic-family wildcards make `# rigor:disable call` and
  per-family CI gating cleanly expressible.
- Severity profiles unblock the strict-CI / lenient-development
  pattern that Steep users routinely employ.
- `def.return-type-mismatch` closes the symmetric gap between
  the existing `argument-type-mismatch` (parameters) and the
  return side, fulfilling ADR-5's "strict on returns" promise.

### Negative

- Existing `# rigor:disable undefined-method` comments and
  `disable:` config entries in user code use the unprefixed form;
  the alias table absorbs the migration but the coexistence of
  two spellings increases the surface plugin authors and
  formatters must understand. The plan is to remove the alias
  table in a future ADR once the canonical form is widely
  adopted.
- Severity profile re-stamping changes the `Diagnostic#severity`
  observed by downstream consumers (formatters, JSON output).
  CI parsers that depend on a specific severity should pin the
  profile.
- The first cut of `def.return-type-mismatch` is conservative.
  False positives are minimised by skipping `Dynamic[top]`
  bodies, but real-world code with branchy returns may surface
  cases the v0.1.x cut does not handle. Plan: collect those as
  follow-up tickets.

## References

- [Steep cross-check triage 2026-05-03](../notes/20260503-steep-cross-check-triage.md)
- [ADR-5: Robustness principle](5-robustness-principle.md)
- [ADR-7: v0.1.0 slice 4 – 6 working decisions](7-v0.1.0-slice-decisions.md)
- [`docs/internal-spec/inference-engine.md`](../internal-spec/inference-engine.md)
- [`docs/internal-spec/flow-contribution-merger.md`](../internal-spec/flow-contribution-merger.md)
