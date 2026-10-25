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

**A target under measurement is exclusive state.** Its `.rigor.yml`, `.rigor/cache` and
`.rigor-effects.yml` live in the target's directory, and `rigor effects update` writes into cwd. Two
agents on one target corrupt each other silently: in August 2026 an agent writing a manual chapter
used the same checkout for real CLI output, wrote its own `.rigor.yml` and deleted `.rigor/cache`
mid-run, so a whole interleaved A/B batch ran cold under both arms and was void. Give every agent that
runs Rigor in a target its own target, measuring or not, or have it `rsync` a private copy first, and
say so in every brief: agents do not know about each other. When a collision is found late, rerun the
batch rather than trust it.

## Corpus before/after diff

To claim "no new firings across the corpus" for an engine change, the SAME engine must analyse each
target twice. Do not use a `git worktree` checkout as the baseline arm: its bundler cannot
materialise gems for that worktree's `Gemfile` path, so every baseline run errors to empty JSON and
reports a bogus `base=0`. Toggle the changed file in the working tree instead — save the HEAD and
changed versions, run all targets on each, diff the diagnostic sets per target, and wrap the whole
thing in a `trap restore EXIT`.

Attribute each delta to a sub-change rather than to the branch. In your own worktree, with the change committed,
set `base=$(git merge-base HEAD origin/master)`, `git checkout "$base" -- <files the sub-change modified>` and `rm
<files it added>`, check that `git diff --stat HEAD` lists exactly that sub-change, re-run only the affected
targets, and restore with `git checkout HEAD -- <files>` under the same `trap … EXIT`. Never `git stash` for this:
the stash stack lives in the `.git` every worktree shares, so a pop can take another session's work. When each
sub-change is its own commit, [`tool/engine_diag_diff.rb`](#diagnostic-differential-across-commits) `--base
<parent> --head <commit>` needs no toggle at all. A new always-falsey or always-truthy cluster under a precision
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

## Diagnostic differential across commits

`tool/engine_diag_diff.rb --base REV --head REV [--corpus REV | --corpus-dir DIR] [--target PATH] [--rule RULE]
[--require-rows-in PATH:N] [--adjudication FILE]` (`--target` repeats; with none, the corpus configuration's `paths:`, falling back to `lib` only when it names none, and the run's first line says which) archives each engine whole (`lib data plugins`), runs each in a fresh process over one corpus,
and prints the diagnostic rows the head removed and added, keyed by path, line, column, rule and message. It exits
non-zero when a removed or added row of `--rule` is not in the adjudication file (a YAML list of `{base, path,
line, column, message, verdict, reason}`, `base` being the merge-base sha the run prints: `fp-silenced` or `tp-lost` for a removed row, `named-mechanism` for an added one,
as ADR-119 WD2 allows a new firing only for a mechanism the change names), when an entry for the current base matches no row (entries for another base are ignored, so a landed change's go
dormant), when an entry sits under a floored path, or when a floor (`--require-base-rows N`,
`--require-rows-in PATH:N`, held in the base and the head) is not met. Both engines run under this checkout's
`Gemfile.lock` and the corpus's configuration, so a dependency or configuration change in the head can make the base
run fail loudly rather than compare. Use it, rather than a flag or an in-tree copy of the old rule, for any "no new firings,
every removal adjudicated" claim: a frozen copy still reads the live scope and tables a change moves, and would
agree with the change by construction. Pass the merge base as `--base`; a survey checkout goes in as `--corpus-dir`.
CI's `Arity differential` job runs it over `spec/integration/fixtures/arity_differential/` and
`spec/integration/fixtures/declaration_witness/` for the `call.wrong-arity` rule (ADR-119 WD2, `SourceArity`'s
decision point) on every PR that changes code, with the floor held by the `survivors/` shapes; the lane-2 corpus run
is the same command with the survey checkouts.

## Typing census across commits

`tool/typing_census.rb --base REV --head REV --corpus-dir DIR [--target PATH]... [--classes REGEX] [--json FILE]` archives
each engine whole, runs each in a fresh process (`rigor check --no-cache --workers 0`) with a module prepended over
`ExpressionTyper#try_user_method_inference`, and prints the (class, method) pairs the base typed at least once and the
head never does, with the typed and untyped call totals of each side. It is ADR-119 WD7(f)'s "census of reads
answering `Dynamic`" for the instance typing site, taken from the engine's own scopes. Run it with `bundle exec`, one
heavy job at a time.

## Probes that lie

- **The run-result cache (ADR-45) serves an unanalyzed result.** A probe reads "No diagnostics" in
  0.2 s and the bug looks fixed. Use `--no-cache` when adjudicating; a suspiciously fast wall time
  is the tell. `coverage --protection` has no cache flag but still reads the target's `.rigor/cache`,
  so clear it between A/B protection runs.
- **`rigor type-of` is not `rigor check`.** It builds an environment without the plugin registry (so
  no rbs-inline source-RBS synthesis), it parses a single file with a single-file scope index (so
  every cross-file declaration reads `Dynamic[top]` — `class Foo` coming back `Dynamic[top]` is the
  tell), and it cannot see discovery-seeded joins (so a both-arms-`Dynamic` A/B proves nothing).
  A cross-file `def` is not merely absent but can be overridden: a `pre_eval:` patch on an ancestor
  types the call even where another file's nearer `def` wins under `check` (#1708).
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

- **Steep reads inline `.rb` annotations only under `check "lib", inline: true`** in the Steepfile.
  Without it every class is `Ruby::UnknownConstant` and a clean run measured nothing; prove binding
  with a control (a body returning `1` under `-> String` must report).

The rule that covers all of them: **when a probe says "no", prove the harness can say "yes" first.**
Pair every silence probe with a control that must fire. A fixture built on an undefined class name
cannot distinguish "correctly declined" from "never analysed" — both read as silence.

## Specs and gates that pass without checking

The same failure inside the suite: a green example that would stay green with the fix removed.

- **Prove a gate by mutating what it protects**, never by reading it; reading shows what the author
  intended. A mutant must live in the tree rspec loads: `spec/spec_helper.rb` puts its own `../lib`
  first, so mutating a copied `lib` and running rspec from another checkout tests the original.
- **A load-time `Dir[]` that generates examples can generate none**, and zero examples is zero
  failures. Assert non-vacuity explicitly, as `spec/docs/plugin_io_boundary_spec.rb` does. A floor
  with slack (`>= 15` of 20) suits only a corpus that grows; on a static one any file can go green.
- **A guard that keeps breaking is usually a bad proxy**, not a missing case. Replace the proxy with
  the real check (`Prism.parse` for "does it parse") rather than adding one rule per spelling.
- **A spec rewrite is verified by comparing payloads**, the sources each example analyses, not
  example names; a `--dry-run` diff pins only the count and numbering.
- **Inline RBS `-> A | B` is a parse error** (`unexpected token for method type`). The run only prints
  the error, so every "no diagnostic" assertion passes. Write `-> (A | B)`
  and pair each "no mismatch" example with a control that must fire under the same signature.
- **A bare `analyze(source)` never widens project discovery**, so census- or seed-dependent
  behaviour answers differently than in a project run (the example is at `RunnerHelpers#analyze`).
  Use `analyze(files: { "code.rb" => source })` for anything the pre-pass seeds.
- **A child Ruby inherits `bundler/setup`.** The suite's `RUBYOPT` and the `gemspec` line in the
  `Gemfile` define `Rigor` in the child before it runs, and clearing a few env vars does not undo it.
  Spawn through `RubyRun.capture` (`spec/support/ruby_run.rb`) or `Bundler.with_unbundled_env`.
- **A decline assertion (`to be_nil`) passes on any construction error**, which also yields nil.
  Pair it with the neighbouring case that must succeed.
- **A failure that passes when its file runs alone is spec order.** Rerun the pair with `--order
  defined` to find the spec that polluted shared state; v0.4.3's `lens_spec` failed only after a spec
  that required the plugin directly, which left the plugin loader's gem-to-id memo unrecorded.

## Shell commands that answer wrong silently

These hold for any shell work, not only measurement; `AGENTS.md` points here. The command runs and its
output looks right, but it acted on the wrong input or measured the wrong thing.

- **When the agent shell is zsh** (`$ZSH_VERSION` is set):
  - an unquoted `$VAR` does not word-split, so `for f in $FILES` iterates once and `rspec $FILES` gets
    one argument; use an array or `${=VAR}`;
  - `${PIPESTATUS[0]}` is empty (zsh's is `$pipestatus`, 1-based); run the guarded command unpiped and
    test `$?`;
  - `"$B:lib/path"` applies the `:l` modifier and eats a letter; write `"${B}:lib/path"`;
  - an unquoted glob in an argument (`--include=*_spec.rb`) aborts with `no matches found`, so
    `files=$(…)` comes back empty and a later `rspec $files` runs the whole suite; quote globs meant for
    the tool and guard `[ -n "$files" ]` before a targeted run;
  - `echo ===` fails; quote it;
  - a multi-line snippet written for bash runs as written only under `bash -c` or from a script file.
- **`cmd | grep -q` under `pipefail` reports no match on large inputs**: grep exits at the first match,
  the producer dies of SIGPIPE (141), and the pipeline fails. Use `grep … >/dev/null` or `grep -c` so
  grep drains its input (#2150 hit this in `verify-changed`).
- **`rg -r` is `--replace`**, not recursive: `rg -rn PATTERN` rewrites every match to the literal `n`.
  rg is recursive by default.
- **An unquoted heredoc runs every backtick span** in the script as a command, so a Python or Ruby
  edit whose strings hold Markdown code is mangled before it runs. Quote it (`<<'EOF'`) and pass values
  through the environment.
- **`timeout N` must wrap the command inside `--command`**; wrapping `nix develop` itself lets the
  shell setup eat the budget.
- Inside the Flake, `sed` is GNU sed: [`parallel-lanes.md`](parallel-lanes.md) § "Mutation table".

`gh` traps are in [`contribution-flow.md`](contribution-flow.md) § "GitHub and git traps".

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
  RSS of THIS process, read on first use: straight after the analysis, before any `--coverage` scan or
  output (#1529) — and `Runner::PoolCoordinator` analyses every slice
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
- **An engine A/B already exists.** `tool/engine_alloc_ab.rb --base REV --head REV|WORKTREE` runs two engines
  over one frozen corpus (the base's tree by default), each in a fresh process with a load-path proof, and prints
  the allocation delta; CI runs it on every engine PR as the advisory "Engine allocations" job. Reach for it
  before building arms by hand, and pass the merge base as `--base`: `origin/master` charges a branch with every
  engine change merged since it was cut. For a question it cannot answer (another corpus, a CPU profile), build
  arms as it does: `git archive` each engine's `lib data plugins`, and run from the repository root so the
  bundle resolves.
- **Wall is decided on CI Linux, not here.** The "Engine wall A/B" workflow (`engine-wall.yml`,
  `tool/engine_wall_ab.rb`) alternates two engines in ABBA order off this host and reports whether their
  ranges separate beyond chance: two runs per arm separate a third of the time with no difference at all, so
  the verdict needs five per arm. `bench/README.md` has the dispatch line. A local wall A/B is a smoke test.
- **Warm and incremental latency has its own harness.** `tool/engine_warm_ab.rb`, dispatched on Mastodon by
  `engine-warm.yml`, times null, leaf-edit and hub-edit runs for the default cache and `--incremental`. It checks
  that each edit run was a miss and each incremental run warm, and compares each warm answer with a plain
  `--no-cache` run. Two traps it was built around: `--incremental --no-cache` is a cold full analysis that neither
  reads nor writes the incremental snapshot or the run-result slot (#1525), so it is a valid oracle for a warm run
  but says nothing about warm latency; and `--verify-incremental`'s "N/M files re-analyzed" is a fixed half
  of the tree, not an edit's closure (#1526). For the same reason a plain `--verify-incremental` OK proves
  nothing about invalidation edges (#1967): it replays no edit. Only a warm-against-cold comparison after an
  edit does — a session spec that edits between baseline and recheck, or `--verify-incremental-edits=N`, which
  replays exactly two edits per sampled file (emptied, and reduced to its class/module skeleton) and so covers
  only edges a removal fires; an edge that only an addition or a body-changing edit exercises is not tested, such
  as #2161's `module_function :two` to `private :two` swap behind a `visibility:` read (#2277).
  On `lib` (607 files) each sampled file costs about 95–105 s. The cold tools (`bench-perf`, the A/Bs) all pass `--no-cache` and
  say nothing about a warm run.
- **In a CPU profile, prefer vernier to stackprof.** stackprof's `:cpu` mode charges samples taken inside a long C
  call (Prism's parse) to the next interrupt check. During #1507 that made `IO.read` read as ~460 ms and
  `File.realpath` as ~200 ms of a run; timed directly, reading every file took 11 ms and the 922 realpath calls
  22 ms.
- **Size a lever against the whole run before calling it one.** A phase that gets 30% faster is worth 30%
  of that phase's share of the run. During #1507 the declaration-walk merge (#1197) cut the table build by
  26–46% per slice and was prioritised as the wall lever. The next four walkers measured were worth about
  0.2% of a cold `rigor check lib`, and warm null runs never reach them. Put the saving against the command's
  end-to-end wall, from a profile of the journey the user runs, before ranking it.
- **Coverage ratios compare only within one instrument and one kind.** #535 changed the precision
  lens's seed, so a ratio from before it does not compare with one after; precision (type quality of
  expressions) and protection (receiver concreteness at dispatch sites) never compare with each other.
- **Keep the instrument.** A note in `docs/notes/` records the numbers, not the harness that produced
  them — the positive control, the trap-clearing flags, the classifier. Push the instrumented build
  as its own branch and name it in the note's limitations section; a follow-up question against the
  same subsystem is the normal case, not the exception.

### Attributing an allocation delta

- **`ObjectSpace.each_object` tracing misses `T_IMEMO`.** Run each arm in-process with GC disabled
  and diff `ObjectSpace.count_objects` and `ObjectSpace.count_imemo_objects` around
  `Rigor::CLI.new(["check", "--no-cache", "--workers=0", ...]).run`. Paired `imemo_ifunc` and
  `imemo_memo` growth means a C-implemented Enumerable method taking a block on a hot path.
- **Hot-path idioms that allocate.** `reduce`/`inject` with a block (not with a Symbol) allocates even over an empty
  Array (guard with `empty?` or use `each`); `when *CONST` copies the array on every evaluation; a
  `return` out of a `rigor_each_child` block allocates once per frame it unwinds, which goes
  quadratic when a caller re-asks the scan at every level (write `found ||= scan?(child)` instead). A
  docstring's "allocation-free" holds only if `GC.stat(:total_allocated_objects)` says so on a deep
  synthetic input.
- **A zero diagnostic diff does not mean the change did nothing.** A change to overload or facet
  selection can flip hundreds of picks that never reach a diagnostic: count the flips with an
  ENV-gated log in `OverloadSelector` or `FacetDistribution` on a copy of the arm. For sig-gen and
  effect-summary changes, diff `rigor sig-gen --format=json` and `rigor effects --full --format json`
  per arm instead of `check` diagnostics. The host Ruby defaults to US-ASCII, so read sweep JSON with
  `encoding: "UTF-8"`.
