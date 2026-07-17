---
name: rigor-regression-sweep
description: |
  Run a multi-version baseline-drift regression sweep of Rigor against a real OSS Ruby project — baseline at one tag, then `rigor check` every later tag against that frozen baseline + frozen config, and tabulate how the surfaced-diagnostic ("error increase") count evolves. Use to validate how realistic Rigor's diagnostics and the `rigor-project-init` workflow are over a normal development flow, and to grow an empirical multi-project corpus. Triggers: "sweep Rigor across versions of X", "check error increase over a release line", "validate the baseline against real churn", "regression-sweep this project".
metadata:
  internal: true
---

# Rigor Regression Sweep

A contributor workflow for measuring **how Rigor's diagnostics
behave over a real project's development flow**. Pick an OSS Ruby
project, baseline it at one version, then run `rigor check` against
every later tag with that baseline + config **frozen**. The
per-tag *surfaced* diagnostic count is the "error increase" a team
adopting Rigor in acknowledge mode would have seen.

It validates two things at once: the **baseline mechanism**
(ADR-22) and the realism of the **`rigor-project-init`** acknowledge-
mode environment — and grows an empirical corpus under
`docs/notes/`.

First worked run: [`docs/notes/20260521-mastodon-v4.5-regression-sweep.md`](../../../docs/notes/20260521-mastodon-v4.5-regression-sweep.md)
(Mastodon, 16 tags `v4.5.0-beta.1` → `v4.5.10`).

## Phase 0 — When to use

Trigger when asked to "sweep Rigor across versions of X", "check how
the error count grows over a release line", "validate the baseline
against real churn", or to add a project to the regression corpus.

Do NOT use for: a single-version check of one project (just run
`rigor check`); authoring a plugin (`rigor-plugin-author`); the
22-library single-snapshot survey style of
[`docs/notes/20260519-oss-library-survey.md`](../../../docs/notes/20260519-oss-library-survey.md)
(that is breadth; this is depth-over-time for one project).

## Phase 1 — Pick the target and the tag range

Choose a real OSS Ruby project with git tags.

**The sampling decision is the single most important one** — and it
governs *what the sweep can prove*.

Released tags are a **post-spec-gate population**. A mature project's
CI catches obvious errors before merge, and genuine bugs are fixed
before a tag is cut. So a sweep over *released tags* — whether a
patch series or a feature-spanning minor/major range — measures:

- **baseline stability** — does ordinary maintenance churn produce
  false regressions? (a real, valuable question), and
- **standing diagnostics** — does newly-added released code carry
  diagnostics the baseline did not already cover?

It does **not** measure Rigor's **bug-detection** power.
`surfaced = 0` over released tags is the *expected* result for a
healthy project, not a Rigor weakness: the bugs Rigor would catch
are the same class the project's specs already caught and removed
before the tag existed. (Confirmed by the Mastodon v4.5.x run —
flat at 0 across 16 tags.)

To actually test bug-detection, sample where **unfixed bugs still
exist** — finer than release tags:

- **per-commit** on `main` between two releases (or a window of it);
- **PR-head commits** (pre-merge state);
- **bug-introducing commits** — for a fixed set of known bug fixes,
  sweep the commit *before* each fix and check whether Rigor
  surfaced the defect.

Pick the sampling to match the question:

| Question | Sample |
| --- | --- |
| Does maintenance churn cause false regressions? | released tags (this is the easy, default run) |
| Does new released code add standing diagnostics? | feature-spanning released-tag range |
| Does Rigor *catch real bugs*? | per-commit / PR-head / bug-introducing commits |

List the chosen revisions in **chronological order** (betas / RCs
included — they are part of the dev flow). Record the sampling
choice *and its consequence* in the survey note.

The later phases say "tag" for brevity, but every step works on any
checkout-able revision — `git checkout` and the scripts' `TAGS`
list accept commit SHAs just as well as tag names.

## Phase 2 — Clone the target

Clone into the survey area, not the rigor repo:

```sh
cd ~/repo/ruby/rigor-survey
git clone --filter=blob:none https://github.com/<org>/<name>.git <name>
```

