# ADR-23 — Diagnostic triage command (`rigor triage`)

Status: **Accepted, 2026-05-20; slices 1+2+3+4 implemented in v0.1.9.
WD6 (info excluded from the volume views by default) implemented in
v0.2.3.**

`lib/rigor/triage/` carries the catalogue; `rigor triage` is a
production subcommand. Plugin-contributed recognisers (WD2 extension
point) remain deferred. Records the design of a `check`-derived
subcommand that summarises a project's diagnostic stream — rule-ID
distribution, per-file hotspots, and heuristic "why" hints. Companion
to [ADR-22](22-baseline-and-project-onboarding.md): ADR-22 records
*what is there today* (the baseline); ADR-23 explains *what it means*
and *what to do next*.

## Context

The five-project survey
([`docs/notes/20260519-oss-library-survey.md`](../notes/20260519-oss-library-survey.md))
and a follow-up Mastodon measurement (1303 files) showed that a
mature codebase's first `rigor check` is dominated by a few large
diagnostic clusters whose *cause* is structural, not a scatter of
unrelated bugs:

- Mastodon, default config: **488 diagnostics**. ~73 % were
  `call.undefined-method` for ActiveSupport `core_ext` selectors
  (`3.days`, `5.minutes`, `"x".squish`, `Time.current`, …) — pure
  config gaps, fixed by wiring the `rigor-activesupport-core-ext`
  RBS bundle. With that bundle: **488 → 88 (−82 %)**.
- The residual 88 were themselves clustered: ~55 nil-receiver
  diagnostics on ActiveRecord associations, ~13 AR query methods
  misinferred on `Array[String]`, a tail of RBS-coverage gaps.

The operational lesson: **the raw diagnostic list is the wrong
first artefact for a newcomer.** A 488-line dump reads as 488
problems; the *useful* reading is "≈360 of these say one thing —
enable one RBS bundle". [ADR-22](22-baseline-and-project-onboarding.md)
addresses the *adoption* half (snapshot the residue as a baseline,
surface only regressions). It does not address the *diagnosis*
half — telling the user which clusters are config gaps, which are
likely project monkey-patches, which are RBS-coverage holes, and
which are the genuine localised bugs worth fixing first.

ADR-22's `rigor-project-init` SKILL phase 7 ("count diagnostics per
rule, suggest rules small enough to fix interactively") and
`rigor-baseline-reduce` phase 1 ("group by rule, sort by count")
*do* this triage today — but ad hoc, as LLM-side counting over the
raw stream. That is non-deterministic, untestable, and re-derived
on every SKILL invocation. The data layer should be a deterministic,
spec-covered command the SKILLs *call*.

## Decision

Add **`rigor triage`** — a `check`-derived subcommand. It runs the
same analysis as `rigor check`, then, instead of the raw per-line
diagnostic stream, emits a three-section report:

1. **Rule-ID distribution** — project-wide histogram of diagnostics
   per `rule`, split by severity.
2. **Hotspot files** — files carrying the most (and most
   concentrated) diagnostics, with their per-rule breakdown.
3. **Heuristic hints** — pattern recognisers over the diagnostic
   stream that name a *likely cause* and a *suggested action* for
   each large cluster (see § "Heuristic catalogue").

`--format json` emits the same content machine-readably for the
ADR-22 SKILLs and other tooling. The command is **read-only and
advisory** — it never edits `.rigor.yml`, never writes a baseline;
acting on its output is the user's (or a SKILL's) decision.

## Working decisions

### WD1 — A subcommand, not a `rigor check` flag

`rigor triage`, parallel to `check` / `baseline` / `lsp` /
`sig-gen` — not `rigor check --triage`.

- The triage report and the raw diagnostic stream are *alternative*
  views, not additive. A `--triage` flag appended to `check` would
  still print the 488-line dump the report exists to replace.
- `rigor check` already spends `--explain` (fallback diagnostics)
  and `--stats` (`RunStats`: file/RBS-class counts). A third
  overloaded flag muddies a crowded surface.
