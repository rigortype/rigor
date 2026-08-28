# Understanding errors

A diagnostic is Rigor telling you something it proved about
your code. This chapter is about *reading* one: what its parts
mean, what each rule family is really claiming, why one fires
when you did not expect it, why one stays silent when you did,
and how to work a freshly-adopted project down to a clean run.

The reference lives one door over. The full rule catalogue,
each rule's evidence tier, the severity-profile table, and the
exact syntax of every suppression form are in
[Diagnostics](../manual/04-diagnostics.md) in the manual; this
chapter links there rather than restating it.

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
- `disable:` in `.rigor.yml`

Wildcards work — `# rigor:disable call` suppresses every
`call.*` rule on that line.

Need to look up what a rule does without leaving the shell?
`rigor explain <rule>` prints the rule's summary, when it
fires, when it doesn't, the suppression token, the authored
severity, and the per-profile severity. `rigor explain` with
no argument prints the index of every shipped rule.

### Confidence — reading the evidence tier

Every built-in diagnostic carries an `evidence_tier` —
`high` / `medium` / `low` — which is Rigor's own confidence
that the firing is a *true positive*, derived from the rule's
gates rather than from its severity. It is worth internalising
as a reading habit rather than a config knob: a `high` firing
(`call.undefined-method` on a concrete receiver) is almost
always a real bug and can be acted on directly, while a `low`
one (`call.unresolved-toplevel`) usually means the analyzer is
missing context — an unanalyzed file, a monkey-patch it never
saw — and reads better as "look at this" than "fix this". The
tier never feeds severity, and never changes whether a
diagnostic fires; it only routes your attention.

The per-rule tiers, and the `documentation_url` field that
rides alongside them in `--format json`, are in
[manual — Evidence tier](../manual/04-diagnostics.md#evidence-tier).

## The five families

Every rule ID reads `family.rule`, and the family tells you
what kind of proof failed. The catalogue — every rule, what it
fires on, its evidence tier — is in
[manual — Diagnostics](../manual/04-diagnostics.md#catalogue).
What follows is what each family is *about*.

**`call.*` — the call site's shape is wrong.** An undefined
method, an arity no signature accepts, an argument whose type
provably violates the parameter contract, a receiver that
might be `nil`. These are the highest-volume diagnostics on
real-world code, and also the most refined: every one of them
fires only when Rigor can prove the underlying fact about a
statically-known receiver, which is why a `call.*` firing is
usually worth reading first.

**`flow.*` — the control flow itself is unsound.** Something
provably raises on every path, a branch is dead, a `case`
clause can never match, a local is written and never read, a
Hash literal repeats a key. `flow.unreachable-branch`,
`flow.always-truthy-condition` and `flow.unreachable-clause`
form the **reachability family** — each proves that a piece of
code cannot run. `unreachable-clause` is the newest member and
deliberately quieter than its siblings (`:info` under
`balanced`) while its corpus false-positive gate finishes;
bump it with `severity_overrides:` if you want it louder.

**`def.*` — a definition violates the contract it declares.**
A body whose return drifts from the declared RBS return, an
instance variable written with two disagreeing types, an
explicit-receiver call into a private method. The three
`def.override-*` rules are the Liskov Substitution Principle's
signature rule applied across a project-defined hierarchy
(superclass chain plus included and prepended modules, resolved
cross-file): returns may narrow, parameters may widen,
visibility may not shrink. They are the conceptual subject of
[appendix: Liskov substitution](appendix-liskov.md).

**`assert.*` and `dump.*` — the introspection helpers.**
`assert.type-mismatch` fires when an `assert_type("expected",
value)` call disagrees with the inferred type, so a snippet in
this handbook is a test of the engine as much as an
illustration. `dump.type` is not a problem report at all — it
is your probe during debugging: sprinkle `dump_type(value)`
through suspicious code, run `rigor check`, and read the
inferred types straight out of the diagnostic stream.

## Turning a diagnostic down

Rigor gives you five layers, and picking the right one is
mostly a question of *how much* you want to say:

1. **`severity_profile:`** — the project's overall stance.
   `lenient` for a legacy codebase you are easing Rigor into,
   `balanced` for everyday work, `strict` for a project with
   no legacy noise.
2. **`severity_overrides:`** — one rule (or one family) at a
   different severity from the rest of the profile. The right
   layer when a rule is *useful but not blocking* for you.
3. **`disable:`** — the rule is off project-wide. Heavier than
   an override to `off`; both work, and the choice is mostly
   stylistic.
4. **`# rigor:disable` / `# rigor:disable-file`** — this line,
   or this file. The right layer when the analyzer is wrong
   *here* and right everywhere else. Prefer it to a
   project-wide switch: it keeps the exception visible next to
   the code that needed it, and it is the thing you later
   promote into an `RBS::Extended` directive.
5. **A [baseline](../manual/06-baseline.md)** — the whole
   existing backlog, recorded rather than hidden, so new
   diagnostics still surface. This is the layer to reach for
   on adoption day, and the one to reach for *instead of*
   `disable:` when the rule is genuinely finding things you
   have simply not fixed yet.

The exact syntax of all five — profile table, override
precedence, the three suppression forms, the baseline file and
its `rigor baseline` commands — is in
[manual — Diagnostics](../manual/04-diagnostics.md#severity-profiles)
and [manual — Baselines](../manual/06-baseline.md).

## Why a diagnostic might NOT fire when you expected one

The most common reasons:

1. **The receiver is `Dynamic[top]`.** Rigor stays silent on
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
rigor check --explain lib
```

This adds an `:info` diagnostic for every fail-soft fallback
the engine took — every place it widened to `Dynamic[top]`
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
   `Dynamic[top]` and you see no diagnostic, but a sibling
   call against the wrong class might fire.
4. **A diagnostic is genuinely false-positive.** Rare
   (Rigor's design priority is no-false-positives) but
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
      line, or `disable:` to `.rigor.yml`.
3. Re-run. Repeat until the diagnostic stream is clean.
4. Add `rigor check lib` to CI under the
   `balanced` profile (or stricter).
5. As the project's invariants get more proven, demote
   `# rigor:disable` lines into `RBS::Extended` directives
   so the analyzer learns the real contract.

On a codebase too large for step 2 in one sitting, record the
existing diagnostics as a
[baseline](../manual/06-baseline.md) first and run the loop
against what CI newly surfaces.

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
[`rigor-sorbet`](../../plugins/rigor-sorbet) adapter reads
`sig { ... }` blocks, RBI files, and `T.let` / `T.cast` /
`T.must` / `T.unsafe` assertions as type sources.
