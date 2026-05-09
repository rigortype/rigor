# Understanding errors

This chapter is the catalogue of diagnostics Rigor ships, the
families they belong to, and how to suppress one when it is
wrong (or move its severity around).

## Anatomy of a diagnostic

```text
lib/user.rb:42:7: error: undefined method `upcas' for "alice" [call.undefined-method]
                  ↑      ↑                                   ↑
                  │      │                                   └─ qualified rule
                  │      └─ message
                  └─ severity (error / warning / info)
```

The qualified rule (`call.undefined-method`,
`flow.always-raises`, `def.return-type-mismatch`, …) is the
stable identifier for the rule. Use it in:

- `# rigor:disable <rule>` end-of-line suppressions in source
- `# rigor:disable-file <rule>` file-scope suppressions
- `severity_overrides:` in `.rigor.yml`
- `disabled_rules:` in `.rigor.yml`

Wildcards work — `# rigor:disable call` suppresses every
`call.*` rule on that line.

Need to look up what a rule does without leaving the shell?
`rigor explain <rule>` prints the rule's summary, when it
fires, when it doesn't, the suppression token, the authored
severity, and the per-profile severity. `rigor explain` with
no argument prints the index of every shipped rule.

## The rule catalogue

Five families, each with one or more rules:

### `call.*` — call-site rules

Fire when a method call's shape is wrong.

| Rule | Fires when | Default severity |
| --- | --- | --- |
| `call.undefined-method` | The receiver class is statically known and the method is not defined on it (RBS or in-source). | error |
| `call.wrong-arity` | The number of positional arguments does not satisfy any overload's arity. | error |
| `call.argument-type-mismatch` | An argument's type provably does not satisfy the parameter contract (RBS or `RBS::Extended` `param:`). | error |
| `call.possible-nil-receiver` | The receiver type is `T | nil` and the method is not defined on `NilClass`. | warning |

`call.*` rules are the highest-volume diagnostics on
real-world code. They are also the most refined — every one
fires only when Rigor can prove the underlying fact.

### `flow.*` — flow-analysis rules

Fire when the control flow itself is unsound.

| Rule | Fires when | Default severity |
| --- | --- | --- |
| `flow.always-raises` | Every reachable evaluation of an expression raises (e.g. `n / 0` where `n: Integer`). | error |
| `flow.unreachable-branch` | An `if` / `unless` / ternary's predicate is a syntactic literal AND the corresponding dead branch is non-empty. | warning |
| `flow.always-truthy-condition` | The predicate of an `if` / `unless` / ternary is provably truthy (or falsey) by inferred type, with surgical skips inside loop bodies and on defensive predicate calls. | warning |
| `flow.dead-assignment` | A plain local-variable write whose target name is never read in the same `def` body. | warning |

### `def.*` — method-definition rules

Fire when the body of a method violates its declared
contract.

| Rule | Fires when | Default severity |
| --- | --- | --- |
| `def.return-type-mismatch` | The body's last expression's inferred type cannot satisfy the RBS-declared return type. Honors `%a{rigor:v1:return: <refinement>}` overrides. | warning under `balanced` profile, error under `strict` |
| `def.ivar-write-mismatch` | A later `@var = ...` write's concrete class disagrees with the first write's class in the same class body (NilClass-to-clear is allowlisted). | error |
| `def.method-visibility-mismatch` | An explicit-receiver call targets a `Nominal[X]` whose discovered method is `:private` in the surrounding class body. | error |

### `assert.*` — runtime assertion rules

| Rule | Fires when | Default severity |
| --- | --- | --- |
| `assert.type-mismatch` | An `assert_type(value, "expected")` call's actual inferred type does not match the expected string. | error |

### `dump.*` — debug helpers

| Rule | Fires when | Default severity |
| --- | --- | --- |
| `dump.type` | `dump_type(value)` was called — emits an info diagnostic naming the inferred type. | info |

`dump_type` is your introspection probe during debugging:
sprinkle it through suspicious code, run `rigor check`, read
the inferred types from the diagnostic stream.

## Severity profiles

Rigor ships three named severity profiles that re-stamp the
shipped severities:

| Profile | Behaviour |
| --- | --- |
| `lenient` | Most rules → `warning`; uncertain rules drop to `info`. CI-friendly for legacy code. |
| `balanced` (default) | Most rules → `error`; `dump.type` → `info`. The shipped behaviour. |
| `strict` | Everything → `error` including the `:warning` rules under `balanced`. Suitable for new projects with no legacy noise. |

Set in `.rigor.yml`:

```yaml
severity_profile: strict
```

## Per-rule overrides

Override a single rule's severity:

```yaml
severity_overrides:
  call.argument-type-mismatch: warning
  def.return-type-mismatch: off
```

`off` drops the diagnostic from the result entirely — useful
when you want a profile-wide setting for most rules but
silence one specifically.

Family wildcards work in overrides too:

```yaml
severity_overrides:
  call: warning   # demote every call.* rule
  dump: off       # drop every dump.* rule
```

Per-rule entries beat family-wildcard entries:

```yaml
severity_overrides:
  call: warning                    # every call.* → warning
  call.undefined-method: error     # except undefined-method, still error
```

YAML reserves the bareword `off`. If the stripped severity
seems not to apply, quote it: `"off"`. Same for `on`.

## In-source suppression

```ruby
"hello".no_such_method  # rigor:disable call.undefined-method
```

The comment must be on the same line as the diagnostic. Use
the qualified rule, the family wildcard, or `all`:

```ruby
"hello".no_such_method   # rigor:disable call
"hello".no_such_method   # rigor:disable all
```

For multiline blocks, suppress at every line — Rigor does
not yet ship a `disable-block` syntax.

### File-scope suppression