- Discoverability: `rigor --help` listing `triage` alongside
  `check` advertises the onboarding path. A buried flag does not.
- The ADR-22 SKILLs invoke a named subcommand with a stable
  `--format json` contract; that is cleaner than parsing a
  `check` sub-section.

`rigor triage` accepts the same positional `paths` and the same
`.rigor.yml` / `--config` resolution as `rigor check`.

### WD2 — A fixed built-in heuristic catalogue for v1

The recognisers (§ "Heuristic catalogue") ship as a fixed,
Rigor-maintained set. Plugin-contributed recognisers are a
deferred follow-up, NOT v1.

The v1 catalogue is small (six recognisers) and grounded in
concrete survey data; a plugin extension point would be
speculative before the built-in set has proven its shape against
real projects. The catalogue lives in one module so adding a
recogniser is a one-file change.

### WD3 — Recognisers key on `rule` first, message text second

A recogniser's primary key is the structured `rule` identifier
(`call.undefined-method`, `nullable-receiver`, …) — stable across
releases. Where a recogniser additionally needs the *receiver type*
or *method name* (H1/H2/H3/H4 below), v1 extracts them by parsing
the diagnostic **message** (`undefined method 'X' for TYPE`).

This message parsing is acknowledged **fragile** — it couples the
catalogue to message wording, exactly the coupling
[ADR-22 WD1](22-baseline-and-project-onboarding.md) avoids for the
baseline. Mitigations:

- The parse targets only the *prefix shape* of a handful of rules
  (`undefined method 'M' for T`), which has been stable across the
  v0.1.x line — not arbitrary message bodies.
- A recogniser that fails to parse a message degrades to "skip
  this diagnostic", never to a crash or a wrong hint.

The robust fix — giving `Analysis::Diagnostic` optional structured
fields (`receiver_type`, `method_name`) populated by the rules
that have them — was recorded as **slice 4** and is now
**implemented**: the single `call.undefined-method` emission site
(`CheckRules#build_undefined_method_diagnostic`) populates the
pair, and the catalogue reads the fields, falling back to message
parsing only where they are absent. The message-wording coupling
is gone for the engine-emitted path.

### WD4 — Triage is advisory; it does not act

`rigor triage` prints hints; it never edits config or writes a
baseline. Rationale:

- Separation of concerns: triage is *diagnosis*. Editing
  `.rigor.yml` (enabling a plugin, wiring `signature_paths:`) and
  writing `.rigor-baseline.yml` are *treatment* — owned by the
  `rigor-project-init` SKILL (which escalates choices to the user)
  and `rigor baseline generate`.
- A command that silently rewrites config on a read-looking verb
  violates the same "no magic" stance as
  [ADR-22 WD2](22-baseline-and-project-onboarding.md).

The hints therefore phrase actions imperatively for a human/agent
to perform ("add it to `signature_paths:`"), not as auto-applied
edits.

### WD5 — `triage` is the data layer beneath the ADR-22 SKILLs

`rigor triage` and ADR-22 compose as a pipeline:

| Stage | Tool | Question answered |
| --- | --- | --- |
| Diagnose | `rigor triage` | *Why* are there N diagnostics? Which clusters? |
| Decide | `rigor-project-init` / `rigor-baseline-reduce` SKILL | Enable which plugins? Fix / suppress / baseline which rules? |
| Record | `rigor baseline generate` | Snapshot the agreed residue. |

The SKILLs call `rigor triage --format json` instead of counting
the raw stream themselves. ADR-22's `rigor-project-init` phase 7
("surface concentrated rules as likely real bugs") and
`rigor-baseline-reduce` phase 1 ("group by rule, sort by count")
become thin wrappers over the triage JSON — deterministic and
spec-covered, rather than ad-hoc LLM arithmetic.

### WD6 — Triage's volume views route only actionable diagnostics

