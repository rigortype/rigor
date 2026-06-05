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
ID; `rigor explain` with no argument lists them all.

### Catalogue

| Rule | Fires when |
| --- | --- |
| `call.undefined-method` | The method is not defined on the receiver's statically known class. |
| `call.self-undefined-method` | An implicit-self call (no receiver) resolves to no method on a confidently-closed standalone class. Ships `:off`; opt in via `severity_overrides`. |
| `call.wrong-arity` | The positional-argument count matches no signature. |
| `call.argument-type-mismatch` | An argument's type provably violates the parameter contract. |
| `call.possible-nil-receiver` | The receiver is `T \| nil` and the method is not defined on `NilClass`. |
| `call.unresolved-toplevel` | A top-level implicit-self call resolves against no same-file `def`, `pre_eval:` patch, or `Kernel` / `Object` method. |
| `flow.always-raises` | The expression provably raises on every reachable path. |
| `flow.unreachable-branch` | An `if` / `unless` / ternary branch is statically dead. |
| `flow.always-truthy-condition` | A condition is provably always truthy or always falsey. |
| `flow.dead-assignment` | A local is written but never read in the same method. |
| `def.return-type-mismatch` | The method body's result violates its declared RBS return type. |
| `def.ivar-write-mismatch` | An instance variable is written with a type disagreeing with its first write. |
| `def.method-visibility-mismatch` | An explicit-receiver call reaches a private method. |
| `def.override-visibility-reduced` | An override reduces the visibility it inherits from a project-defined ancestor. |
| `def.override-return-widened` | An override's declared return type widens the inherited return (covariance). |
| `def.override-param-narrowed` | An override narrows an inherited parameter type (contravariance). |
| `rbs_extended.unsatisfied-conformance` | A class declares `%a{rigor:v1:conforms-to _Interface}` in its RBS but is missing a method the interface requires. Presence-based: only definitively-absent required methods fire. |
| `assert.type-mismatch` | An `assert_type` expectation does not match the inferred type. |
| `dump.type` | A `dump_type` call — informational, prints the inferred type. |

Plugins may contribute further families and rules; `rigor
explain` lists whatever the active configuration loads.

## Severity profiles

Each rule emits with an authored severity, then a **profile**
re-stamps it for the run. Three profiles, set with the
`severity_profile:` config key:

| Profile | Stance |
| --- | --- |
| `lenient` | Only proven diagnostics are errors; uncertain ones drop to `warning` / `info`. For incremental adoption on legacy code. |
| `balanced` *(default)* | Most rules `error`; `dump.type` `info`; uncertain rules `warning`. |
| `strict` | Every rule is an `error`. CI-friendly. |

For finer control, `severity_overrides:` maps a rule ID or a
family to one of `error`, `warning`, `info`, or `off`:

```yaml
severity_profile: balanced
severity_overrides:
  flow.always-truthy-condition: off
  call: warning
```

A rule-specific override beats a family override.

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
