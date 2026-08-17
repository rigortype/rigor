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
| <a id="rule-call-raise-non-exception"></a>`call.raise-non-exception` | A `raise` / `fail` argument's concrete type is provably not an Exception class, an Exception instance, a String, or an object defining `#exception` — a runtime `TypeError`. | high |
| <a id="rule-call-unresolved-toplevel"></a>`call.unresolved-toplevel` | A top-level implicit-self call resolves against no same-file `def`, `pre_eval:` patch, or `Kernel` / `Object` method. | low |
| <a id="rule-flow-always-raises"></a>`flow.always-raises` | The expression provably raises on every reachable path. | high |
| <a id="rule-flow-unreachable-branch"></a>`flow.unreachable-branch` | An `if` / `unless` / ternary branch is statically dead. | high |
| <a id="rule-flow-always-truthy-condition"></a>`flow.always-truthy-condition` | A condition is provably always truthy or always falsey. | medium |
| <a id="rule-flow-dead-assignment"></a>`flow.dead-assignment` | A local is written but never read in the same method. | medium |
| <a id="rule-flow-unreachable-clause"></a>`flow.unreachable-clause` | A `case`/`when` or `case`/`in` clause is statically dead — its subject type is disjoint with the pattern, or a prior clause already exhausted the subject. | medium |
| <a id="rule-flow-duplicate-hash-key"></a>`flow.duplicate-hash-key` | A Hash literal repeats a literal key (symbol, plain string, integer, float, `true`/`false`/`nil`) — the last entry silently overwrites the earlier one at runtime. Literal keys only; symbol vs string and `1` vs `1.0` never collide, and interpolated / constant / computed keys are never compared. A `**splat` between two identical literal keys does not rescue the pair. | high |
| <a id="rule-flow-return-in-ensure"></a>`flow.return-in-ensure` | An explicit `return` inside an `ensure` clause — it overrides the method's in-flight return value and silently swallows any in-flight exception. A `return` in a nested `def`, lambda, or `define_method` block inside the `ensure` does not fire (it exits that inner frame). | high |
| <a id="rule-flow-shadowed-rescue-clause"></a>`flow.shadowed-rescue-clause` | A `rescue` clause can never run because an earlier clause of the same chain already catches a superclass (or the same class) of every exception class it names. | high |
| <a id="rule-def-return-type-mismatch"></a>`def.return-type-mismatch` | The method body's result violates its declared RBS return type. | medium |
| <a id="rule-def-ivar-write-mismatch"></a>`def.ivar-write-mismatch` | An instance variable is written with a type disagreeing with its first write. | high |
| <a id="rule-def-method-visibility-mismatch"></a>`def.method-visibility-mismatch` | An explicit-receiver call reaches a private method. | high |
| <a id="rule-def-override-visibility-reduced"></a>`def.override-visibility-reduced` | An override reduces the visibility it inherits from a project-defined ancestor. | high |
| <a id="rule-def-override-return-widened"></a>`def.override-return-widened` | An override's declared return type widens the inherited return (covariance). | high |
| <a id="rule-def-override-param-narrowed"></a>`def.override-param-narrowed` | An override narrows an inherited parameter type (contravariance). | high |
| <a id="rule-static-value-use-void"></a>`static.value-use.void` | A value recovered from an author-declared `-> void` return is used in value context (an assignment right-hand side, a call receiver, or a call argument). Off by default; reaches a run only through the `use-of-void-value` bleeding-edge feature (ADR-100). A bare-statement `void` call and a legitimate `top` value both stay silent. | high |
| <a id="rule-effect-envelope-exceeded"></a>`effect.envelope-exceeded` | A method performs an effect its declared envelope does not admit — its proven effect labels (its own body plus everything it calls) are not covered by the `%a{pure}` or `%a{rigor:v1:effect …}` bound written on it or on its class. Opt-in twice over: it needs an `effects:` block in `.rigor.yml` and an envelope you wrote. Positioned at the Ruby `def`. Unproven ("and possibly more") effects never fire, and `mutate.local` is tolerated by every envelope. | high |
| <a id="rule-effect-liskov-widened"></a>`effect.liskov-widened` | An override escapes the envelope written on the method it overrides. A `PgRepo` is usable wherever a `Repo` is, so a `%a{rigor:v1:effect io.db}` on `Repo#find` binds `PgRepo#find` too: an implementation may be purer than the bound it inherits, never less pure. Either what the override *does* exceeds the inherited bound, or the envelope the override *declares for itself* is wider than it. Both sides must be authored — nothing fires unless someone wrote an envelope on the ancestor — and only subclassing counts, not `include`. Positioned at the override's `def`. Needs an `effects:` block. | high |
| <a id="rule-effect-unknown-label"></a>`effect.unknown-label` | An effect declaration names a label the registry does not know — a typo in an envelope (`%a{rigor:v1:effect io.bd}`), or a member of `effects.tolerated:`. The whole tag then reads as unbounded, so the declaration quietly stops doing anything; this says so. Positioned at the declaration: the `.rbs` line, the `.rb` line for an rbs-inline annotation, or `.rigor.yml` for a config value. `# rigor:disable` comments are not read out of `.rbs` or `.rigor.yml`, so use `disable:` or the baseline there. Only fires where the spelling is evidently meant to be a label (close to a known one, next to a known one, dotted, or retired) — a word nothing resembles stays silent, because you may be opening your own vocabulary. Needs an `effects:` block. | high |
| <a id="rule-effect-annotations-unchecked"></a>`effect.annotations-unchecked` | Your signatures carry `%a{pure}` / `%a{rigor:v1:effect …}` but `.rigor.yml` has no `effects:` block, so nothing checks them. One `:info` per run, positioned at the first annotation. An annotation never turns effect collection on by itself — that would make one line in one file more expensive for every run — so this is how it tells you instead. Add `effects: {}` to opt in, or `disable:` it to keep the annotations documentary. | — |
| <a id="rule-suppression-unknown-rule"></a>`suppression.unknown-rule` | A `# rigor:disable[-file]` comment names a rule that does not exist (typically a typo), so the suppression silently does nothing. `plugin.`-prefixed tokens are never flagged. | high |
| <a id="rule-suppression-empty"></a>`suppression.empty` | A `# rigor:disable[-file]` comment lists no rules, so it suppresses nothing. | high |
| <a id="rule-suppression-unknown-marker"></a>`suppression.unknown-marker` | A comment uses a suppression marker Rigor does not recognise — typically the RuboCop reflex `# rigor:disable-next-line <rule>` or `# rigor:enable <rule>`. Rigor's only markers are `# rigor:disable <rules>` (suppresses on its own line) and `# rigor:disable-file <rules>`, so the comment suppresses nothing. | high |
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
| `strict` | Nearly every rule is an `error`. The exceptions: `call.self-undefined-method` and `static.value-use.void` stay `off` (both opt-in only), `flow.unreachable-clause` stays `warning` pending its false-positive gate, and the three `suppression.*` rules stay `warning` — a stale suppression comment is worth telling you about, but it is not a reason to fail a build. CI-friendly. |