The distribution, selector, and hotspot sections — the **volume
views** — count only `:error` + `:warning` diagnostics by default.
`:info` is excluded; `--include-info` restores it. The summary line
still reports the full `:info` count, and the text report names how
many were hidden.

This decision came from a 2026-06-21 onboarding field trip (a real
Rails app, `conference-app`). Its `rigor triage` read **267 total —
9 error / 1 warning / 257 info**, and the info was almost entirely
*plugin recognition trace*:

```
plugin.activerecord.model-call:      68   ← "Account.find resolves to Account"
plugin.rails-routes.helper:          67   ← "users_path → GET /users"
plugin.actionpack.helper-call:       62   ← arity-checked route helper
plugin.actionpack.permit-call:       34   ← permit key is a real column
plugin.rails-i18n.translation-call:  13   ← key resolves in en, ja
plugin.actionpack.filter-call:       12   ← before_action method is defined
```

These are positive "Rigor resolved this call" records, not problems.
Emitted at `:info` deliberately, they are valuable in `rigor explain`
/ hover / a cross-plugin fact (the plugins document them as the value
they add). But aggregated into triage they:

- **Bury the signal.** The 10 actionable diagnostics (the real work)
  sit under 257 trace rows; the "main breakdown" reads as plugin
  noise.
- **Invert the hotspot ranking.** A controller ranks as a top hotspot
  because it has the *most successfully-resolved* model / route / i18n
  calls — i.e. the most *working* Rails code, not the most bugs. The
  ranking points away from what to fix.
- **Waste an agent's attention.** In the field trip the agent spent
  three exploration rounds answering "why `model-call: 68`?" only to
  conclude "nothing — that's just Rigor resolving your models."

`:info` carries no `evidence_tier` ([ADR-65 WD2](65-diagnostic-evidence-tier-and-doc-url.md)):
it is not a confidence-bearing true-positive claim, so it does not
belong in the views that route attention. This is re-evaluation
trigger #1 ("the heuristic hints prove more misleading than useful →
reduce") generalised from the hints to the whole volume surface.

Scope decisions:

- **Hints see the full stream**, not the actionable subset. The
  `gem-without-rbs` recogniser (H3) intentionally reads an
  info-severity `rbs.coverage.missing-gem` *notice* (categorically a
  project-level notice, not per-call trace) — a genuinely useful
  onboarding hint that must survive the default. The other
  recognisers key on an error/warning rule.
- **H5 (systemic cluster) and H6 (genuine bugs)** are the only
  count-based, severity-agnostic recognisers, so they alone could read
  recognition trace as a "systemic cluster, one fix clears many" or a
  "likely genuine bug" — frightening working code, the cardinal
  false-positive sin. They are guarded against `:info` unless
  `--include-info` is set.
- **The summary keeps the full counts.** Hiding info from the *views*
  must not hide its *existence*; an onboarding user still learns
  "257 info" and that `--include-info` reveals them.

This is technically a behaviour change to the default `rigor triage`
text and `--format json` output (a new `include_info` JSON field; the
volume views no longer sum to `summary.total` by default), shipped as
the BC-bearing part of v0.2.3.

## Heuristic catalogue (v1)

Six recognisers. Each scans the diagnostic stream, and — when its
pattern matches a cluster above a threshold — emits one hint with
an evidence summary and a suggested action. Every hint is framed
`[likely …]` and the report header states "heuristics — verify
before acting": the recognisers are signal, not verdicts.

