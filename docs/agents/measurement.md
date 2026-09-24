# Measuring Rigor

Read this when a task measures something: running the engine against an external project, comparing
diagnostics before and after a change, benchmarking, or probing what the engine inferred. It is the
conditional detail pointed to by `AGENTS.md`.

The recurring failure in all of it is a **confident wrong answer** rather than an error, so each
section below is written around the mechanism that produces one.

## Running against a survey project

Validation targets live under `~/repo/ruby/rigor-survey/` as separate repositories analysed *as
data* — the engine is never added to their `Gemfile`. Onboarding one follows the
[`rigor-project-init`](../../skills/rigor-project-init/SKILL.md) workflow.

Two things make the invocation non-obvious. The engine and its native `rbs`/`prism` gems resolve
only inside this repo's Flake shell and bundle, so the call always goes through `bundle exec`; and
baseline paths and config discovery are both cwd-based, so cwd must be the *target*. Running from
the Rigor repo instead writes `../rigor-survey/...` into `.rigor-baseline.yml`, those paths never
match the diagnostic stream, and the baseline silently suppresses nothing.

```sh
nix develop --command bash -c '
  cd ~/repo/ruby/rigor-survey/<project> &&
  BUNDLE_GEMFILE=<rigor>/Gemfile bundle exec <rigor>/exe/rigor <subcommand>'
```

From a worktree, substitute the worktree in all three places once its `vendor/bundle` exists.

## Corpus before/after diff

To claim "no new firings across the corpus" for an engine change, the SAME engine must analyse each
target twice. Do not use a `git worktree` checkout as the baseline arm: its bundler cannot
materialise gems for that worktree's `Gemfile` path, so every baseline run errors to empty JSON and
reports a bogus `base=0`. Toggle the changed file in the working tree instead — save the HEAD and
changed versions, run all targets on each, diff the diagnostic sets per target, and wrap the whole
thing in a `trap restore EXIT`.

Attribute each delta to a sub-change rather than to the branch: `git stash -- <files-of-one-sub-change>`
and re-run only the affected targets. A new always-falsey or always-truthy cluster under a precision
change usually means a **stale-fold family upstream**, not a defect in the change — find or file the
family before blaming the lever.

**Know what the sweep does not exercise.** `signature_paths` defaults to `nil`, which means
auto-discovery: a target's `sig/` loads whether or not the config names it, so adding
`signature_paths: [sig]` changes nothing. Only a handful of the survey targets ship a `sig/` at all,
so "zero new diagnostics across the corpus" is close to vacuous for any change gated on a
*project-declared* ancestor. Such a change needs a targeted fixture that forces the condition.

A spec that cannot reproduce a corpus fold is a pin, not a regression catcher — some folds need the
target's full class context. Say so, and let the corpus run with its exact command and counts be the
evidence rather than faking discrimination with a fixture that cannot fail.

## Probes that lie

- **The run-result cache (ADR-45) serves an unanalyzed result.** A probe reads "No diagnostics" in
  0.2 s and the bug looks fixed. Use `--no-cache` when adjudicating; a suspiciously fast wall time
  is the tell. `coverage --protection` has no cache flag but still reads the target's `.rigor/cache`,
  so clear it between A/B protection runs.
- **`rigor type-of` is not `rigor check`.** It builds an environment without the plugin registry (so
  no rbs-inline source-RBS synthesis), it parses a single file with a single-file scope index (so
  every cross-file declaration reads `Dynamic[top]` — `class Foo` coming back `Dynamic[top]` is the
  tell), and it cannot see discovery-seeded joins (so a both-arms-`Dynamic` A/B proves nothing).
  Attribute check-path behaviour with `check --no-cache --workers=0` plus a same-file positive
  control.
- **`check` does not load stdlib RBS the project never required**, so `Time.now` is `Dynamic` under
  `check` while `type-of` resolves it to `Time`; a control built on `Time` exercises the decline path
  instead of the one you meant.
- **A literal-built collection folds to a shape carrier.** `["a", "b"].map { … }` is a tuple, so
  `.first` resolves through shape dispatch and never reaches the RBS overload under test — use a
  genuine nominal source when the tier under test is RBS dispatch.
- **`BUNDLE_PATH` is the relative `vendor/bundle`**, so a Flake command with cwd outside the repo
  falls back to host gems and dies on a native-extension mismatch. `BUNDLE_GEMFILE` does not fix it.
