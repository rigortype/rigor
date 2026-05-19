# ADR-22 — Baseline mechanism + project-onboarding SKILLs

Status: **proposed, 2026-05-19.** Records the project's stance on
**per-project error-level pragmatism**: a baseline file (PHPStan-shaped)
plus two companion agent SKILLs (project initialisation and
baseline-reduction). The combination lets mature codebases adopt
Rigor without first fixing every diagnostic, while preserving the
guarantee that *new* regressions surface immediately.

## Context

The five-project survey under
[`docs/notes/20260519-oss-library-survey.md`](../notes/20260519-oss-library-survey.md)
showed that **mature Ruby codebases routinely carry hundreds to
thousands of static-analysis diagnostics** on first contact with
Rigor. Even after the v0.1.6 / v0.1.7-track plugin and engine
improvements (D1–D6) that closed several systemic false-positive
classes, the headline totals settled at:

| Project | Total diagnostics | Errors |
| --- | --- | --- |
| Mastodon | 2,401 | 678 |
| Redmine | 939 | 381 |
| Solidus | 47 | 41 |
| tdiary-core | 65 | 20 |
| dependabot-core | 5 | 2 |

Three observations from inspecting the residual diagnostics
across these projects:

1. **Some are real-but-empirically-safe.** Static analysis sees
   `T | nil`; the production code base, exercised by an active
   test suite and live traffic, always initialises the slot
   before reaching the call site. The static reading is *correct*
   in a worst-case-soundness sense; the runtime never observes
   the worst case.
2. **Some are stylistic.** When the same pattern repeats across
   dozens of files in an active codebase — `instance_variable_get`
   defensive guards, dynamic `send` dispatch on a known-finite
   tag set, idiomatic `obj&.method` chains that the analyzer's
   narrowing doesn't follow — the pattern *is* the project's
   style. Forcing every site to be rewritten contradicts a
   working idiom.
3. **Some are bugs Rigor caught.** Genuine `nil`-receiver
   crashes that have lurked because the line is rarely
   exercised. These are the value Rigor delivers.

A naive zero-diagnostic-required policy collapses categories 1 +
2 + 3 into a single "fix everything" bucket. Worse, it blocks
adoption: a maintainer trying Rigor on Mastodon faces 678 errors
on day one and abandons the experiment before extracting any
genuine bug fix from category 3. PHPStan, mypy, Sorbet, and
Steep have all converged on the same answer:

> Record what's there today as a **baseline**. Surface only
> **new** diagnostics. Treat baseline reduction as a separate,
> opt-in workflow.

This is the design principle Rigor adopts.

Rigor already ships three diagnostic-suppression layers, but
none fits the "snapshot what's there today" use case:

- **`# rigor:disable <rule>` (per-line)** — author-intent
  comment for a specific known-safe line. Verbose to apply
  across hundreds of sites.
- **`# rigor:disable-file <rule>` (per-file)** — file-level
  blanket suppression. Coarse; loses count visibility.
- **`severity_profile: lenient/balanced/strict`
  (per-run)** — re-stamps every rule's severity globally.
  No per-file targeting.

The user-facing reasoning from the design conversation:

> Statically `T|nil` may be observed, but in practice the value
> is always initialised — `nil` cases don't actually occur.
> When the same pattern is left in place across an active
> project, it can be regarded as style. At minimum, the fact
> that production / test code works is more important than the
> static-analysis inference. Yet glossing over known patterns
> in the initial state would let future latent errors accumulate.

The baseline mechanism is the explicit accommodation of that
tension: **the initial state is preserved**; **new occurrences
surface**; **reducing the baseline is a recognised workflow with
its own SKILL**.

## Decision

This ADR commits to three deliverables, scheduled together
because each one is load-bearing for the others:

1. **Baseline file mechanism** — a project-local YAML file
   recording the count of every (file, rule) pair known at
   baseline-generation time. Diagnostics observed at run time
   that are accounted for by the baseline are silenced; excess
   diagnostics surface as the current run's "new findings".
2. **`rigor-project-init` SKILL** — agent-facing workflow for
   onboarding a new project: write `.rigor.yml`, choose plugins
   matching the project's stack, pick the right
   `severity_profile`, generate an initial baseline,
   optionally emit `.rigor.dist.yml` per the developer-override
   convention.
3. **`rigor-baseline-reduce` SKILL** — agent-facing workflow
   for opportunistic quality improvement: walk the baseline
   rule-by-rule in priority order (smallest rule first;
   patterns with concentrated fixes first), present sample
   call sites + suggested fixes, decrement counts as the user
   actually lands fixes.

