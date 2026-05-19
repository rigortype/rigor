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

### WD1 — Baseline match granularity: rule-ID by default, message-pattern as opt-in

Three candidate granularities considered:

| Granularity | Pros | Cons |
| --- | --- | --- |
| (file, **rule**, count) — Rigor's default | Refactor-robust (line moves don't invalidate the baseline). Compact (one row per file × rule). Stable across patch releases that tweak diagnostic wording. | Can't distinguish two same-rule diagnostics on different lines / receivers. |
| (file, rule, **message**, count) — opt-in, PHPStan's default | Pin-point per-call-site precision (different `undefined method foo` vs `undefined method bar` are separate buckets). Lets a maintainer baseline a specific known issue without silencing every same-rule diagnostic in the file. | Fragile under wording tweaks across rigor releases — the baseline regenerates after every Rigor patch release where a rule reworded its diagnostic. |
| (file, rule, **line**, count) | Surface exact regression locations. | Most fragile of all — adding one line above shifts every baseline entry. |

**Decision**: WD1 supports **both** rule-ID (default) and
message-pattern (opt-in) forms in the same file, on a per-row
basis. The CLI's `rigor baseline generate` writes rule-ID rows
unless `--match-mode message` is passed.

Why two modes:

- Rigor's analyzer surface is younger than PHPStan's; message
  wording is still being refined release-to-release. A
  default that pins on wording would force users to
  regenerate after every patch release where any rule's
  message gets a typo fix. **The rule-ID default minimises
  baseline churn across Rigor versions.**
- Pin-point precision is sometimes load-bearing. A
  maintainer wants to baseline "the known
  `undefined method 'bar' for Foo` at this site" without
  silencing every future `undefined-method` in the same
  file. **The opt-in message mode covers that case.**

Both modes share the WD4 ALL-or-NOTHING threshold semantics —
"bucket" is defined by whatever keys the row carries:

- A rule-ID row defines bucket `(file, rule)`.
- A message row defines bucket `(file, rule, message)`.

Rows of different modes can coexist in the same file. The
filter walks every row in order; the first row whose keys
match a diagnostic is the bucket counter the diagnostic
contributes to. Rows further down don't see already-claimed
diagnostics.

The baseline file shape (mixed example):

```yaml
# .rigor-baseline.yml — generated by `rigor baseline generate`
# Tracks diagnostics known at <ISO-8601 timestamp>. Reducing
# rows is the `rigor-baseline-reduce` SKILL's job.
version: 1

ignored:
  # Rule-ID rows (the default form `generate` writes) — every
  # diagnostic with the named rule under the named file
  # contributes to this bucket's count.
  - file: app/models/spree/address.rb
    rule: call.undefined-method
    count: 3
  - file: app/services/fan_out_on_write_service.rb
    rule: call.undefined-method
    count: 1
  - file: app/services/fan_out_on_write_service.rb
    rule: nullable-receiver
    count: 2

  # Message-pattern rows (opt-in via `--match-mode message`,
  # or hand-edited): tighter precision. `message` is a Ruby
  # `Regexp`-compatible pattern (no surrounding `/.../`).
  # Diagnostics with the named rule in the named file whose
  # `message` matches the regex contribute to this bucket;
  # other diagnostics fall through to the next row.
  - file: app/lib/activitypub/linked_data_signature.rb
    rule: call.undefined-method
    message: "undefined method `merge' for Array"
    count: 1