Under `balanced`, the rules that do **not** emit as `error`
are:

| Severity | Rules |
| --- | --- |
| `warning` | `call.unresolved-toplevel`, `def.ivar-write-mismatch`, `def.return-type-mismatch`, `def.override-visibility-reduced`, `def.override-return-widened`, `def.override-param-narrowed`, `flow.unreachable-branch`, `flow.always-truthy-condition`, `flow.dead-assignment`, `flow.duplicate-hash-key`, `flow.return-in-ensure`, `flow.shadowed-rescue-clause`, `suppression.unknown-rule`, `suppression.empty`, `suppression.unknown-marker`, `effect.envelope-exceeded`, `effect.liskov-widened` |
| `info` | `flow.unreachable-clause`, `dump.type`, `effect.unknown-label`, `effect.annotations-unchecked` |
| `off` | `call.self-undefined-method`, `static.value-use.void` |

Everything else emits as `error`. For one rule under all three
profiles, `rigor explain <rule>` prints `Authored severity:` and
`Severity by profile:` — that output is generated from the rule
catalogue itself, so it is the per-rule source of truth.

For finer control, `severity_overrides:` maps a rule ID or a
family to one of `error`, `warning`, `info`, or `off`:

```yaml
severity_profile: balanced
severity_overrides:
  flow.always-truthy-condition: off
  call: warning
```

A rule-specific override beats a family override. `off` drops
the diagnostic from the result entirely, which makes
`severity_overrides:` the lighter-touch sibling of `disable:`
below — both silence a rule; the override reads as "this one
rule, at this severity" alongside the rest of the profile.

YAML reserves the bareword `off` as a boolean. If an override
that names it seems not to apply, quote it — `"off"` — and the
same for `on`.

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
comma- or space-separated list, or `all`. The comment must sit
on the line the diagnostic points at; there is no
`disable-block` form, so an expression spread over several
lines needs the comment on each line that fires.

The marker has to be the **first thing in the comment** — a
whole-line `# rigor:disable …` or a trailing
`expr  # rigor:disable …`. A comment that merely quotes the
syntax, as this manual does throughout, is ordinary prose: it
suppresses nothing and warns about nothing. The same goes for a
doubled `## rigor:disable …` and for a marker written inside an
`=begin` / `=end` block — neither activates.

A marker that cannot work is flagged rather than silently
ignored: a token that names no known rule (a typo like
`call.undefined-metod`) fires
[`suppression.unknown-rule`](#rule-suppression-unknown-rule),
a bare marker with no rules at all fires
[`suppression.empty`](#rule-suppression-empty), and a marker
word outside Rigor's grammar (the RuboCop reflex
`# rigor:disable-next-line <rule>`, or `# rigor:enable`)
fires
[`suppression.unknown-marker`](#rule-suppression-unknown-marker)
— all `:warning` in every profile. Tokens under the `plugin.`
prefix are never flagged (plugin rule vocabularies load
dynamically), and the surveillance diagnostics are themselves
suppressible like any other rule.

**In-source, whole file.** `# rigor:disable-file <rules>`
anywhere in a file suppresses those rules for every line;
`# rigor:disable-file all` silences the file. Convention is to
put it near the top — typically on a generated file, a fixture,
or a vendored snippet — but every comment in the file is
scanned, so any placement works.

The three layers **compose**: a file-scope marker does not
cancel a line-scope one, and a project-wide `disable:` still
applies to a file that carries neither.

**Project-wide.** The `disable:` config key turns rules off
across the whole run:

```yaml
disable:
  - flow.dead-assignment
```

For a *known backlog* you want to keep visible but not fail
on, prefer a [baseline](06-baseline.md) over a blanket
`disable:` — `disable:` also hides any new occurrences.
