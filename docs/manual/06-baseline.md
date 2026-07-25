# Baselines

A **baseline** records the diagnostics a project already has,
so `rigor check` can stay silent about them and surface only
what is *new*. It is the pragmatic on-ramp for adopting Rigor
on an existing codebase: you do not have to reach zero
diagnostics before the check becomes useful in CI. It is also
what the [`rigor-project-init` skill](08-skills.md) snapshots
for you at onboarding
([ADR-22](../adr/22-baseline-and-project-onboarding.md) is the
design).

## The baseline file

A baseline is a YAML file — `.rigor-baseline.yml` by
convention — listing buckets of known diagnostics:

```yaml
version: 1
ignored:
  - file: app/models/user.rb
    rule: call.undefined-method
    count: 3
  - file: app/lib/legacy.rb
    rule: call.argument-type-mismatch
    count: 1
```

Each row is a **bucket** keyed by `(file, rule)`, with a
`count` of how many diagnostics of that rule the file is
allowed. An optional `message:` field (a regular-expression
source) narrows a bucket to call sites whose message matches.

You do not hand-write this file — `rigor baseline generate`
produces it.

## Turning a baseline on

A baseline file sitting in the project is **dormant** until
something activates it — presence alone does nothing. Activate
it with the config key:

```yaml
baseline: .rigor-baseline.yml
```

or per run with `rigor check --baseline=PATH`. `--no-baseline`
ignores a configured one for a single run, and `baseline:
false` in a config file disables a baseline inherited through
`includes:`.

## All-or-nothing per bucket

When a baseline is active, each bucket is matched whole:

- **current count ≤ recorded count** — every diagnostic in the
  bucket is silenced.
- **current count > recorded count** — every diagnostic in the
  bucket surfaces, not just the excess.

The reasoning: line numbers drift as a file is edited, so a
partial match cannot reliably point at *which* diagnostic is
the new one. Surfacing the whole bucket asks you to review
that rule × file together.

The baseline filter runs **last** — after `# rigor:disable`
comments and the severity profile. A baseline never resurrects
a diagnostic another layer has already suppressed.

## The `rigor baseline` commands

| Command | Use |
| --- | --- |
| `rigor baseline generate` | Write a fresh baseline from the current diagnostics. Refuses to clobber an existing file without `--force`. |
| `rigor baseline regenerate` | Rewrite unconditionally — run it after fixing diagnostics so the file shrinks. |
| `rigor baseline dump` | Print the baseline, filterable with `--rule` and `--file`. |
| `rigor baseline drift` | Show how buckets have moved — `--only=over` for buckets that grew, `reducible` for ones you have already improved past, `cleared` for empty ones. |
| `rigor baseline prune` | Drop buckets that match nothing any more. `--dry-run` previews. |

`generate` and `regenerate` take `--match-mode=rule` (the
default — one bucket per file × rule) or `--match-mode=message`
(a bucket per distinct message: more precise, more churn).

`--match-mode=message` keys each bucket on the **rendered
message text**, which includes details such as the displayed
receiver type. That makes it sharper at telling two same-rule
diagnostics on one line apart, but also **brittle**: when a Rigor
upgrade rewords a message or changes how a type is displayed, the
key no longer matches and the previously-baselined diagnostic
resurfaces as if new. `--match-mode=rule` keys only on
`(file, rule)` and is immune to message rewording — prefer it
unless you specifically need per-message discrimination, and
expect to `regenerate` a `message`-mode baseline after upgrading
Rigor.

## The ad-hoc form — `rigor diff`

A managed baseline is not the only way to fail CI on *new*
diagnostics only. The lightweight alternative keeps a plain JSON
snapshot in the repository and compares against it explicitly:

```sh
# Once: capture the current diagnostic surface.
rigor check --format=json > rigor.baseline.json
git add rigor.baseline.json

# Per PR: compare against the committed snapshot.
rigor diff rigor.baseline.json
```

[`rigor diff`](02-cli-reference.md#rigor-diff) prints a `+ NEW`
row for every diagnostic absent from the snapshot and a
`- FIXED` row for every one resolved since, and exits `1` when
anything is new — so a PR that adds a violation fails while the
recorded legacy ones stay quiet. `--format=json` is available
for editor and dashboard integrations. Regenerate the snapshot
with the same `rigor check --format=json` redirection whenever
you fix a row, and the project tightens monotonically.

The difference from a managed baseline is where the knowledge
lives: `rigor diff` is a separate step your CI script has to
run, while a `baseline:` file makes `rigor check` itself exit
clean on recorded diagnostics. Prefer the managed form unless
you specifically want the raw JSON snapshot.

## Working a baseline down

`rigor triage` summarises a diagnostic stream — rule
distribution, class/method selectors, the files with the most
diagnostics, and heuristic hints about likely causes — so you can
decide what to tackle first:

```sh
rigor triage
```

The `selectors` section (`rigor triage --format json | jq
'.selectors'`) is the best prioritisation signal: a class/method
with a high `count` spread across many `files` is a systemic cause
one fix or a `pre_eval:` entry clears in bulk, while a low-`count`
selector is a candidate genuine bug to fix at the site.

It is advisory and always exits `0`. The intended loop is
`triage` to prioritise → fix or suppress a rule → `rigor
baseline regenerate` to shrink the file. The
[`rigor-baseline-reduce` skill](08-skills.md) walks this loop
interactively.

To make CI fail on *any* baseline drift, add `--baseline-strict`
to `rigor check`. It fails not only when a bucket grows past its
recorded count (excess drift, which the surfaced diagnostics already
fail on) but also when the code has *shrunk* below it (deficit drift:
the baseline is now looser than the code and should be regenerated).