When you need to silence a rule everywhere in a file —
typically a generated file, a fixture, or a vendored snippet
that triggers a known false positive — drop a single
`# rigor:disable-file` comment anywhere in the file:

```ruby
# rigor:disable-file call.undefined-method

# This whole file is generated; the analyzer's call surface
# is mismatched with the runtime layer for these stubs.
```

Convention is to put the comment near the top, but Rigor
scans every comment in the file so any placement works. The
same token forms apply: qualified rule, family wildcard, or
`all`. The line-scope `# rigor:disable` form continues to
work — the two compose, and any project-wide
`disable: [...]` in `.rigor.yml` also still applies.

## Project-wide suppression

```yaml
# .rigor.yml
disabled_rules:
  - call.possible-nil-receiver
```

Drops the rule project-wide. Heavier hammer than
`severity_overrides: { call.possible-nil-receiver: off }` —
both work; the choice is stylistic.

## Baseline diffing for CI

When you adopt Rigor on an existing codebase, you usually
inherit a long tail of legitimate-but-pre-existing diagnostics
that nobody is going to fix today. The pragmatic move is to
**snapshot the current state as a baseline** and then have CI
fail only on *new* diagnostics introduced by a PR:

```sh
# Once: capture the current diagnostic surface.
bundle exec rigor check --format=json > rigor.baseline.json
git add rigor.baseline.json
git commit

# Per PR: compare against the committed baseline.
bundle exec rigor diff rigor.baseline.json
```

`rigor diff` prints `+ NEW` rows for each diagnostic that
wasn't in the baseline and `- FIXED` rows for each that has
been resolved since. The exit code is `1` when any new
diagnostic appears and `0` otherwise — so adding a new
violation fails CI, but the legacy diagnostics recorded in
the baseline don't.

When you fix a row in the baseline, regenerate it with the
same `rigor check --format=json > rigor.baseline.json` so
the project tightens monotonically over time. The
`--format=json` form of `rigor diff` itself is also
available for editor / dashboard integrations.

## Why a diagnostic might NOT fire when you expected one

The most common reasons:

1. **The receiver is `Dynamic[Top]`.** Rigor stays silent on
   gradual receivers. Run `rigor type-of <file>:<line>:<col>`
   to confirm what the engine sees.
2. **The method exists somewhere in the hierarchy.** Even one
   matching def in any ancestor class / module silences
   `call.undefined-method`.
3. **The call is implicit-self inside a method body.** Rigor
   does not flag implicit-self calls — too much noise on
   metaprogramming-heavy code.
4. **The literal might be empty / nil at runtime in a way the
   analyzer cannot prove.** `s = ARGV.first; s.upcase`
   silently passes because `s` could legitimately be a
   non-empty string at runtime, and Rigor will not flag what
   it cannot prove. Add an explicit guard or a `param:`
   tightening.
5. **The target rule is disabled by configuration.** Check
   your `.rigor.yml` and any `# rigor:disable` comments in
   the offending file.
6. **The severity profile dropped it.** Under `lenient`, rules
   that fire as `:warning` may have been further demoted to
   `:info` and filtered out of your CI script.

When in doubt, run with `--explain`:

```sh
bundle exec rigor check --explain lib
```

This adds an `:info` diagnostic for every fail-soft fallback
the engine took — every place it widened to `Dynamic[Top]`
because it could not see further. The output is noisy on
realistic code but invaluable when "I expected a diagnostic
here" debugging.

## Why a diagnostic IS firing when you think it should not

Almost always one of:

1. **Rigor is right.** The classic case: a method's RBS sig
   says `String?` but the project's runtime invariants
   guarantee non-nil. Either fix the sig (preferred), add a
   `RBS::Extended` `return:` directive, or add a `# rigor:disable`
   on the line.
2. **An RBS sig is missing or wrong.** The class lives in a
   gem with no `.rbs`, or the project's own `sig/` is out of
   date with the source. Update or add the sig.
3. **A constant is being looked up wrong.** Constant
   resolution can fall back to RBS-core or in-source class
   discovery; if both miss, the call goes through
   `Dynamic[Top]` and you see no diagnostic, but a sibling
   call against the wrong class might fire.
4. **A diagnostic is genuinely false-positive.** Rare —
   Rigor's design priority is no-false-positives — but
   possible. File an issue with the smallest reproducer you
   can extract.

## A helpful workflow

The pragmatic loop on a project that just adopted Rigor:

1. Run `rigor check lib` once to see the baseline.
2. Skim every diagnostic. Triage as one of:
   a. **Real bug.** Fix the code.
   b. **Missing / wrong RBS.** Update the sig or add a new
      one.
   c. **Genuine noise.** Add `# rigor:disable <rule>` on the
      line, or `disabled_rules:` to `.rigor.yml`.
3. Re-run. Repeat until the diagnostic stream is clean.
4. Add `bundle exec rigor check lib` to CI under the
   `balanced` profile (or stricter).
5. As the project's invariants get more proven, demote
   `# rigor:disable` lines into `RBS::Extended` directives
   so the analyzer learns the real contract.

A clean `rigor check` run is the goal; a green CI badge says
"every diagnostic that fires is one we accept."

## What's next

[Chapter 9 — Plugins](09-plugins.md) is a one-page pointer to
the `examples/` directory. Plugins extend Rigor for
project-specific DSLs (units of measure, route helpers,
deprecations, …). Most projects will never write one; the
chapter exists so you know the option is there.
[Chapter 10 — Coexisting with Sorbet](10-sorbet.md) is for
projects arriving from a Sorbet codebase: the
[`rigor-sorbet`](../../examples/rigor-sorbet/) adapter reads
`sig { ... }` blocks, RBI files, and `T.let` / `T.cast` /
`T.must` / `T.unsafe` assertions as type sources.