- **`rigor check` is only an oracle for the tree it was loaded from.** `exe/rigor` puts the `lib/`
  beside it first on the load path, so the path you typed picks the engine, not the branch you are
  on: `<main clone>/exe/rigor` run from a worktree analyses `master`, and a bare `rigor` outside
  `bundle exec` runs whatever release is installed on the host. Neither errors, and every one of them
  prints the same `--version`. A spec-style `Analysis::Runner` harness in the worktree and a CLI
  resolved this way then disagree on exactly the behaviour the branch changes, and "the CLI is silent
  where the harness fires, even with `--no-cache`" reads as an engine or worker-pool gap. It is not
  one: a same-tree `Runner`, `check --no-cache --workers=0` and `--workers=2` report the same
  diagnostics (#1029's fixtures, cold and warm). Before diffing the two, prove they share a tree —
  `bundle exec ruby -e 'require "rigor/cli"; puts $LOADED_FEATURES.grep(%r{rigor/cli\.rb$})'` under
  the same `BUNDLE_GEMFILE` — or add a control call that only the branch answers.

The rule that covers all of them: **when a probe says "no", prove the harness can say "yes" first.**
Pair every silence probe with a control that must fire. A fixture built on an undefined class name
cannot distinguish "correctly declined" from "never analysed" — both read as silence.

## Controls, benchmarks and the instrument

- **Search for a prior measurement before publishing one.** `docs/notes/` and the
  [`rigor-prior-art`](../../.claude/skills/rigor-prior-art/SKILL.md) skill answer "have we measured
  this before?", and reconciling against an existing number is what distinguishes a finding from an
  artifact. Name the commits that could even explain a delta.
- **Non-overlapping ranges are not a control.** `max(off) < min(on)` shows the reps separated under
  whatever conditions prevailed; it cannot tell a real effect from a host artifact that was steady
  across the batch.
- **A phased A/B confounds phase with treatment.** "Run every project on one arm, then switch and run
  them all again" has reported a 45 % regression that did not exist; re-running the same code with
  the arms alternated rep by rep, each with its own cache directory, showed a 34 % improvement. The
  phase boundary and the treatment are perfectly confounded in the phased shape, and the correct
  form costs only a few extra file copies.
- **A cost harness needs a zero-work guard more than it needs precision.** A config's relative
  `paths:` resolve against the config file's own directory, so variant configs written to a tmpdir
  analysed nothing, finished in 0.18 s and reported an improvement. Both arms must analyse a positive
  and identical file count, or the run aborts.
- **Wall time is noise; allocations are the signal.** Running heavy projects back to back throttles
  later ones. A perf hypothesis is decided by the deterministic allocation delta plus held
  diagnostic counts.
- **Allocations do not see retention, and the reported `Memory peak` sees it only in a sequential
  run.** A memo that never frees what it caches is invisible on the allocation axis: bounding
  `ExpressionTyper#class_graph_buckets` to one slot dropped 28.7 MB of held heap and moved `lib`
  allocations by −368 objects, i.e. nothing. The two RSS readings to hand are worse than merely
  noisy. `RunStats.peak_rss_bytes` has no `/proc` on macOS and falls back to `ps -o rss=` — CURRENT
  RSS of THIS process when the stats are built — and `Runner::PoolCoordinator` analyses every slice
  in a forked child, so under `--workers=N` the figure cannot see a worker's retention at all: the
  same A/B that separates cleanly at the default `parallel.workers: 0` reported ~257 MB on both arms
  at `--workers=4`. `tool/bench.rb`'s `peak_rss_kb` is `nil` off Linux, so a local `make bench-perf`
  gates wall and allocations while the Linux CI run also gates RSS (`rss_pct` in
  `bench/thresholds.yml`). Decide a retention hypothesis on what the run still HOLDS instead:
  analyse in-process with `--workers=0`, then `GC.start(full_mark: true, immediate_sweep: true)` a
  few times and read `GC.stat(:heap_live_slots)` and `ObjectSpace.memsize_of_all`
  (`require "objspace"`). Those two hold to a few hundred slots and 0.2 MB across reps — two orders
  of magnitude inside the effect — where the reported `Memory peak` spans ~7 % per arm and needs
  most of a dozen alternated reps to separate 5 %. A retention change also wants its own spec: the
  answers stay correct and only the residue differs, so no diagnostic assertion can fail. Pin the
  storage shape (`spec/rigor/inference/class_graph_memo_slot_spec.rb`) and check the spec fails
  against the unbounded arm before trusting it.
- **Keep the instrument.** A note in `docs/notes/` records the numbers, not the harness that produced
  them — the positive control, the trap-clearing flags, the classifier. Push the instrumented build
  as its own branch and name it in the note's limitations section; a follow-up question against the
  same subsystem is the normal case, not the exception.
