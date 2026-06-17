# Type-protection coverage

Most quality metrics tell you how *much* of something you have:
lines covered, expressions typed. They rarely answer the question
that matters most: **if I introduce a bug, would anything catch
it?**

Rigor's type-protection coverage answers that by measuring your
**types and your tests as one safety net**. A call site is safe
when *either* the type checker would reject a wrong call *or* a
test would go red, and it is unguarded only when **neither**
would. That union is the picture this command draws, with the
cheaper missing half named at every gap.

## Precision is not protection

`rigor coverage` on its own reports **type precision** — the
fraction of expressions Rigor gives a precise (non-`Dynamic`)
type:

```sh
rigor coverage [paths]
```

That tells you how much Rigor is inferring, which is useful, but
precision is not protection. A precisely-typed expression you
never call the wrong way buys you nothing; an untyped one a test
hammers is safe. To measure *protection* (would a bug be caught)
add `--protection`. It comes in three tiers, cheapest first.

## Tier 1 — could a bug be caught here? (static, instant)

```sh
rigor coverage --protection [paths]
```

Tier 1 classifies every **dispatch site** (a method call with a
receiver) by whether the receiver has a concrete type — a site
where Rigor's rules *can* catch a wrong method or argument. It is
one analysis pass, fast enough to run interactively and in CI, and
a **sound upper bound**: a concrete receiver is necessary for a
diagnostic to fire, but not sufficient.

The report leads with the protected ratio, then a ranked **"add a
type here"** list — the methods most often called on a `Dynamic`
receiver, where a type annotation would buy the most catching
power. `--threshold=RATIO` turns it into a CI gate (exit `1`
below the ratio) and `--format=json` carries the structured
fields.

This is the everyday number. When you want the truth behind it,
move to Tier 2.

## Tier 2 — would a bug *actually* be caught? (mutation)

```sh
rigor coverage --protection --mutation [paths]
```

Tier 1 says a site *can* be protected; Tier 2 proves whether it
*is*. It introduces type-visible breakages at each site — dropping
a call-argument to `nil`, swapping its type, renaming a call to a
missing method — re-analyses the mutated code, and reports how many
Rigor **catches** (the kill rate). A breakage Rigor misses is a
real "add a type here" site, surfaced with no guesswork.

It runs many analyses, so it defaults to the **git-changed** `.rb`
files (pass explicit paths to widen — whole-project is minutes) and
is an opt-in CI deep-dive, not an interactive check. The framing is
always *effectiveness / where to add a type*, never "your code is
broken": a surviving breakage at a `Dynamic` site is a place
the type net does not reach.

What *does* reach it is your tests.

## The fused view — types **and** tests (`--with-tests`)

```sh
rigor coverage --protection --mutation --with-tests \
  --test-command "bundle exec rspec" [paths]
```

This is the heart of the feature. For every breakage the type
checker does **not** catch, Rigor runs your test suite and asks
whether a **test** catches it. Each dispatch site lands in one of
three buckets:

| Classification | Meaning |
| --- | --- |
| **type-protected** | the type checker would reject the bug |
| **test-protected** | the types miss it, but a test goes red |
| **unprotected** | neither — a real, unguarded dispatch site |

The report names the **cheaper missing axis** at every gap: a
`Dynamic`-receiver hole says *add a type*; a typed-but-untested
hole says *add a test*. A site is reported unprotected only when
**both** halves miss, which is where the real risk lives, and what
no types-only or tests-only tool can show you.

Cost stays proportional to the hole. A breakage the type checker
already kills **never reaches the suite** (a gradual short-circuit),
so the expensive test runs are spent only where the static net has
a gap. The honest headline becomes *"of the bugs my types let
through, how many do my tests catch?"*

`--format=json` carries `mode` (`protection-fused`), `type_killed`,
`test_killed`, `unprotected`, `protected_ratio`, per-file rows, and
`add_protection_here`; `--threshold` gates on the fused ratio.

