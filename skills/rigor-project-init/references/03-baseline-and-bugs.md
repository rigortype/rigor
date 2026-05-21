# 03 — Triage, baseline, and surfacing real bugs

Covers **Phase 5** (triage), **Phase 6** (baseline — acknowledge mode
only), and **Phase 7** (real bugs + escalation).

## Phase 5 — Triage the diagnostic stream

Do **not** read the raw `rigor check` output to decide what to do. A
mature codebase's raw stream is hundreds of lines and reads as
hundreds of unrelated problems — it is the wrong first artefact. Run
the triage command instead:

```sh
rigor triage --format json
```

`rigor triage` runs the same analysis as `rigor check`, then returns
a structured summary instead of the per-line dump. It is read-only
and advisory — it never edits config and never writes a baseline.
The JSON shape:

```json
{
  "summary":      { "total": 489, "error": 480, "warning": 9, "info": 0 },
  "distribution": [ { "rule": "call.undefined-method", "count": 437 } ],
  "hotspots":     [ { "file": "app/models/status.rb", "count": 42,
                      "by_rule": { "call.undefined-method": 40 } } ],
  "hints": [
    { "id": "activesupport-core-ext", "confidence": "likely",
      "diagnostic_count": 365, "summary": "...", "action": "..." }
  ]
}
```

Use the three sections like this:

- **`summary` / `distribution`** — the scale, and which rules
  dominate. Decides nothing on its own; feeds the mode sanity-check
  (>100 errors → acknowledge mode is the right default).
- **`hotspots`** — files carrying the most diagnostics. A single hot
  file is often one structural cause, not many bugs.
- **`hints`** — the heuristic catalogue. Each hint names a *likely
  cause* and a *suggested action*. They are signal, not verdicts —
  the `confidence` field is `likely` or `possible`; verify before
  acting.

### Hint catalogue → what to do

| Hint `id` | Cause | Where this skill handles it |
| --- | --- | --- |
| `activesupport-core-ext` | ActiveSupport core-class monkey-patches not loaded. | Go back to Phase 3/4: add `rigor-activesupport-core-ext` to `plugins:` (it is an RBS-bundle plugin), re-run triage. This is a config gap, not a bug. |
| `gem-without-rbs` | A dependency ships no RBS. | Phase 7 escalation — `rbs collection install`, or `dependencies.source_inference:`, or open a Rigor issue. |
| `project-monkey-patch` | An in-project monkey-patch / refinement Rigor did not see. | Phase 7 escalation — register the defining file via `pre_eval:`, or (if it is a DSL) write a project plugin. |
| `activerecord-relation-misinference` | An ActiveRecord relation inferred as `Array`. | Ensure `rigor-activerecord` is enabled (Phase 3). If it persists, it is an engine gap — open a Rigor issue. |
| `systemic-file-cluster` | One file × one rule, large count. | Acknowledge mode: a clean baseline bucket. Strict mode: a single fix may clear many — review that file first. |
| `genuine-bugs` | Low-count rules scattered across files. | **Phase 7** — these are the localised bugs Rigor caught. Review first, in both modes. |

If triage flags `activesupport-core-ext` (or any config gap),
**fix the config and re-run `rigor triage` before continuing**. The
baseline and the real-bug review should both run against the
post-config diagnostic set, not the inflated one.

## Phase 6 — Generate the baseline (acknowledge mode only)

**Strict mode skips this phase entirely.** A strict project has no
baseline; every diagnostic stays live.

In acknowledge mode, snapshot today's diagnostics:

```sh
rigor baseline generate
```

This writes `.rigor-baseline.yml` at the project root — one
`(file, rule, count)` bucket per cluster. The command refuses to
overwrite an existing baseline without `--force`.

Then **wire it into the config**. Per Rigor's no-magic rule, the
baseline file does nothing until `.rigor.dist.yml` names it. Add (or
uncomment) the line written in Phase 4:

```yaml
baseline: .rigor-baseline.yml
```

`rigor baseline generate` prints a note reminding you of this if the
config does not yet declare `baseline:`. Do both edits — generate and
wire — in one step so the user never has a generated baseline that
silently does nothing.

How the baseline behaves afterwards (acknowledge mode's whole point):

- A `(file, rule)` bucket is silenced while its live count stays at
  or below the recorded number.
- If a commit pushes a bucket *over* its recorded count, **every**
  diagnostic in that bucket surfaces — the bucket is now a regression
  to review.
- New `(file, rule)` pairs that were not in the baseline surface
  immediately.

So ordinary coding cannot quietly grow the diagnostic count: the
baseline is a ceiling, not a blanket. Reducing it later is the
`rigor-baseline-reduce` skill's job.

Commit `.rigor-baseline.yml` — it documents project state.

Print the suppression summary for the user: "N diagnostics recorded
as baseline; M will surface on subsequent runs."

## Phase 7 — Surface real bugs & offer escalation

The triage `genuine-bugs` hint (and any low-count, scattered rule in
`distribution`) points at the diagnostics most likely to be **actual
bugs** — a `nil`-receiver crash on a rarely-exercised line, a typo'd
method. In **both modes**, surface 2–3 of these to the user and offer
to walk them: a small, scattered rule is rarely systemic.

In acknowledge mode these still went into the baseline — that is
fine; the baseline is a starting envelope, not a verdict that the
bug is acceptable. Recommend the user run the `rigor-baseline-reduce`
skill next to work them down.

### Escalation path A — application-specific metaprogramming

If triage reports `project-monkey-patch`, or a `call.undefined-method`
cluster lands on the project's own DSL / `define_method` factory /
in-house macro, Rigor cannot follow it by default. Two answers,
cheapest first:

1. **A plain monkey-patch in a known file** (e.g.
   `lib/core_ext/string_extensions.rb`) — register it via `pre_eval:`
   in `.rigor.dist.yml`. Rigor walks those files before per-file
   inference, so the added methods become visible.
2. **A genuine project DSL** — the durable fix is a **project-private
   Rigor plugin** that teaches Rigor the DSL's shape. Offer to hand
   off to the `rigor-plugin-author` skill. The plugin can live under
   the project's own `lib/` (loaded without a gemspec) or as a
   separate `rigor-<name>` gem.

### Escalation path B — an unsupported external gem

If triage reports `gem-without-rbs`, a dependency ships no type
information and Rigor has no built-in coverage. In order:

1. `rbs collection install` — pulls community RBS for the gem if it
   exists. Re-run triage afterwards.
2. `dependencies.source_inference:` in `.rigor.dist.yml` — opt the
   gem into Rigor inferring `Dynamic`-typed returns from its source.
3. If the gem is widely used and genuinely warrants first-class
   support, **open an issue on the Rigor project** so the maintainers
   can ship a plugin or RBS bundle:
   <https://github.com/rigortype/rigor/issues>. Include the gem name,
   version, and a sample of the diagnostics.

Neither escalation is mandatory — offer them when triage points at
the cause; the user decides whether to act now or defer.

## Output of this module — onboarding complete

- A committed `.rigor.dist.yml`.
- Acknowledge mode: a committed `.rigor-baseline.yml` + an active
  `baseline:` line. Strict mode: neither.
- The user has seen the likely real bugs and knows the two escalation
  paths.

Next sessions: `rigor-baseline-reduce` to work the baseline down
(acknowledge mode), or `rigor-plugin-author` if escalation path A
applies.
