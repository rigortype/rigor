# ADR-77 — `rigor doctor` and `rigor upgrade` evidence-routing commands

Status: **Accepted — implemented 2026-06-24 (`8048991c`; `upgrade`
skeleton).** Two additive CLI commands that *route existing evidence*
rather than change default `check` behaviour. `rigor doctor` classifies
already-produced findings (config-resolution warnings, RBS-env health,
strict-plugin recognition, baseline drift) into setup-problem vs clean-run
with a suggested next action; `rigor upgrade` is the
[ADR-50](50-release-engineering-and-stability-strategy.md) WD7 migration
command. Both reuse the existing check / baseline / plugin surfaces, add no
default behaviour change, and (where they emit JSON) carry a stable
structured contract from day one. Compatibility-safe (additive, current
behaviour preserved).

Grounding: the [2026-06-22 strengthening survey](../notes/20260622-rigor-0.2.x-compatibility-safe-strengthening-survey.md)
§7 / P5; [ADR-50](50-release-engineering-and-stability-strategy.md) WD7
(a `rigor upgrade` migration command, deferred until a concrete BC gives
it a target); and [ADR-73](73-skill-driven-user-experience.md), which
shipped `rigor-doctor` and `rigor-upgrade` as **catalogue-only SKILLs**
(no command behind them — `doctor` composes `config_warnings` +
`plugins --strict` + baseline drift by hand). This ADR promotes those
hand-composed flows into first-class commands.

## Context

`rigor check` already produces every datum a diagnosis needs:
`config_warnings` (a `.rigor.yml` that resolves to nothing), the empty-RBS
WARNING banner (`RBS classes available: 0`), `plugins --strict`
recognition, and baseline drift. Today a user (or the `rigor-doctor`
skill) must run several commands and read the output to tell a *broken
setup* (no plugins for a Rails-locked project, a typo'd config key, a
stale baseline) from a *genuinely clean run*. That is exactly the
classify-existing-evidence shape the survey calls the strongest additive
helper.

The CLI dispatch is a frozen-at-v1.0 vocabulary table (`cli.rb:25`,
`HANDLERS`), so a new command is a public-surface addition: it must be
named deliberately and, if it emits JSON, designed as a stable contract.
The reusable runner setup lives in `CheckCommand#build_check_runner`
(today private and coupled to options / buffer / cache) — the same helper
the ADR-73 `describe --deep` follow-up needs — so a shared "run check →
`Analysis::Result`" extraction is the common dependency.

## Decision

### WD1 — `rigor doctor`: classify, don't re-analyze loudly

`rigor doctor` runs (or reuses) the existing project checks and classifies
the findings into a small, fixed report: *setup problems* (config resolves
to nothing, `RBS classes available: 0`, Rails locked but no Rails plugins,
baseline drift) vs *a clean run*, each with a routed next action (point at
`rbs collection install`, `plugin-tune`, `baseline regenerate`,
`pre_eval:`). It is a presentation/aggregation layer over data `check`
already produces — it adds **no** new analysis pass and no new diagnostic
rule. Message wording is presentation; any JSON output (`--format json`)
is a stable structured contract (a `{checks: [{id, status, hint}]}` shape),
not a mirror of the human text.

### WD2 — `rigor upgrade`: the ADR-50 WD7 migration command

`rigor upgrade` is the deferred ADR-50 WD7 command — it applies the
mechanical parts of a version migration (e.g. re-running `baseline
regenerate` against a strengthened default profile, surfacing renamed
suppression ids via `LEGACY_RULE_ALIASES`, reporting `bleeding_edge:`
graduations). It lands when a concrete BC gives it a target; the ADR
records the command's slot and contract now so the `rigor-upgrade` skill
has a command to route to.

### WD3 — Reuse, don't duplicate, the check-runner setup

Both commands consume a shared "run check → `Analysis::Result`" helper
extracted from `CheckCommand#build_check_runner`, so they never diverge
from `rigor check`'s own configuration / plugin / cache resolution. This
extraction is the same one [ADR-73](73-skill-driven-user-experience.md)
§ "Field-trial follow-ups" names for `describe --deep`; the three callers
(`doctor`, `describe --deep`, `check`) share it.

### WD4 — Deep probe is opt-in, never the presence-only default

`rigor doctor` runs a real (scoped) analysis, so it is **not** wired into
the presence-only `rigor skill describe` headline path (ADR-73 WD2 keeps
that side-effect-free). The expensive diagnosis is an explicit command the
user runs; `describe` may *recommend* `doctor` from presence signals but
does not run it.

## Rejected / deferred alternatives

- **Make `doctor`'s deep analysis the default `describe` headline.**
  Breaks ADR-73 WD2's presence-only contract (slow / side-effectful for a
  what-next hint). Rejected — `describe` recommends `doctor`, doesn't
  become it.
- **Duplicate the check-runner setup in each command.** Diverges from
  `rigor check`'s real configuration/plugin/cache resolution over time;
  WD3 shares one helper instead.
- **A separate diagnostics gem / external tool.** Contradicts the single
  bundled-gem model ([ADR-31](31-contribution-and-supply-chain-policy.md));
  the evidence already lives in the gem.
- **Add a new diagnostic rule for "setup problem".** `doctor` is an
  aggregation/presentation layer, not a new analysis; inventing a rule id
  would multiply vocabulary for a routing view.

## Consequences

- **Positive:** turns multi-command, read-the-output diagnosis into one
  routed command; gives the ADR-73 `rigor-doctor` / `rigor-upgrade`
  catalogue skills a real command to delegate to; forces the
  `build_check_runner` extraction that also unblocks `describe --deep`.
- **Negative:** two new entries in the v1.0-frozen `HANDLERS` vocabulary
  and a new JSON contract to keep stable; `upgrade`'s body waits on a
  concrete migration target.
- **Carry-over:** the shared check-runner helper (WD3) is the reusable
  artifact; the `doctor` check set is intentionally small for v1 and grows
  by demand-gated classifier branches.

## Relationship to other ADRs

- [ADR-50](50-release-engineering-and-stability-strategy.md) — `rigor
  upgrade` is WD7; the new command vocabulary freezes at v1.0 under WD1.
- [ADR-73](73-skill-driven-user-experience.md) — the catalogue-only
  `rigor-doctor` / `rigor-upgrade` skills these commands back; shares the
  `build_check_runner` extraction with `describe --deep`.
- [ADR-23](23-diagnostic-triage-command.md) / [ADR-33](33-mcp-server.md) /
  [ADR-51](51-ci-diagnostic-output-formats.md) — prior additive-command /
  structured-output precedents.