```

Message-mode regex syntax: a literal substring or a Ruby
regex source. The generator quotes literal messages with
`Regexp.escape` (so newly-introduced `(parens)` or `[brackets]`
in messages don't cause silent over-match). Hand-edited
rows can use the full Ruby regex grammar.

Mode selection at generation time:

```sh
rigor baseline generate                # default: rule-ID rows
rigor baseline generate --match-mode message
rigor baseline generate --match-mode mixed  # per-rule heuristic (see below)
```

The `mixed` heuristic — written as a follow-up slice, not the
initial implementation — would choose per-rule: rule-ID for
rules with stable wording (catalogued as such in
`Rigor::Analysis::RuleCatalog`); message-mode for rules
catalogued as wording-evolving. This is a future ergonomics
tweak; the initial release is rule-ID default + opt-in
message-mode.

### WD2 — Baseline file location AND opt-in loading

Two questions, both answered together:

**(a) Default file name + location.** `.rigor-baseline.yml` at
the project root, sibling of `.rigor.yml` / `.rigor.dist.yml`.
This is the path `rigor baseline generate` writes to by default,
and the path the project-init SKILL writes when first
scaffolding a project. The file is intentionally
version-controlled (it documents project state).

Rejected alternatives:

| Location | Why rejected |
| --- | --- |
| `.rigor/baseline.yml` | The cache dir is gitignored by convention; baseline would have to escape that, and the project state would be hidden one level deeper than the config. |
| Inside `.rigor.yml` `baseline:` key | Baseline content scale (rows × hundreds of files) is wrong for the config file — would muddy diffs and lock-step `.rigor.yml` edits with baseline edits. |

**(b) Loading semantics: explicit only, never implicit.** The
**presence** of `.rigor-baseline.yml` on disk does NOT change
`rigor check` behaviour. The baseline is loaded only when
`.rigor.yml` (or `.rigor.dist.yml`) **explicitly** names it:

```yaml
# .rigor.yml — opt-in baseline reference
baseline: .rigor-baseline.yml
# (or any other path the project chose)
```

When the key is omitted, `rigor check` runs as if no baseline
existed — same behaviour Rigor has today. This is the "no
magic" stance: a file sitting in the project root must never
silently change diagnostic semantics.

The reasoning behind making it explicit:

1. **Auditability**: the config file is the single document
   that records what changes diagnostic output. A reviewer
   reading `.rigor.yml` sees `baseline: .rigor-baseline.yml`
   and knows the baseline is active; without that line the
   baseline file is dormant (or absent). No surprise from a
   file checked-in by another contributor that the reviewer
   missed.
2. **CI flexibility**: a project can keep
   `.rigor-baseline.yml` committed for the
   `rigor-baseline-reduce` SKILL's drift inspection without
   activating the suppression in CI. Two configs side by
   side:
   ```yaml
   # .rigor.dist.yml — production CI uses the baseline
   baseline: .rigor-baseline.yml
   ```
   ```yaml
   # .rigor.yml — a contributor's local override that doesn't
   baseline: false   # or just omit the key
   ```
3. **Migration ergonomics**: removing the baseline mid-cycle
   is a one-line edit, not a file deletion. The history of
   "we used to suppress N diagnostics" stays in the YAML.
4. **Test stability**: rigor's own integration specs and
   third-party plugin specs run `rigor check` against
   synthetic projects. If baseline loading were implicit on
   presence, spec authors would have to track stray
   `.rigor-baseline.yml` files in tmpdirs; explicit loading
   removes that footgun.

**Decision**: WD2 = `.rigor-baseline.yml` at project root
**as the convention path**, loaded **only when
`.rigor.yml` / `.rigor.dist.yml` declares `baseline: <path>`**.
The CLI flag `--baseline=PATH` exists as a per-run override
(see § "CLI surface") and is the only way to use a baseline
without putting `baseline:` in the config — primarily a CI
escape hatch, not the intended workflow.

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

### WD4 — Threshold semantics: ALL-or-NOTHING per (file, rule) bucket

The baseline `count` acts as a **threshold**, not as a
"silence-the-first-N" mask. Two states per (file, rule) pair:

| Actual | Behaviour |
| --- | --- |
| `actual ≤ baseline.count` | **All** diagnostics in the bucket are silenced — the project is within the recorded envelope. |
| `actual > baseline.count` | **All** diagnostics in the bucket surface at their full normal severity — including the ones that would have been silenced when the count was still under threshold. |

Rationale: when a (file, rule) bucket crosses its threshold,
the team's review focus is "what's going on with this rule in
this file" — not "which of the N diagnostics is new". Line
numbers within a bucket shift across refactors; a "first 3
silenced, surface only #4 and #5" rule would point at
positions that may have moved between the baseline-generation
moment and the current run. Surfacing the whole bucket lets
the reviewer audit the rule holistically.

Worked example: baseline records `count: 3` for `(foo.rb,
call.undefined-method)`.

- Current run reports 3 sites → 0 surfaced (within threshold;
  silenced).
- Current run reports 5 sites → **all 5** surfaced (over
  threshold; the bucket is now an active concern).
- Current run reports 2 sites → 0 surfaced (under threshold;
  drift opportunity, see WD5).

Implementation: the baseline filter is a per-bucket gate
keyed on `(file, rule)`. When `actual ≤ baseline`, every
diagnostic in the bucket drops; when `actual > baseline`,
every diagnostic in the bucket passes through. There is no
mid-bucket partial state.

Side benefit: the rule is symmetric and easy to explain to
both human reviewers and the CI gate. "Your commit pushed
`foo.rb`'s `call.undefined-method` count from 3 to 4 — over
threshold; here are all 4 sites" reads cleanly. The
alternative "your commit added a 4th site; here's site #4"
would force the CI message to declare which specific site is
the new one, which the (file, rule, count) granularity
deliberately cannot do (because line positions aren't
tracked).

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

### WD8 — Two new SKILLs, **external-author-facing** under `skills/`

Both SKILLs target **users newly adopting Rigor in their own
projects** — gem authors, application developers, project-private
plugin maintainers running `gem install rigortype` and pointing
`rigor check` at their own codebase. They are NOT contributor
workflows for the rigor monorepo. Audience consequence:

- They consume the **published `rigortype` gem surface** — the
  `rigor` executable installed via Bundler, not
  `bundle exec exe/rigor` from a checkout. No `make verify`, no
  Nix Flake, no `spec/integration/...` assumptions.
- They reference **public CLI flags and config keys** only —
  the same surface end-users see in `rigor --help`. Internal
  helpers (`Rigor::Analysis::Runner.new(...)`, Phoenix-style
  internal-only modules) are off-limits.
- They live under the **`skills/` top-level tree** that the
  ROADMAP reserved for the v0.2.0 external-SKILL track (see
  [`docs/ROADMAP.md`](../ROADMAP.md) § "Agent workflows /
  SKILLs"). The `skills/rigor-project-init/` and
  `skills/rigor-baseline-reduce/` directories become the
  first concrete occupants of that tree alongside the
  forthcoming `skills/rigor-plugin-author/` external
  variant. The three SKILLs form a coherent onboarding +
  ongoing-quality + plugin-extension trio for the v0.2.0
  external-user track.
- They follow the **portable / agentskills.io-compatible**
  conventions established when `rigor-plugin-author` was
  briefly under `skills/` (commits `25e98cc` /
  `f2dcc5a`): self-contained, absolute GitHub URLs for
  cross-repo references (not relative `../../` paths),
  `name:` + `description:` + optional
  `metadata: {version:, homepage:}` frontmatter,
  consolidated `references/` modules at ≤ 4 to clear waza's
  module-count advisory.

Implication for scheduling: WD8 commits the two SKILLs to the
**v0.1.9 cycle** — the lead-up versions (v0.1.7 / v0.1.8)
are reserved for collecting and addressing real-project
error data from the field, so the SKILLs ship with concrete
empirical signal behind their default plugin / severity /
baseline-rule choices. The external `rigor-plugin-author`
reformulation rides the same v0.1.9 train. The ADR's slicing
section places them in slices 3 + 4 as the externally-shippable
work, not as contributor experiments.

Carry-over: the baseline file-format and the `rigor baseline
{...}` CLI subcommand family (slices 1 + 2) are NOT gated on
v0.1.9 — those ship through the regular v0.1.x cycle
(starting v0.1.7) so contributors and field-survey runs can
collect empirical baseline data before the SKILLs land.

The two SKILLs are sketched in §§ "rigor-project-init" and
"rigor-baseline-reduce" below.

### WD9 — Dedicated baseline file schema (vs config-include reuse)

PHPStan's actual approach is structurally different from what
this ADR records as Slice 1. PHPStan's `phpstan-baseline.neon`
is a **regular PHPStan config file** containing only
`parameters.ignoreErrors` entries; the main `phpstan.neon`
absorbs it via `includes:` array. The file is "a baseline" by
convention, not by schema — every key is the same as the main
config's.

Rigor's existing surface ALREADY provides the same primitive:
`.rigor.yml` accepts an `includes:` list (per the existing
configuration loader). So the PHPStan-style approach IS
available: we could define a single `ignored:` key valid at
any config level and merge from an include.

Two candidate shapes, then:

| Aspect | (A) Config-include reuse (PHPStan-style) | (B) Dedicated baseline schema (Slice 1) |
| --- | --- | --- |
| Schema | Same as `.rigor.yml`; baseline rows under `ignored:` (or similar) key. Merged via existing `includes:` plumbing. | Distinct top-level: `version: 1` + `ignored:` only. Loaded via dedicated `baseline:` key. |
| Generator output | Writes a config file with only the ignore section populated. | Writes a self-contained baseline file. |
| Schema evolution | Baseline format coupled to config schema bumps. | Baseline format versioned independently (`version: 1`). |
| Inline option | Yes — small projects can put `ignored:` directly in `.rigor.yml`. | No — must reference an external file. |
| Tool ergonomics | Generic config tools handle the file. | Custom Baseline class owns load / filter / drift; cleaner per-tool API. |
| Newcomer mental model | "Config files everywhere; you stack them." | "Config is one thing, baseline is another thing." |
| Generator footprint | Reuses Configuration writer. | ~270 lines of Baseline class (already written). |
| Drift / prune semantics | Generic — operate on a config-shaped file. | Specific to the baseline tool's frame. |

**Decision**: WD9 = (B) — dedicated baseline schema. ACCEPTED
(2026-05-19, after Slice 1 landed) — the alternative was
considered explicitly and the choice is recorded here so future
"why not the PHPStan way?" questions resolve against a written
premise.

The core framing — short form:

> Unifying the schemas WOULD let one ignore-rule form double
> as a project-wide config (`paths:` plus `ignored:` in the
> same file). That's a genuine benefit for direct authoring.
> But the baseline is **not authored by hand** — it's generated
> by `rigor baseline generate` and reduced by the
> `rigor-baseline-reduce` SKILL. The schema-unification value
> (UX learnability, one config grammar) doesn't accrue if
> humans don't read or write the file directly. The
> separation costs (extra Baseline class, custom load
> path) are bounded and one-time; the unification benefit
> would be paid every release cycle in the form of mixed
> stable / churning content in one schema.

Documented rationale, ranked by load-bearing weight:

1. **Separation of concerns matches operational reality.**
   The config file (`paths:` / `plugins:` / `severity_profile:`
   / …) is *stable* — it describes how the project wants to
   be analysed. The baseline (`ignored:` rows × hundreds of
   files) is *churning* — every fix, every refactor, every
   rigor patch release can shift the bucket counts. Co-locating
   them in one schema means the same file format carries two
   different cadences, which leaks into the reader's mental
   model ("which slots are stable vs churn?").

2. **`version: 1` lets the baseline format evolve without
   moving the rest of the config.** Slice 5's `regenerate`
   plus future format migrations (e.g., adding optional
   `last_seen:` timestamps to rows, switching the message
   field's escape grammar) are baseline-internal concerns;
   they shouldn't force a config-schema version bump that
   external `.rigor.yml`-aware tools have to track.

3. **Generator semantics are cleaner.** `rigor baseline
   generate` writes a file whose every row is meaningful —
   no "this is technically valid config but most slots are
   defaults" confusion. A reviewer opening the generated
   file sees ignore rules and nothing else.

4. **Drift / prune tools own the schema.** `rigor baseline
   drift` (slice 2) doesn't have to walk a config tree
   looking for ignore-shaped entries — it reads a
   `version: 1` file and reasons about its single concern.

5. **No key-name conflict.** With (B), `baseline: <path>` in
   `.rigor.yml` cleanly references the dedicated file. With
   (A), the same `baseline:` key would collide with a
   per-file `ignored:` array, forcing a renaming (e.g.,
   `baseline_path:` / `include_baseline_at:`) that's less
   discoverable.

6. **Existing surface is already separated.** `.rigor.yml`'s
   stable shape predates this ADR; folding a high-churn
   `ignored:` key into it would expand the config's
   responsibility scope at exactly the moment the project
   is otherwise narrowing toward concrete per-task files
   (`.rigor.dist.yml` / `.rigor-baseline.yml` / future per-
   topic configs).

The (A) advantages are real but lower-weight in the current
mix:

- "Schema simplicity" is true for the format authors, but
  users almost never hand-edit the baseline — the regenerate
  /  prune subcommands own it. So the "one schema to learn"
  benefit lands disproportionately on rigor's own
  contributors rather than on external users (the v0.1.9
  SKILL trio's target audience).
- The "inline `ignored:`" option matters for projects with
  ~3 ignore rules, which is rare enough that the cost of
  asking those projects to keep a tiny `.rigor-baseline.yml`
  file is negligible.
- "Generic config tools work" — true but speculative; rigor
  doesn't have an external-config-tool ecosystem the way
  PHPStan does (where `phpstan/extension-installer` etc.
  rely on neon parsing). When such an ecosystem matures, the
  trade-off can be revisited.

### When to revisit WD9

This decision becomes worth re-litigating if any of the
following becomes true:

1. **Multiple "topic" config files appear** (`.rigor-i18n.yml`
   for i18n-specific rule overrides, `.rigor-plugins.yml` for
   plugin-only config, etc.). At that point the `includes:`
   machinery is the load-bearing primitive and folding
   baseline into it gets cheaper.
2. **Per-rule ignoreErrors-style inline config** lands as
   a feature (e.g., a `.rigor.yml`-side `ignored:` key
   alongside `disabled:`). At that point the schemas
   converge anyway and merging them simplifies.
3. **A future SKILL or eval tool needs to read both
   simultaneously** (`.rigor.yml` + baseline) and the
   two-schema cost outweighs the separation benefit.

Implementation note: the Baseline class today could be
**extended** to accept the config-include form as an
alternative load path (heuristic: `version:` field present
→ dedicated; absent + `paths:` / `plugins:` present →
config-shape). Worth queuing as slice 5+ if WD9 gets
revisited; out of scope for the current slice.

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

`rigor check` itself grows a `--baseline=PATH` flag and a
`--no-baseline` opt-out. Resolution order for the active
baseline path (per WD2 (b) — explicit loading only):

1. `--no-baseline` on the CLI → no baseline loaded, regardless
   of `.rigor.yml` / `.rigor.dist.yml` content.
2. `--baseline=PATH` on the CLI → load that specific path.
3. `.rigor.yml` (or `.rigor.dist.yml`) carries
   `baseline: PATH` → load that path. `baseline: false` is
   the explicit-disable form.
4. Neither flag nor config key set → no baseline loaded
   (current default behaviour preserved).

The **presence of `.rigor-baseline.yml` on disk is never a
trigger**. A project can scaffold the file with
`rigor baseline generate`, version-control it, and still
deliberately leave the suppression dormant by omitting the
`baseline:` key from its config. The intended workflow is
that `rigor baseline generate` writes both the file and a
matching `baseline: .rigor-baseline.yml` line into
`.rigor.dist.yml` (or warns the user when that line is
missing); the `rigor-project-init` SKILL takes care of this
wiring as a single step.

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
   generate`. AND add `baseline: .rigor-baseline.yml` to
   the `.rigor.dist.yml` written in step 4 — per WD2 (b)
   the file's presence alone is dormant; the config has to
   name it. The SKILL does both edits in one step so the
   user doesn't end up with a generated baseline that
   silently does nothing.
   Print the suppression summary: "N diagnostics recorded
   as baseline; M will surface on subsequent runs".
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
  default granularity is a trade for refactor robustness;
  users wanting per-call-site precision opt into
  `--match-mode message` per WD1 at the cost of regenerating
  the baseline when rigor patch releases tweak wording. Both
  modes degrade to the same `severity_profile: strict` plus
  strict CI gate without the baseline.
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
  Supports both rule-ID rows (default) and message-pattern
  rows (opt-in). Message-pattern rows use Ruby `Regexp`
  source; the generator's literal-message path passes
  through `Regexp.escape` before write.