### The test-command hook

`--test-command=CMD` is how Rigor runs your suite (default
`bundle exec rake`). Two things to know:

- **The suite must pass on clean code first**, or "a breakage
  survived" would be meaningless — the run aborts with a clear
  message. Point the command at a plain pass/fail runner; a
  coverage floor that exits non-zero on an otherwise-green
  single-file run will trip this.
- **The command runs without a shell** (it is split into an argv
  and executed directly), and Rigor strips its own Bundler
  environment so a `bundle exec` command resolves *your* project's
  bundle. So no `env` wrapper is needed — but shell constructs,
  including an inline `BUNDLE_GEMFILE=… ` prefix, are not
  interpreted. For a non-default Gemfile, use
  `bundle config set --local gemfile PATH` or wrap the command in
  `bash -c '…'`.

## `--include-dynamic` — covering your untyped code

By default the fused view only mutates sites Rigor can type-check.
But on dynamic Ruby that is the minority — the receiver of most
calls is `Dynamic`, and there a **test is the only possible
protection**. `--include-dynamic` mutates those sites too:

```sh
rigor coverage --protection --mutation --with-tests --include-dynamic \
  --test-command "bundle exec rspec" --limit 40 [paths]
```

This completes the map to *every* dispatch site, not just the
typed ones, and is where the fused view earns its keep — it shows
which of your untyped code is held up by tests and which is held up
by nothing. Because every such site is, by definition, something
the type checker cannot catch, it runs the suite far more, so it is
an explicit opt-in.

`--limit=N` (with `--seed=N`) caps the measurement to a
deterministic sample of `N` mutations per file, bounding the cost
on large files; per-file ratios then become estimates, noted on
stderr so `--format=json` stdout stays clean.

## Reading the report — the "add a type **or** a test here" list

The unprotected sites are the payload. In practice they fall into
a few recognisable kinds, each with a natural fix:

- **An untested method body** — a helper the suite never exercises.
  *Add a test*, or widen the test command to cover it.
- **An unreached branch** — an error path (`raise` in a `rescue`),
  a version-dispatch arm. *Add a test* for that branch, if it
  matters.
- **A `Dynamic`-receiver collaborator** — a call on an external
  gem object, a framework facade, a duck-typed parameter, or a
  metaprogramming DSL. *Add a type* — often a one-liner from
  [`rigor sig-gen`](02-cli-reference.md#rigor-sig-gen) — so the
  static net starts catching it.

A note on completeness: when `--test-command` is scoped to a
*subset* of your tests, the report over-reports `unprotected` (a
breakage a *different* test would catch shows as a gap). For an
accurate map, run the command over all tests that exercise the
files you are measuring — trading time for completeness.

## Cost and scope

The fused tiers run real analyses and real test suites, so treat
them as a deep-dive, not a per-keystroke check:

- **Scope tight.** The changed-files default (no paths given) keeps
  a run proportional to a diff; pass explicit paths to widen
  deliberately.
- **Keep the suite fast.** Cost is `(breakages measured) ×
  (suite runtime)`. A fast, well-scoped test command is the biggest
  lever.
- **Cap with `--limit`** on `--include-dynamic` or large files.

## In CI

Tier 1 (`--protection`) is cheap enough to gate every run; the
mutation and fused tiers are better as a scheduled or
label-triggered deep-dive. All tiers honour `--threshold` (a fused-
or effectiveness-ratio gate) and `--format=json`, so wiring them
into a pipeline reuses the same machinery as `rigor check`. See
[Running Rigor in CI](11-ci.md).

## See also

- [CLI command reference](02-cli-reference.md#rigor-coverage) —
  the full flag list for `rigor coverage`.
- [Inspecting inferred types](05-inspecting-types.md) — when a
  receiver is `Dynamic` and you want to know why.
- [Provided skills](08-skills.md) — the agent skills that turn an
  "add a type here" list into annotations.