`--filter=blob:none` (blobless partial clone) avoids fetching all
historical blobs up front; each tag checkout fetches what it needs.

## Phase 3 — Verify the tags exist

```sh
cd ~/repo/ruby/rigor-survey/<name>
for t in <tag-list>; do
  git rev-parse -q --verify "refs/tags/$t" >/dev/null \
    && echo "OK   $t" || echo "MISS $t"
done
```

Drop or substitute any missing tag before sweeping; note omissions.

## Phase 4 — Write the frozen config

Write `.rigor.dist.yml` **into the target's root** (untracked there,
so `git checkout` between tags never disturbs it). Approximate what
`rigor-project-init` would generate for the project's stack, then
**freeze it** — identical config across every tag is what makes the
surfaced-count delta attributable to the project's code.

```yaml
# Frozen — held identical across every tag in the sweep.
paths: [app, lib]            # the project's source roots
exclude: [vendor, tmp]
severity_profile: lenient    # acknowledge-mode default for a large project
signature_paths:
  - /abs/path/to/rigor/plugins/rigor-activesupport-core-ext/sig
cache:
  path: /abs/path/to/rigor-survey/_<name>-sweep/cache
```

Rules that keep the sweep clean:

- **Artefacts live OUTSIDE the target tree.** Put the baseline,
  cache, and per-tag reports under a sibling
  `_<name>-sweep/` directory. `cache.path` is set absolute for the
  same reason. Then `git checkout <tag>` only ever changes the
  project's own files.
- **Plugin-gem caveat (v0.1.x).** The `rigor-*` plugin gems are not
  RubyGems-published yet, so a faithful external-user config omits
  them; wire RBS bundles (`rigor-activesupport-core-ext`) by
  absolute `sig/` path. The frozen-config methodology is unaffected
  — just record which plugins were and were not active.
- The content-hashed cache is **safe to share across tags** — a
  changed file misses, an unchanged file hits. Keep it; it makes the
  sweep fast.

## Phase 5 — Baseline at the first tag

```sh
cd ~/repo/ruby/rigor-survey/<name> && git checkout -q -f <first-tag>
```

Generate the baseline (run from the rigor repo so the Nix flake
resolves; `cd` into the target *inside* the command):

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command \
  bash -c 'cd ~/repo/ruby/rigor-survey/<name> && \
    BUNDLE_GEMFILE=<rigor>/Gemfile bundle exec <rigor>/exe/rigor \
    baseline generate --output=<rigor>/../rigor-survey/_<name>-sweep/baseline.yml'
```

Record the bucket / diagnostic count it reports — that is the sweep's
zero point.

## Phase 6 — Sweep the tags

Use [`scripts/sweep.sh`](scripts/sweep.sh) — set `RIGOR`, `TARGET`,
`SWEEP`, and `TAGS` at the top, then:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command \
  bash .claude/skills/rigor-regression-sweep/scripts/sweep.sh
```

It checks out each tag (`git checkout -q -f`), runs
`rigor check --baseline=… --no-stats --format json`, and saves
`reports/<tag>.json` (stdout) + `reports/<tag>.err` (stderr — carries
the "N diagnostic(s) silenced by baseline" line). Long sweeps:
run it backgrounded.

## Phase 7 — Tabulate

Use [`scripts/tabulate.rb`](scripts/tabulate.rb) (set the same paths
+ `TAGS`):

```sh
nix … develop --command ruby \
  .claude/skills/rigor-regression-sweep/scripts/tabulate.rb
```

Per tag it prints `raw / silenced / surfaced` and the severity +
rule breakdown. `raw = surfaced + silenced`. **`surfaced` is the
headline metric** — diagnostics beyond the frozen baseline envelope,
i.e. the error increase a team would have seen on that tag.

## Phase 8 — Interpret and record

Read the curve, then write a `docs/notes/<date>-<project>-…-regression-sweep.md`
survey note (mirror the Mastodon one). Cover:

- The **surfaced curve** — flat at 0 means ordinary development never
  breached the baseline (baseline stability validated); a rising
  curve means real regressions or churn artefacts to inspect.