| # | Hint | Detection | Suggested action |
| --- | --- | --- | --- |
| H1 | **likely ActiveSupport `core_ext`** | `call.undefined-method`, receiver ∈ core classes (`Integer` / `Float` / `Numeric` / `String` / `Symbol` / `Hash` / `Array` / `Object` / `NilClass` / `Time` / `Date` / `DateTime` / `Range`), method name ∈ the bundled AS-selector set | Wire `rigor-activesupport-core-ext` via `signature_paths:` |
| H2 | **likely a project monkey-patch / refinement** | same method name undefined across ≥ K files (default K=3), receiver is a core class or a project-defined class, method absent from every RBS source | Register the defining file via `pre_eval:` ([ADR-17](17-monkey-patch-pre-evaluation.md)), or add an RBS overlay |
| H3 | **gem ships no RBS** | `call.undefined-method` whose receiver class is attributed (via the dependency-source index) to a `Gemfile.lock` gem with no RBS | `rbs collection install`, or opt the gem into `dependencies.source_inference:` ([ADR-10](10-dependency-source-inference.md)) |
| H4 | **possible ActiveRecord relation misinference** | AR query method names (`where` / `joins` / `includes` / `order` / `distinct` / `group` / `pluck` / …) flagged `call.undefined-method` on a receiver inferred as `Array[...]` | Enable `rigor-activerecord`; if it persists, it is an engine inference gap worth a Rigor-side issue |
| H5 | **systemic single-file cluster** | a single `(file, rule)` bucket with count ≥ threshold | One fix may clear many; or a strong [ADR-22](22-baseline-and-project-onboarding.md) baseline candidate |
| H6 | **likely genuine bugs — review first** | rules with a low total count, scattered across files (not concentrated) | Review these sites first — low-count scattered diagnostics are the localised bugs Rigor caught |

The H1 AS-selector set is the ~50 selectors the
`rigor-activesupport-core-ext` bundle covers. The recogniser SHOULD
derive it by reading that bundle's `sig/` rather than duplicating
the list, so the two never drift (implementation detail for
slice 2).

H2's "absent from every RBS source" and H3's gem attribution both
reuse data the analyzer already holds — the RBS reflection surface
and the `DependencySourceInference` gem-to-class map — so neither
recogniser needs a second analysis pass.

## CLI surface

```
$ rigor triage [paths...]
  → Runs analysis, prints the three-section report (distribution,
    hotspots, hints). Honours .rigor.yml / --config exactly as
    `rigor check`.

  --format text|json   text (default) | machine-readable
  --hints-only         print only the heuristic-hints section
  --top N              hotspot-file count (default 10)
  --no-hints           distribution + hotspots only
  --include-info       route :info into the volume views (WD6;
                       excluded by default — mostly plugin trace)
```

`rigor triage` exits 0 regardless of diagnostic count — it is an
inspection command, not a gate (`rigor check` remains the gate).

### Output sketch — text

```
Diagnostic distribution — 488 total (480 error / 8 warning)
  call.undefined-method     437  ████████████████
  nullable-receiver          31  ██
  always-truthy-condition     8  ▏

Hotspot files
  app/models/status.rb       42  call.undefined-method ×40  nullable-receiver ×2
  app/models/account.rb      27  ...

Hints — heuristics, verify before acting
  [likely ActiveSupport core_ext]  ~287 diagnostics
    undefined-method on Integer/Numeric: days ×34  minutes ×68  hours ×26 …
    → ActiveSupport monkey-patches Numeric. Add rigor-activesupport-core-ext
      to `signature_paths:` in .rigor.yml.
  [likely a project monkey-patch]  12 diagnostics
    `to_widget` undefined on String across 5 files …
    → Register the defining file via `pre_eval:` (ADR-17), or add an RBS overlay.
```

### Output sketch — json

```json
{
  "summary":      { "total": 488, "error": 480, "warning": 8 },
  "distribution": [ { "rule": "call.undefined-method", "count": 437 } ],
  "hotspots":     [ { "file": "app/models/status.rb", "count": 42,
                      "by_rule": { "call.undefined-method": 40 } } ],
  "hints": [
    { "id": "activesupport-core-ext", "confidence": "likely",
      "diagnostics": 287, "evidence": { "...": "..." },
      "action": "Wire rigor-activesupport-core-ext via signature_paths:" }
  ],
  "include_info": false
}
```

