# Diagnostics

When `rigor check` finds a problem it reports a **diagnostic**:
a file, a line and column, a severity, a rule ID, and a
message. This page is the reference for the rule catalogue,
the severity model, and suppression. For the *reasoning*
behind each rule, see
[handbook chapter 8](../handbook/08-understanding-errors.md).

## Rule IDs

Every rule has a two-segment `family.rule` identifier:

| Family | Covers |
| --- | --- |
| `call` | Call sites — undefined methods, arity, argument types, nil receivers. |
| `flow` | Control-flow proofs — always-raises, dead branches, constant conditions. |
| `def` | Method definitions — return types, ivar writes, visibility. |
| `assert` | `assert_type` checks. |
| `dump` | `dump_type` notices. |

`rigor explain <rule>` prints the full catalogue entry for any
built-in rule ID; `rigor explain` with no argument lists them all.

### Catalogue

Each built-in rule has a stable per-rule anchor on this page
(`#rule-<family>-<name>`, dots written as dashes) — the
`documentation_url` field in `--format json` and `rigor explain`'s
`Documentation:` line both point here. The `Evidence` column is
Rigor's confidence that a firing is a true positive (see
[Evidence tier](#evidence-tier) below). The one exception is
`rbs_extended.unsatisfied-conformance`, an `rbs_extended`-family rule
rather than a built-in: `rigor explain` does not resolve it and it
carries no `documentation_url`.

| Rule | Fires when | Evidence |
| --- | --- | --- |
| <a id="rule-call-undefined-method"></a>`call.undefined-method` | The method is not defined on the receiver's statically known class. | high |
| <a id="rule-call-self-undefined-method"></a>`call.self-undefined-method` | An implicit-self call (no receiver) resolves to no method on a confidently-closed standalone class. Ships `:off`; opt in via `severity_overrides`. | low |
| <a id="rule-call-wrong-arity"></a>`call.wrong-arity` | The positional-argument count matches no signature. | high |
| <a id="rule-call-argument-type-mismatch"></a>`call.argument-type-mismatch` | An argument's type provably violates the parameter contract. | high |
| <a id="rule-call-possible-nil-receiver"></a>`call.possible-nil-receiver` | The receiver is `T \| nil` and the method is not defined on `NilClass`. | high |
| <a id="rule-call-unresolved-toplevel"></a>`call.unresolved-toplevel` | A top-level implicit-self call resolves against no same-file `def`, `pre_eval:` patch, or `Kernel` / `Object` method. | low |
| <a id="rule-flow-always-raises"></a>`flow.always-raises` | The expression provably raises on every reachable path. | high |
| <a id="rule-flow-unreachable-branch"></a>`flow.unreachable-branch` | An `if` / `unless` / ternary branch is statically dead. | high |
| <a id="rule-flow-always-truthy-condition"></a>`flow.always-truthy-condition` | A condition is provably always truthy or always falsey. | medium |
| <a id="rule-flow-dead-assignment"></a>`flow.dead-assignment` | A local is written but never read in the same method. | medium |
| <a id="rule-flow-unreachable-clause"></a>`flow.unreachable-clause` | A `case`/`when` or `case`/`in` clause is statically dead — its subject type is disjoint with the pattern, or a prior clause already exhausted the subject. | medium |
| <a id="rule-flow-duplicate-hash-key"></a>`flow.duplicate-hash-key` | A Hash literal repeats a literal key (symbol, plain string, integer, float, `true`/`false`/`nil`) — the last entry silently overwrites the earlier one at runtime. Literal keys only; symbol vs string and `1` vs `1.0` never collide, and interpolated / constant / computed keys are never compared. A `**splat` between two identical literal keys does not rescue the pair. | high |
| <a id="rule-flow-return-in-ensure"></a>`flow.return-in-ensure` | An explicit `return` inside an `ensure` clause — it overrides the method's in-flight return value and silently swallows any in-flight exception. A `return` in a nested `def`, lambda, or `define_method` block inside the `ensure` does not fire (it exits that inner frame). | high |
| <a id="rule-def-return-type-mismatch"></a>`def.return-type-mismatch` | The method body's result violates its declared RBS return type. | medium |
| <a id="rule-def-ivar-write-mismatch"></a>`def.ivar-write-mismatch` | An instance variable is written with a type disagreeing with its first write. | high |
| <a id="rule-def-method-visibility-mismatch"></a>`def.method-visibility-mismatch` | An explicit-receiver call reaches a private method. | high |
| <a id="rule-def-override-visibility-reduced"></a>`def.override-visibility-reduced` | An override reduces the visibility it inherits from a project-defined ancestor. | high |
| <a id="rule-def-override-return-widened"></a>`def.override-return-widened` | An override's declared return type widens the inherited return (covariance). | high |
| <a id="rule-def-override-param-narrowed"></a>`def.override-param-narrowed` | An override narrows an inherited parameter type (contravariance). | high |
| <a id="rule-rbs_extended-unsatisfied-conformance"></a>`rbs_extended.unsatisfied-conformance` | A class declares `%a{rigor:v1:conforms-to _Interface}` in its RBS but is missing a method the interface requires. Presence-based: only definitively-absent required methods fire. | — |
| <a id="rule-assert-type-mismatch"></a>`assert.type-mismatch` | An `assert_type` expectation does not match the inferred type. | high |
| <a id="rule-dump-type"></a>`dump.type` | A `dump_type` call — informational, prints the inferred type. | — |

Plugins may contribute further families and rules; `rigor
explain` lists whatever the active configuration loads.

## Evidence tier

Every rule in the catalogue above carries an **evidence tier** —
Rigor's own confidence that a firing is a *true positive*, derived
from the rule's firing gates. It is orthogonal to severity (impact) and to
the severity profile: the tier never changes whether a diagnostic
surfaces, it only routes attention.

| Tier | Meaning |
| --- | --- |
| `high` | Fires only on a concrete, statically-known type with no metaprogramming escape. Rigor's false-positive discipline has already filtered the uncertain cases, so a firing is almost always a real problem — a consumer can act on it (or a downstream classifier can trust it) without cross-checking another tool. |
| `medium` | Rests on a flow- or inference-level proof that inherits a documented false-positive envelope (loop / mutation / RBS-strictness modelling gaps, narrowed by the rule's *does not fire when* list). Usually right, but not literal-provable. |
| `low` | A resolution- or coverage-gap signal: a firing frequently reflects context the analyzer cannot see (an unanalyzed file, a metaprogramming patch) rather than a definite bug. Treat as "review this" — e.g. route `call.unresolved-toplevel` to a `pre_eval:` decision. |

Informational rules (`dump.type`) carry no tier. The per-rule tier
is the single source of truth in the rule catalogue — read it with
`rigor explain <rule>` or `rigor explain --format json`, and it is
echoed on each diagnostic in `rigor check --format json` (below).

## Severity profiles

Each rule emits with an authored severity, then a **profile**
re-stamps it for the run. Three profiles, set with the
`severity_profile:` config key:

| Profile | Stance |
| --- | --- |
| `lenient` | Only proven diagnostics are errors; uncertain ones drop to `warning` / `info`. For incremental adoption on legacy code. |
| `balanced` *(default)* | Most rules `error`; `dump.type` `info`; uncertain rules `warning`. |
| `strict` | Nearly every rule is an `error` — the exceptions are `call.self-undefined-method` (stays `off`, opt-in only) and `flow.unreachable-clause` (`warning`, pending its false-positive gate). CI-friendly. |

For finer control, `severity_overrides:` maps a rule ID or a
family to one of `error`, `warning`, `info`, or `off`:

```yaml
severity_profile: balanced
severity_overrides:
  flow.always-truthy-condition: off
  call: warning
```

A rule-specific override beats a family override.

## Machine-readable output (`--format json`)

`rigor check --format json` emits the diagnostics as a JSON
document for editors, CI, and AI agents. Each diagnostic is an
object with **stable, structured fields** — so a consumer filters
and groups on them directly and **never parses the human-readable
`message`** (the wording is presentation, not contract, and may be
reworded in a minor release):

| Field | Present | Meaning |
| --- | --- | --- |
| `path` / `line` / `column` | always | Location (1-based line and column). |
| `severity` | always | `error` / `warning` / `info`. |
| `rule` | always (`null` for parse / internal errors) | The `family.rule` ID. |
| `source_family` | always | `builtin`, `rbs_extended`, `generated.*`, or `plugin.<id>`. |
| `message` | always | Human-readable text — *presentation, not contract*. |
| `receiver_type` | when the rule has a receiver | The called receiver's displayed type (`String`, `Array[User]`, …). |
| `method_name` | when the rule has a method | The called / defined method name. |
| `project_definition_site` | `call.undefined-method` monkey-patch case | `path:line` where the project itself defines the method (ADR-17). |
| `evidence_tier` | built-in rules with a tier | `high` / `medium` / `low` — Rigor's confidence the firing is a true positive ([Evidence tier](#evidence-tier)). |
| `documentation_url` | built-in rules | A stable URL to the rule's entry in this catalogue. |

`evidence_tier` lets a consumer prioritise without re-deriving
confidence — e.g. surface only `high` firings in a strict CI gate,
or route `low` firings to a human review queue:

```sh
# only the high-confidence diagnostics
rigor check --format json \
  | jq '[.diagnostics[] | select(.evidence_tier == "high")]'
```

### Coverage block (`--coverage`)

`rigor check --coverage` adds a top-level `coverage` object so a single
run reports both *what fired* and *how much of the analyzed surface
Rigor could type* — useful when a large diagnostic count raises the
question "did it analyze all my files, or only a few?". The block
mirrors the `summary` of `rigor check`'s sibling
[`rigor coverage`](02-cli-reference.md#rigor-coverage) (same
precision-tier vocabulary), plus `scan_files`:

```jsonc
"coverage": {
  "scan_files":            203,
  "parse_errors":          0,
  "expressions_typed":     18394,
  "precise_count":         9847,
  "precise_ratio":         0.535,
  "dynamic_opaque_count":  8547,
  "dynamic_opaque_ratio":  0.465
}
```

It is **off by default** — computing it is a second precision pass over
the analyzed files — so the default check path's cost is unchanged. In
text mode `--coverage` prints a one-line summary instead. For the full
per-file / per-tier breakdown, run `rigor coverage` directly.

The `receiver_type` / `method_name` pair is populated by the
call-family rules and the method-level `def.*` rules. Group a run
by the called class and method with `jq`, no message parsing:

```sh
# every diagnostic that names a method, as {receiver, method, rule}
rigor check --format json \
  | jq '[.diagnostics[] | select(.method_name) | {receiver: .receiver_type, method: .method_name, rule}]'
```

The `check` stream is **faithful per-site** — a literal receiver
reports its literal type (`"hi"`, `42`). For the **aggregated**
view — counts per class/method across the whole run, with literal
receivers folded to their class — use
[`rigor triage`](02-cli-reference.md)'s `selectors` section.

## Suppressing a diagnostic

Three layers, from narrowest to broadest.

**In-source, one line.** A trailing comment suppresses the
named rules on that line:

```ruby
config.merge(extra)  # rigor:disable call.undefined-method
```

It accepts qualified IDs, family wildcards (`call`), a
comma- or space-separated list, or `all`.

**In-source, whole file.** `# rigor:disable-file <rules>`
anywhere in a file suppresses those rules for every line;
`# rigor:disable-file all` silences the file.

**Project-wide.** The `disable:` config key turns rules off
across the whole run:

```yaml
disable:
  - flow.dead-assignment
```

For a *known backlog* you want to keep visible but not fail
on, prefer a [baseline](06-baseline.md) over a blanket
`disable:` — `disable:` also hides any new occurrences.