- **Churn cross-check** — always measure `git diff --stat
  <first> <last> -- 'app/**/*.rb' 'lib/**/*.rb'`. A flat curve is
  only meaningful if real files changed; report the changed-file
  count so `surfaced = 0` cannot be mistaken for "nothing moved".
- **The rename caveat.** The baseline keys on `(file, rule, count)`.
  A *renamed* file with a baselined diagnostic shows as the old
  bucket going `:cleared` **and** a new `(file, rule)` surfacing —
  a `surfaced > 0` that is a churn artefact, not a regression.
  When `surfaced` jumps, diff the tag and rule out renames before
  calling it a regression.
- **Cold-cache spot check.** Re-run the last tag with `--no-cache
  --no-baseline` and confirm `raw` matches the swept value — proves
  the shared cache masked nothing.
- **The parse-error floor.** A constant, non-zero `surfaced` at
  *every* tag — including the baseline tag itself — is the
  signature of **rule-less diagnostics**: parse errors and
  internal-analyzer errors carry no `rule`, so `Baseline` never
  buckets them and they surface forever. The usual source is a
  Rails generator `.rb` template (an ERB file with a `.rb`
  extension — `<%= … %>` fails to parse). Confirm by reading the
  rule-less rows; the fix is config-side — `exclude:` the
  generator-template directory — not a baseline concern. (Seen in
  the Redmine sweep: 22 parse errors from one `lib/generators/.../templates/migration.rb`.)
- **Feed findings back.** Validated behaviour → cite in the relevant
  ADR. New false positives or a surprising curve → a queued
  engine/plugin item, or a regression spec under `spec/`.

## Invocation gotcha

`nix develop` resolves the flake from the **current directory**. The
rigor flake is in the rigor repo, the target is elsewhere — so do
**not** `cd` into the target before `nix develop`. Run `nix …
develop --command bash -c 'cd <target> && …'` from the rigor repo,
and pass `BUNDLE_GEMFILE=<rigor>/Gemfile` so `bundle exec
<rigor>/exe/rigor` runs with rigor's gem environment while the target
is the working directory (diagnostic paths then resolve
target-relative, keeping baseline keys stable across tags).

## Corpus-gating gotchas (each cost a wrong conclusion first)

- **A worktree isolates the ENGINE, never a PLUGIN.** `exe/rigor` unshifts its
  own tree's `lib/`, so `$worktree/exe/rigor` measures that worktree's engine —
  but `plugins/` still resolves from the main repo, so a worktree "before" run
  silently loads the *modified* plugin and the diff comes out empty. It presents
  as a **passing** gate. For a plugin change swap the directory instead:
  `git checkout origin/master -- plugins/rigor-<name>` (plus `rm` any file the
  change adds), run the before side, then
  `git checkout HEAD -- plugins/rigor-<name>`. Verify with `rigor plugins`,
  which prints each manifest's version.
- **`make verify` gates only `lib` + `plugins` — the external corpus still
  exposes false positives** from receivers Rigor mistypes. Never widen a union /
  nilable-receiver diagnostic (or promote any default) on a clean `make verify`
  alone; run this sweep, or at minimum a before/after corpus diff, first.
- **Adjudicate against the framework's own source, not the symptom.** A GENUINE
  verdict on a hot production code path is presumptively-FP until confirmed
  against the library's source — two GitLab "bugs" overturned to FP that way.
- **`dump_type`-via-`check` is the ground truth** — single-file `dump_type`
  probes are wrong for cross-file symbols. Analyze the whole directory.
- **Prove the path is exercised before trusting a green run.** A clean corpus
  result proves nothing until you instrument it (29 real `Void` translations in
  kramdown; 61 mail files matching `#:nodoc:` — twice, that instrumentation is
  what separated a real no-op from a vacuous one). Measure the layer, not the
  aggregate: a `--depth 1` clone collapses every commit to one author/date, and
  a vendored directory can inflate a grep count 3×.
- **Survey checkouts**: `mise.toml` needs `mise trust` first; `git stash push --
  <tracked files>` (an untracked pathspec errors and stashes nothing); never run
  two `rigor` processes against one target — cache-lock contention corrupts the
  run.