When `include_info` is `false` (the default, WD6), the
`distribution` / `selectors` / `hotspots` counts exclude `:info` and
so do not sum to `summary.total`; `summary.info` still reports the
full count.

## Consequences

### Positive

- **Onboarding reads correctly.** A newcomer sees "≈360 of 488 say
  one thing" instead of 488 undifferentiated problems — the single
  biggest friction the survey identified.
- **The ADR-22 SKILLs get a deterministic data layer.** Phase-7 /
  phase-1 counting stops being ad-hoc LLM arithmetic; it becomes a
  spec-covered command with a stable JSON contract.
- **Config-gap diagnosis is tied to the fix.** H1/H3 convert "lots
  of undefined-method noise" into "enable this bundle / install
  this RBS" — actionable, not just descriptive.
- **`triage` + `baseline` are a clean pair.** Triage says what to
  fix vs suppress; baseline records the decision.

### Negative

- **Message-parsing fragility** (WD3) — receiver/method extraction
  couples the recognisers to message wording until slice 4 adds
  structured `Diagnostic` fields. Bounded: parse failure degrades
  to skip.
- **Heuristics can mislead.** A hint is a guess; H2 in particular
  can mistake a repeated genuine typo for a monkey-patch. The
  `[likely …]` framing and the "verify before acting" header are
  load-bearing — the command must never present a hint as a verdict.
- **One more subcommand** on the CLI surface. Mitigated by it being
  the natural onboarding entry point ADR-22 already implies.

### Carry-over

- The plugin-contributed-recogniser extension point (WD2) and the
  structured-`Diagnostic`-fields robustness fix (WD3 / slice 4)
  are deferred, not rejected.

## Implementation slicing

### Slice 1 — `rigor triage` skeleton + distribution + hotspots — LANDED (v0.1.9)

- New `Rigor::CLI` `triage` subcommand reusing `Runner#run`.
- New `Rigor::Triage` module: distribution aggregation +
  hotspot ranking + text / json renderer.
- No hints yet (`--no-hints` behaviour is the whole command).

### Slice 2 — Heuristic catalogue — LANDED (v0.1.9)

- `Rigor::Triage::Hint` recogniser interface + the six H1–H6
  recognisers. H1 derives its selector set from the
  `rigor-activesupport-core-ext` bundle's `sig/`.
- Hints wired into both renderers.

### Slice 3 — ADR-22 SKILL integration — LANDED (v0.1.9)

- `rigor-project-init` phase 7 and `rigor-baseline-reduce`
  phase 1 rewritten to call `rigor triage --format json`.

### Slice 4 — structured `Diagnostic` fields (DONE) + plugin recognisers (deferred)

- **DONE** — optional `receiver_type` / `method_name` on
  `Analysis::Diagnostic`, populated by the `call.undefined-method`
  rule. The catalogue reads the structured pair (falling back to
  message parsing only where absent), removing the WD3
  message-parsing coupling for the engine-emitted path.
- **Deferred** — a `Plugin` hook letting plugins contribute
  recognisers.

## Re-evaluation triggers

1. **The heuristic hints prove more misleading than useful** on
   real projects → reduce the catalogue to distribution + hotspots
   only, or raise every recogniser's confidence threshold.
2. **A fourth ADR-22-family consumer needs the triage JSON** →
   promote the JSON shape to a documented stable contract.
3. **Message wording churn breaks WD3 parsing repeatedly** →
   pull slice 4 (structured fields) forward.

## References

- [ADR-22](22-baseline-and-project-onboarding.md) — baseline
  mechanism + the two onboarding SKILLs `rigor triage` feeds.
- [ADR-17](17-monkey-patch-pre-evaluation.md) — `pre_eval:`, the
  action H2 suggests.
- [ADR-10](10-dependency-source-inference.md) —
  `dependencies.source_inference:`, the action H3 suggests.
- [`docs/notes/20260519-oss-library-survey.md`](../notes/20260519-oss-library-survey.md)
  — the five-project survey that produced the cluster taxonomy.