The mechanism is **opt-in per project** — no `.rigor-baseline.yml`
present means current behaviour (every diagnostic surfaces). The
SKILLs are **agent-facing**, not CLI commands; the CLI grows the
narrow `rigor baseline {generate, dump, prune}` subcommand
family that the SKILLs drive.

## Working decisions

The major design choices, recorded so future "why this shape?"
questions resolve against a written premise.

### WD1 — Baseline match granularity is `(file, rule, count)`

Three candidate granularities considered:

| Granularity | Pros | Cons |
| --- | --- | --- |
| (file, rule, **count**) | Refactor-robust (line moves don't invalidate the baseline). Compact (one row per file × rule). Matches PHPStan's `phpstan-baseline.neon`. | Can't distinguish two same-rule diagnostics on different lines. New occurrences don't surface if total count stays equal even when lines move. |
| (file, rule, **line**) | Surface exact regression locations. | Fragile under refactor — adding one line above shifts every baseline entry. |
| (file, rule, **message regex**) | Pin-point precision. | Most fragile of all — message wording is part of the diagnostic's public surface but routinely tweaked in patch releases. |

**Decision**: WD1 = `(file, rule, count)`. Same shape PHPStan
landed on after the mypy / Psalm community converged. The trade
— that line-shuffle within a file doesn't surface as a new
diagnostic when total count is unchanged — is acceptable: rigor's
goal is to flag *new* findings, and "I moved an existing finding
up three lines" isn't a regression.

The baseline file shape:

```yaml
# .rigor-baseline.yml — generated by `rigor baseline generate`
# Tracks diagnostics known at <ISO-8601 timestamp>. Reducing
# rows is the `rigor-baseline-reduce` SKILL's job.
version: 1

ignored:
  - file: app/models/spree/address.rb
    rule: call.undefined-method
    count: 3
  - file: app/services/fan_out_on_write_service.rb
    rule: call.undefined-method
    count: 1
  - file: app/services/fan_out_on_write_service.rb
    rule: nullable-receiver
    count: 2
```

### WD2 — Baseline file location

Three candidate locations:

| Location | Pros | Cons |
| --- | --- | --- |
| `.rigor-baseline.yml` (project root) | Sibling of `.rigor.yml`. Visible to the author. PHPStan convention. | One more file at the root. |
| `.rigor/baseline.yml` | Nested under existing cache dir. | The cache dir is gitignored by convention; baseline would have to escape that. |
| Inside `.rigor.yml` `baseline:` key | Single config file. | Baseline rows can be thousands; muddy with config. |

**Decision**: WD2 = `.rigor-baseline.yml` at project root. The
file is intentionally version-controlled (it documents project
state). Embedded mode (inline `baseline:` key in `.rigor.yml`)
is rejected — baseline content scale (rows × projects with
hundreds of files) is wrong for the config file.

### WD3 — Scope is per-rule, not per-severity

The baseline records *rule identifiers* (`call.undefined-method`
/ `nullable-receiver` / `plugin.activerecord.unknown-column` /
…), never severity levels (`:error` / `:warning`). Two reasons:

1. **Severity changes mid-cycle**: a rule can move from
   `:warning` to `:error` when `severity_profile: strict` is
   set. The baseline must remain stable across that toggle.
2. **Per-rule scope mirrors the existing `# rigor:disable
   <rule>` surface**. Same identifier vocabulary; no second
   classification scheme to learn.

### WD4 — Excess-over-baseline diagnostics surface unchanged

When `actual > baseline.count` for a (file, rule) pair, the
**excess** diagnostics are emitted at their full normal
severity. Implementation simplification: emit the first `count`
diagnostics silently, then emit the remaining `actual - count`
as normal. The user sees "1 new error" when their commit adds
one site of an already-baselined rule.

Edge case: when `actual < baseline.count`, do *not* emit; the
gap is recorded by `rigor baseline drift` as a reduction
opportunity. (See WD5.)

### WD5 — Drift detection is opt-in, not enforced

PHPStan strict mode treats `actual < baseline` as a failure
(forces baseline reduction in lockstep with fixes). Rigor
**does not**. Reasoning: in a multi-contributor codebase,
parallel branches may legitimately produce baseline drift in
either direction; making CI fail on drift creates merge
ordering friction without buying genuine correctness.

Instead:

- `rigor baseline drift` — read-only inspection. Reports
  `(file, rule, baseline.count, actual.count, delta)` rows
  where delta != 0. The `-baseline-reduce` SKILL consults this.
- `rigor baseline prune` — interactive removal of zero-count
  entries (files where the diagnostic class is no longer
  observed at all).
- `rigor baseline regenerate` — full rewrite from current
  diagnostics. Destructive (overwrites the file); used after
  bulk fixes.

### WD6 — Baseline filters AFTER `# rigor:disable` and after `severity_profile`

The diagnostic pipeline order:

```
emit  →  per-line `# rigor:disable` filter
      →  per-file `# rigor:disable-file` filter
      →  severity_profile re-stamp
      →  baseline filter (NEW)
      →  output
```

The baseline filter is the **last** suppression layer. Author-
intent comments take precedence (an author saying "this
specific line is safe" outranks the project's collective
"we know there are N of these here"). The baseline does not
consume `# rigor:disable`d sites; it only sees what those
upstream filters let through.

### WD7 — Diagnostic count metadata is preserved in run output

The CLI grows a one-line summary after the diagnostic stream:

```
3,099 → 121 surfaced  (2,978 silenced by .rigor-baseline.yml)
```

So even when the baseline is large, the *fact* of suppression
is visible — preventing the situation where a CI passes silently
on a project with 2,978 latent issues nobody is tracking. The
existing `--stats` flag gets a baseline section. The summary
line is plain stderr, not a diagnostic, so it doesn't pollute
machine-readable output.

### WD8 — Two new SKILLs, both contributor-facing (`.claude/skills/`)

Per the discipline established when
[`skills/rigor-plugin-author/`](../../.claude/skills/rigor-plugin-author/)
was re-homed to `.claude/skills/` (commit `1a3c342`), the new
SKILLs are contributor-facing today. They consume rigor's
internal layout (`make verify`, the Flake, `bundle exec exe/rigor`)
and run inside the rigor monorepo's checkout. Both SKILLs are
candidates for an `external-author` reformulation when the
v0.2.0 external-SKILL track lands (see
[`docs/ROADMAP.md`](../ROADMAP.md) § "Agent workflows / SKILLs").

The two SKILLs are sketched in §§ "rigor-project-init" and
"rigor-baseline-reduce" below.

## CLI surface

Three new subcommands, all backed by the same baseline I/O
module.

```
$ rigor baseline generate [--force]
  → Writes .rigor-baseline.yml from current `rigor check` results.
    Refuses (exits 1) if the file exists; --force overrides.

$ rigor baseline dump [--rule <rule>] [--file <glob>]
  → Read-only inspection. Shows the current baseline grouped by
    rule, file, or both. Supports `--format json` for tooling.

$ rigor baseline drift
  → Reports baseline-vs-actual deltas. Exits 0 even on drift;
    the user / agent decides whether to act.

$ rigor baseline prune
  → Drops baseline rows whose `actual.count == 0`. Confirms the
    rows interactively before writing (or `--force` to skip).

$ rigor baseline regenerate
  → Equivalent to `generate --force` after an `prune`. The
    common end-of-quality-improvement-session refresh.
```

`rigor check` itself grows a `--baseline=PATH` flag (default
`.rigor-baseline.yml`) and a `--no-baseline` opt-out. Both can
be set via `.rigor.yml`'s `baseline_path:` and `baseline:` keys
respectively for the in-config form.

## SKILL: rigor-project-init

End-to-end agent workflow for onboarding a new project to
Rigor. Triggered when the user says "set up Rigor in this
project", "configure rigor for X", or starts running rigor in
a Gemfile-bearing directory that has no `.rigor.yml`.

### Phase outline

1. **Detect the project shape** — read `Gemfile` to detect the
   framework family (Rails / Sinatra / dry-rb / plain Ruby /
   …); read `Gemfile.lock` to detect the locked gem versions
   and the absence-or-presence of `rbs_collection.lock.yaml`.
2. **Plugin selection** — propose a plugin set matching the
   detected stack. Defaults:
   - Rails-shaped project → `rigor-actionpack`,
     `rigor-activerecord`, `rigor-actionmailer`,
     `rigor-rails-routes`, `rigor-rails-i18n`, plus per-gem
     plugins for Devise / Pundit / Sidekiq / Sorbet etc.
     present in `Gemfile`.
   - dry-rb-shaped project → `rigor-dry-types` +
     `rigor-dry-struct` (+ schema / validation when present).
   - RSpec test suite → `rigor-rspec`.
3. **Severity profile** — propose `lenient` for any project
   with >100 errors on first run (matches the "incremental
   adoption" use case); propose `balanced` otherwise. The
   strict profile stays opt-in for CI-final-gating.
4. **Write `.rigor.dist.yml`** (the convention is dist-file
   committed, optional `.rigor.yml` local override) with the
   detected configuration.
5. **Run `rigor check`** to get the diagnostic baseline.
6. **Write `.rigor-baseline.yml`** via `rigor baseline
   generate`. Print the suppression summary: "N diagnostics
   recorded as baseline; M will surface on subsequent runs".
7. **Surface real bugs**: in the baseline, count diagnostics
   per rule. Suggest 2-3 rules where the count is small enough
   to fix interactively (these are likely the genuine bugs
   Rigor caught — concentrated rules with low counts often
   indicate localised issues vs. systemic patterns).

### Decision points the SKILL escalates to the user

- "This project uses HAML in places and ERB in others — should
  I enable `rigor-actionpack`'s extended template extension
  set, or restrict it?" (P3-style trade-off.)
- "The baseline is very large (>2,000 entries). Consider
  excluding `vendor/` / `spec/` / `test/` from `paths:` first."
- "Locked gems X, Y, Z have no RBS coverage; consider
  `dependencies.source_inference:` for them."

## SKILL: rigor-baseline-reduce

End-to-end agent workflow for opportunistic quality
improvement. Triggered when the user says "reduce the rigor
baseline" / "fix some baseline diagnostics" / "what should I
fix next?".

### Phase outline

1. **Read `.rigor-baseline.yml`** — group by rule, sort by
   ascending count (smallest rules first → likely real bugs
   or contained patterns).
2. **For each rule (in priority order)**:
   a. Run `rigor check` filtered to the affected files; surface
      the actual diagnostic stream so the user sees the
      messages.
   b. Sample 3-5 distinct sites; ask the user to classify each:
      "real bug" / "stylistic / safe" / "FP — Rigor should
      catch this".
   c. If "real bug": propose a fix; offer to apply.
   d. If "stylistic / safe": add `# rigor:disable <rule>`
      comments at the sites (per-line, not per-file —
      preserves visibility); decrement baseline count.
   e. If "FP": leave in baseline AND open / flag a Rigor-side
      issue (the rule itself should narrow further). For the
      contributor-facing variant of this SKILL inside the
      rigor repo, "flag a Rigor-side issue" means draft a
      regression spec under `spec/rigor/...` and a survey
      note under `docs/notes/`.
3. **After each rule processed**: `rigor baseline drift`
   to refresh the residuals; `rigor baseline prune` if the
   rule is fully cleared from a file.
4. **Stop conditions**: user signals halt; the next rule's
   count exceeds a configurable session budget (default: 20
   call sites); session reaches a configurable wall-time
   budget (default: 60 minutes).

### Decision points the SKILL escalates to the user

- "This rule has 200 sites across 14 files — looks systemic.
  Investigate whether a plugin / engine fix would clear them
  in bulk, or pick a specific file and reduce there?"
- "This file's diagnostic shape suggests the per-file
  `# rigor:disable-file` form would be more maintainable than
  per-line; switch?"
- "The diagnostic message changed between Rigor versions; the
  baseline doesn't match. Regenerate or prune-then-regenerate?"

## Consequences

### Positive

- **Adoption velocity**: a maintainer can onboard Rigor in
  five minutes and immediately see only the diagnostics that
  *appeared since baseline*. The legacy noise stays
  parenthesised, not blocking.
- **Incremental quality improvement** has a recognised
  workflow with metric (baseline size) attached. "Reduce the
  baseline by 10% this sprint" becomes a tracked goal.
- **The SKILL pair makes the workflow agent-driveable**. The
  user doesn't have to know the baseline grammar; the
  init SKILL writes it, the reduce SKILL walks it.
- **Existing suppression mechanisms are preserved**. Per-line
  `# rigor:disable` is the authored-intent finest-grain
  primitive; per-file `# rigor:disable-file` covers concern
  blocks; severity_profile re-stamps; baseline absorbs the
  remaining "snapshot today" residue.

### Negative

- **One more YAML file** at the project root. The convention
  is one of: `.rigor.yml`, `.rigor.dist.yml`,
  `.rigor-baseline.yml`. PHPStan / RuboCop / Sorbet have
  comparable footprints; this isn't unusual in the Ruby
  static-analysis ecosystem.
- **Baseline drift** under refactors can hide newly-introduced
  issues if total count stays equal. The (file, rule, count)
  granularity is a trade for refactor robustness. Users
  wanting tighter detection can fall back to
  `severity_profile: strict` plus a strict CI gate without
  the baseline.
- **CI integration is a separate decision**. This ADR does
  *not* specify CI behaviour beyond the exit-code contract
  (excess-over-baseline → non-zero exit per existing
  `rigor check` semantics). Teams choose whether to also fail
  CI on drift; that's a `.rigor.yml` / pipeline decision.

### Carry-over

- The two SKILLs ship as contributor-facing artefacts under
  `.claude/skills/`. The external-author variant queued for
  v0.2.0 (per
  [`docs/ROADMAP.md`](../ROADMAP.md) § "Agent workflows /
  SKILLs (committed: v0.2.0)") covers the same workflow shape
  for users running Rigor inside their own gem / project
  checkout, outside the rigor monorepo.
- Naming: this ADR uses **baseline** consistently. The CLI
  subcommand family lives under `rigor baseline {...}`.

## Implementation slicing (proposed)

Sliced for orthogonal landing; each slice is shippable
on its own. Demand-driven; no slice scheduled by this ADR.

### Slice 1 — Baseline file I/O + `rigor baseline generate`

- New `Rigor::Analysis::Baseline` value object (frozen).
  Loads / writes `.rigor-baseline.yml` per WD1 shape.
- New `Rigor::CLI::BaselineCommand` with `generate`
  subcommand.
- `rigor check` gains `--baseline=PATH` / `--no-baseline`.
  When baseline is loaded, filters diagnostics after the
  existing pipeline (per WD6).
- Summary line appended to stderr (WD7).

### Slice 2 — Drift inspection (`dump`, `drift`, `prune`)

- `rigor baseline dump` — read-only inspection.
- `rigor baseline drift` — compute baseline-vs-actual deltas.
- `rigor baseline prune` — drop zero-count entries.

### Slice 3 — `rigor-project-init` SKILL

- `.claude/skills/rigor-project-init/SKILL.md` (router).
- `.claude/skills/rigor-project-init/references/01-detect.md`
  (Gemfile / Gemfile.lock walk; plugin matching).
- `.claude/skills/rigor-project-init/references/02-configure.md`
  (severity profile choice; `.rigor.yml` / `.rigor.dist.yml`
  template).
- `.claude/skills/rigor-project-init/references/03-baseline.md`
  (run `rigor check`; generate baseline; surface concentrated
  rules as likely real bugs).

### Slice 4 — `rigor-baseline-reduce` SKILL

- `.claude/skills/rigor-baseline-reduce/SKILL.md` (router).
- `.claude/skills/rigor-baseline-reduce/references/01-classify.md`
  (per-rule walkthrough; sample-and-classify protocol).
- `.claude/skills/rigor-baseline-reduce/references/02-fix-or-suppress.md`
  (real-bug fixes, `# rigor:disable` placement, FP escalation
  to a Rigor-side regression spec).

### Slice 5 — `regenerate` + drift-as-warning mode

- `rigor baseline regenerate` (destructive rewrite).
- `--baseline-strict` flag making excess-or-deficit drift
  exit non-zero (the strict CI gate for teams that want it).

### Slice 6 (out of scope for this ADR) — IDE / LSP integration

The Language Server (per
[ADR-19](19-language-server-packaging.md)) could surface
baselined diagnostics differently from new ones (e.g.,
ghosted in the gutter). That's a follow-up; not committed by
this ADR.

## Re-evaluation triggers

This ADR's design is re-litigated if any of these become true:

1. **PHPStan-style line-precision baseline becomes the
   community default** (so far the (file, rule, count) shape
   holds across mypy / Psalm / PHPStan / Sorbet's snapshot
   format; if RuboCop's
   [`--auto-gen-config`](https://docs.rubocop.org/rubocop/configuration.html#automatically-generated-configuration)
   format wins in the Ruby ecosystem, reconsider WD1).
2. **Multiple maintainers report baseline-drift-hides-bug
   incidents.** Would force WD5 to flip toward strict-drift
   default.
3. **The two SKILLs see >50% of their use cases from external
   gem authors**. Would force a v0.2.0 external-author
   variant earlier than committed.
4. **A different suppression layer absorbs the use case
   first** — e.g., per-line `# rigor:disable` extends to
   accept "N occurrences" as a count. Unlikely but recorded.

## References

- PHPStan's baseline:
  <https://phpstan.org/user-guide/baseline>
- Sorbet's strictness levels + escape hatches:
  <https://sorbet.org/docs/static>
- RuboCop's `--auto-gen-config`:
  <https://docs.rubocop.org/rubocop/configuration.html#automatically-generated-configuration>
- [ADR-8](8-steep-inspired-improvements.md) — severity
  profiles (the prior layer this ADR builds on).
- [`docs/notes/20260519-oss-library-survey.md`](../notes/20260519-oss-library-survey.md)
  — the five-project survey that drove the design need.
- [`docs/ROADMAP.md`](../ROADMAP.md) § "Agent workflows /
  SKILLs (committed: v0.2.0)" — companion external-author
  SKILL track this ADR's SKILLs feed into.