- New `Rigor::CLI::BaselineCommand` with `generate`
  subcommand. Initial flag set:
  `--match-mode {rule,message}` (default `rule`), `--force`.
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
- `skills/rigor-project-init/SKILL.md` (router; agentskills.io-shape frontmatter; absolute GitHub URLs for cross-repo references).
- `skills/rigor-project-init/references/01-detect.md`
  (Gemfile / Gemfile.lock walk; plugin matching).
- `skills/rigor-project-init/references/02-configure.md`
  (severity profile choice; `.rigor.yml` / `.rigor.dist.yml`
  template; baseline path declaration).
- `skills/rigor-project-init/references/03-baseline.md`
  (run `rigor check` against the user's project; generate
  baseline; surface concentrated rules as likely real bugs).
- Audience consequence: invokes the published `rigor` binary
  (Bundler-installed), not `bundle exec exe/rigor` from a
  monorepo checkout. References only public CLI flags and
  config keys.
- Committed to v0.1.9 per WD8.

### Slice 4 — `rigor-baseline-reduce` SKILL

- `skills/rigor-baseline-reduce/SKILL.md` (router; agentskills.io-shape).
- `skills/rigor-baseline-reduce/references/01-classify.md`
  (per-rule walkthrough; sample-and-classify protocol;
  real-bug / stylistic / FP triage).
- `skills/rigor-baseline-reduce/references/02-fix-or-suppress.md`
  (real-bug fix patterns; `# rigor:disable` placement
  decisions; FP escalation as a GitHub issue against rigor
  rather than as a regression spec — external users don't
  have a `spec/` to extend rigor with).
- Audience consequence: same as slice 3 — external-user
  surface only.
- Committed to v0.1.9 per WD8.

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
