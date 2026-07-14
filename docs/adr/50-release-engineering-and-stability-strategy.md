# ADR-50 — Release engineering and stability strategy (v0.2.0 → v1.0.0)

Status: **Proposed, 2026-06-05.** Records the strategy for taking Rigor
from the v0.1.x feature-development line to an enterprise-safe stable
product, with **v0.2.0 as the release-engineering trial milestone** (not a
contract freeze) and **v1.0.0 as the hard contract freeze**. The governing
axis is enterprise adoption: **no breaking change and no performance
regression** within a release line, at a quality the user can pin and
trust. The reference model throughout is **PHPStan** — Rigor already
mirrors its plugin/type architecture (ADR-0/1/2), so mirroring its release
engineering (the `bleedingEdge` opt-in, the `N.x` support-branch model) is
the coherent continuation. Implementation is staged (the perf gate, the
bleeding-edge flag, the support-line policy, the public-surface document);
this ADR pins the decisions, not the code.

Several of the working decisions below propose a *concrete shape* (the
bleeding-edge overlay, the perf thresholds, the backport/Ruby interaction)
that is open to adjustment — flagged **(proposed shape)** where so. The
ADR follows its own trial-then-freeze model: it **stays `Proposed`
through the v0.2.0 line** (which is the rehearsal that informs the final
shape) and is **ratified at v1.0.0**, when the contract is fixed.

## Context

### The enterprise axis

An enterprise user pins a Rigor version in CI and expects two guarantees
across a minor upgrade: (a) the build does not newly fail on code that
passed — neither from an API change *nor* from a diagnostic that did not
fire before; and (b) analysis does not get materially slower or hungrier.
Rigor is a correctness tool in the CI critical path, so a regression in
either dimension is a trust-eroding event, not a cosmetic one.

### The parts already exist; ADR-50 assembles them into a contract

The mechanisms a stable-release strategy needs are mostly built:

- **Diagnostic-churn absorption** — the baseline mechanism + severity
  profiles ([ADR-22](22-baseline-and-project-onboarding.md),
  [ADR-8](8-steep-inspired-improvements.md)); the established convention
  that new / strengthened rules ship `:off` or `:info` and earn promotion
  only behind a corpus FP gate ([ADR-24](24-self-method-call-resolution.md),
  [ADR-47](47-narrowing-driven-clause-reachability.md) WD4).
- **Corpus validation** — the OSS-corpus FP sweep
  ([ADR-47](47-narrowing-driven-clause-reachability.md) WD4 swept 16) and
  the [`rigor-regression-sweep`](../../.claude/skills/rigor-regression-sweep/SKILL.md)
  skill (multi-version baseline-drift); the self-check gates
  (`make check` / `check-plugins` / `check-incremental`).
- **Performance instrumentation** — profiling harnesses and corpus runs on
  Mastodon / Redmine / GitLab ([ADR-44](44-dispatch-allocation-churn.md),
  [ADR-45](45-unchanged-project-fast-path.md),
  [ADR-46](46-incremental-dependency-graph.md)).
- **Distribution / supply-chain** — latest-Ruby-only, not-in-`Gemfile`
  ([ADR-27](27-tool-distribution-model.md)); contribution policy
  ([ADR-31](31-contribution-and-supply-chain-policy.md)).

What is missing is the **contract that binds them to a release**: a stated
public surface, a committed perf gate, a deprecation/bleeding-edge policy,
and a support-line model. That is ADR-50's scope.

### Reconciling the freeze-timing inconsistency

Three ADRs disagree on when the plugin contract freezes:
[ADR-25](25-plugin-contributed-rbs.md) WD6 and
[ADR-32](32-rbs-inline-comment-ingestion.md) WD8 say "the contract surface
**v0.2.0** freezes"; [ADR-37](37-plugin-interface-segregation.md) says
"hook signatures freeze as a public contract at **1.0**." **ADR-50 is the
authority and resolves it in favour of ADR-37:** the hard freeze is
**v1.0.0**. v0.2.0 *begins enumerating* the surface and pledges
minor-non-break as the trajectory, but does not freeze — the inference
engine is still evolving and an early freeze would trade the product's core
(deep inference precision) for a premature guarantee. ADR-25/32's wording
should be read as "the surface v1.0.0 freezes; v0.2.0 begins it" (a
follow-up may amend their text).

## Decision

The strategy has four pillars, each PHPStan-shaped.

### 1. v0.2.0 is a trial; v1.0.0 is the freeze

**v0.2.0** ships the *release-engineering machinery* (the perf gate, the
support policy, the bleeding-edge flag, a drafted public-surface document)
and pledges **minor-non-break on the enumerated public surface** as the
operating discipline — a rehearsal of the v1.0.0 contract, run while the
engine still evolves. **v1.0.0** is the hard freeze: the public surface
(§ WD1) becomes binding under the compatibility policy below.

### 2. Compatibility: public surface frozen, engine internals free

A change is a **breaking change** when it alters the enumerated public
surface (§ WD1) in a way that invalidates a conforming user's
configuration, plugin, or suppression. Engine internals
(`lib/rigor/inference/*`, `Scope`, the `Type::*` carriers, dispatch tiers)
are **explicitly not public** and may change in any release — the same
internal/public split ADR-19 already relies on for the LSP.

### 3. Diagnostics: output is non-contract, *new disciplines* are gated

The *set of diagnostics that fire* is **not** part of the compatibility
contract — strengthening a rule so it reports a genuine error it
previously missed is allowed in a **minor**, and the baseline
([ADR-22](22-baseline-and-project-onboarding.md)) is the standing absorber.
**But** a change that requires the user to **comply with a new discipline
they were not previously held to** *is* a breaking change, and ships
**off by default behind a PHPStan-style bleeding-edge opt-in** until the
next major turns it on. (§ WD2 / WD3 draw the line.) What *is* contract on
the diagnostic surface is the **stable vocabulary**: rule identifiers,
suppression markers (`# rigor:disable <id>`), the baseline format, and the
`severity_overrides:` keys — so a user's suppressions and baseline keep
working across the upgrade even as firings change.

### 4. Performance: a committed benchmark gate

"No perf regression" is enforced **mechanically** by a committed benchmark
harness run as a CI gate against the established OSS corpora, comparing
against a stored baseline within a tolerance band; a regression past the
band fails the build (§ WD4).

### 5. Support: latest + previous minor, then the `1.x` branch model

Pre-1.0: the **latest minor + the immediately-preceding minor** are
supported (security + regression backports). Post-1.0: switch to PHPStan's
model — the `1.x` branch becomes the default development line and the
supported-line policy follows it (§ WD5).

## Working decisions

### WD1 — The enumerated public surface (contract vs internal)

The v1.0.0 contract (enumerated, drafted at v0.2.0) covers:

| Surface | Contract at v1.0.0 |
| --- | --- |
| CLI commands + flags (`check`, `triage`, `baseline`, `sig-gen`, `lsp`, `mcp`, …) | yes |
| `.rigor.yml` keys + value grammar | yes |
| Plugin contract — `Plugin::Base` hooks + the manifest fields (ADR-37's `node_rule` / `dynamic_return` / `type_specifier` + the declarative fields) | yes (the ADR-37 narrow protocols; the deprecated fat hooks per WD3) |
| Diagnostic **identifiers** + suppression markers + `severity_overrides:` keys | yes (the *vocabulary*, not the firing set — § Decision 3) |
| Baseline file format + cache schema version | yes (format; schema bumps invalidate, never mis-read) |
| `RBS::Extended` annotation grammar (`%a{rigor:v1:…}`) | yes |
| Engine internals (`Inference::*`, `Scope`, `Type::*`, dispatch tiers) | **no — internal, may change any release** |
| Which diagnostics fire on a given file | **no — § Decision 3** |
| `rigor sig-gen` *output precision* (the inferred shapes) | **no — precision improves freely** |

The drift specs already pin much of this (`public_api_drift_spec.rb`); WD1
is the human-readable companion the release doc publishes.

### WD2 — Bleeding-edge as an inspectable, granular overlay (proposed shape)

Bleeding-edge is a **Rigor-maintained overlay of default-overrides** — the
set of the next major's queued changes (severity-map promotions +
new-discipline rule enablements), versioned with the gem, **not** a
user-supplied config-file path. It keeps PHPStan's "the diff is explicit"
benefit (PHPStan's `bleedingEdge` *is* a readable default-override include)
while fitting Rigor's YAML-plus-plugin surface rather than a `.neon`
include. Three properties:

- **Inspectable.** `rigor show-bleedingedge` (working name) prints the
  overlay as an explicit diff against the current defaults — every rule /
  severity / discipline it would change, each with its feature id. This is
  the transparency PHPStan gets from a readable include file, delivered as
  a command rather than a path.
- **Granular + explicit opt-in.** `.rigor.yml` `bleeding_edge:` accepts
  `true` (adopt the whole overlay), a **list of feature ids** (adopt only
  those), or `{ all: true, except: [...] }` (adopt all but the named) — so
  a user pulls in exactly the advanced features they want, not an
  all-or-nothing switch. `--bleeding-edge[=ids]` mirrors it on the CLI.
- **Orthogonal to `severity_profile:`.** Profile = how loud *today's*
  rules are; bleeding-edge = which of the *next major's* queued changes you
  adopt early. The two compose.

Each bleeding-edge feature carries a **stable feature id**, part of the
contract vocabulary (WD1): the `show` subcommand, the config, and the
eventual CHANGELOG migration note all name the same id, and a feature
graduates to default-on at the next major by being removed from the
overlay. This gives a new discipline a real landing path — ship it in the
overlay in minor N (early adopters + Rigor's own CI exercise it by id),
default it at the major with a migration note keyed on that id.

(Resolves the WD2 deliberation toward an inspectable overlay + per-feature
granularity over a single boolean — it preserves PHPStan's explicit-diff
transparency without a real include path, and lets users adopt advanced
features one at a time. The rejected alternative — folding bleeding-edge
into a fourth `severity_profile` value — still stands: it would conflate
loudness with the discipline-set and lose both the granularity and the
explicit diff.)

**First feature queued (v0.3.0): `reject-unparseable-signatures`.** An
unparseable `.rbs` under `signature_paths:` is quarantined so the rest of
the env survives, which makes the run *quieter* rather than cleaner — the
types that file declared are simply gone. It is reported by default as the
`:warning` `rbs.coverage.quarantined-signature`; the feature promotes it to
`:error`, and that is the intended default at the next major. It is the
worked example of the WD3 rule: **rejecting a previously-accepted input is
a new required discipline, so it ships off-by-default behind the overlay
rather than turning a green build red on upgrade** — the more so because
ADR-79 keeps Rigor faithful to the project's own `rbs` gem, whose parser
can newly reject a file across versions. Its id also sets the style:
kebab-case, naming the *discipline* rather than the rule it happens to
promote, so a discipline can grow to cover more rules without its
contract-vocabulary id going stale.

**Foundation landed (v0.1.19).** The WD2 *surface* was wired end-to-end
before any discipline was queued: `Rigor::BleedingEdge` is the maintained `Feature` registry
(stable id + summary + a `severity_overrides` map); `.rigor.yml`
`bleeding_edge:` accepts `true` / a feature-id list / `{ all:, except: }`,
normalised and exposed on `Configuration`; `rigor show-bleedingedge`
prints the overlay + what the project adopts (`--format text|json`); and
`Configuration::SeverityProfile.resolve` gained a
`bleeding_edge_overrides:` map composed *below* the user's own
`severity_overrides:` (exact or family) and *above* the profile table.
With the registry empty the composed map is `{}`, so resolution stays
bit-for-bit unchanged — the first queued discipline lands as a single
`FEATURES` entry with no further engine plumbing.

**CLI mirror landed (Unreleased).** `rigor check --bleeding-edge[=ids]`
/ `--no-bleeding-edge` override the configured `bleeding_edge:` selection
for a single run (same CLI-over-config precedence as `--workers` /
`--no-cache`). Rather than thread a parallel override through every
`Runner` construction site (and across the worker boundary), the CLI
rebuilds the loaded `Configuration` via a new `Configuration#with_bleeding_edge`
— a frozen `dup` that re-derives `bleeding_edge_severity_overrides` — so
the two `SeverityProfile.resolve` sites and the worker path see the run's
selection unchanged, keeping `Configuration` the single source of truth.
The flag uses OptionParser's `=[LIST]` (attached-value-only) form so a bare
`--bleeding-edge lib` adopts the overlay and checks `lib` rather than
consuming the path. Surfacing the list form also frozen-ized the selector
ids in `coerce_bleeding_edge`, restoring `Ractor.shareable?` for the
config-file list path. **Not yet shipped:** the dedicated bleeding-edge
CHANGELOG section (no entries to carry yet — it lands with the first
queued feature).

### WD3 — What counts as a breaking diagnostic change (the discipline test)

The line between "allowed minor strengthening" and "BC-breaking new
discipline":

- **Allowed in a minor (non-contract output):** a rule that fires on code
  which was *already* in its remit and is a genuine error (a missed
  nil-receiver, a real undefined-method), or any new rule that ships
  `:off` / `:info`. Absorbed by the baseline; no new authoring burden.
- **BC — gate behind bleeding-edge:** a change that makes previously-clean,
  *idiomatic* code fail under the **default** profile by requiring a new
  authoring discipline (e.g. demanding an annotation, a narrower idiom, or
  a structural change the user was never asked for). These land off-by-
  default behind `bleeding_edge:` and turn on only at a major.

The corpus FP sweep ([ADR-47](47-narrowing-driven-clause-reachability.md)
WD4) is the instrument that classifies a candidate: zero firings on the
idiomatic corpus → it is a strengthening, not a new discipline.

### WD4 — Performance gate (proposed shape)

- **Harness:** a `make bench-perf` target running the analyzer over fixed
  subsets of the established corpora (Mastodon `app/models`, Redmine `app`,
  a GitLab `app/{controllers,services,…}` subset — the trees ADR-44/45/46
  already profile), `--no-cache`, fixed worker count.
- **Metrics:** wall time, total allocations (`ObjectSpace`), peak RSS, and
  diagnostic count (a *count* change flags an unintended behaviour shift —
  the byte-identical-diagnostics check ADR-44/45/46 already use).
- **Baseline + thresholds are committed, tunable artifacts.** A committed
  `bench/baseline.json` (per corpus, per metric) and a committed tolerance
  band (`bench/thresholds.yml` or co-located) — **both deliberately
  refreshable, never silently**. The band is *not* hard-coded in engine
  code precisely so it can be tuned to runner / corpus reality as it
  shifts; changing it is a reviewed commit, like a snapshot refresh.
- **Gate:** a CI job fails when any metric regresses past the committed
  tolerance band. The **initial** band (tunable per above): wall +10 %,
  allocations +5 %, RSS +10 % — wider on wall for runner noise, tighter on
  allocations as the deterministic signal. A *win* past the band prompts a
  baseline refresh, not a failure.
- Not in the local `make verify` fast path (too slow); a dedicated CI job,
  like `check-incremental` (ADR-46).

### WD5 — Support line + the latest-Ruby-only interaction

- **Pre-1.0:** latest minor + the immediately-preceding minor receive
  security + regression-fix backports; everything older is
  pin-and-upgrade. Two lines, bounded backport cost.
- **Post-1.0:** the `1.x` branch is the default development line (PHPStan's
  model); the support window follows it. The major-version cadence is where
  bleeding-edge disciplines (WD3) become default and any frozen-surface
  break (WD1) is allowed.
- **Ruby floor (reconciling [ADR-27](27-tool-distribution-model.md)):** a
  backport targets the **Ruby version its line already shipped with** — it
  does not widen the Ruby floor, and Rigor stays latest-Ruby-only *for the
  development line*. A supported previous-minor line keeps its own Ruby
  pin; it is not retro-fitted to a newer Ruby. So latest-Ruby-only and a
  two-line support window coexist without conflict.

### WD6 — The release acceptance gate (what must be green to cut a release)

A release candidate must pass, in addition to `make verify`
(`test`/`lint`/`check`/`check-plugins`):

1. `make check-incremental` (ADR-46 soundness gate).
2. The corpus **FP sweep** — zero *new* diagnostics on the frozen-baseline
   corpora vs the previous release (the `rigor-regression-sweep` shape).
3. The **perf gate** (WD4) — within the tolerance band.
4. The **public-surface drift spec** green (no unintended contract change).

This composes with [`rigor-release-prep`](../../.claude/skills/rigor-release-prep/SKILL.md)
(version bump + CHANGELOG + build) — that skill gains a pre-flight step
that runs this gate. The version-bump discipline (no autonomous bumps,
single-digit components, release-style CHANGELOG at landing) is unchanged.

**Mechanism (landed, advisory).** The gate is operationalized as a
`release/x.y.z` branch + a `release-gate.yml` workflow: pushing the branch
runs the base CI gate (`ci.yml`, which now also triggers on `release/**`)
plus the comprehensive extras — the `make bench-perf` perf gate (WD4), a
gem-build validation, and the OSS-corpus sweep (Mastodon today;
data-driven, so Redmine / GitLab are a threshold-file addition away). Per
the trial-then-freeze spine, the comprehensive gate ships **advisory**
(reports, does not block — no required-check wiring, perf/sweep stages run
`continue-on-error`) and hardens to required once its baselines
(`bench/baseline.json`, the sweep thresholds) calibrate against CI numbers.

### WD7 — Deprecation + graduation cadence

A bleeding-edge feature (WD2) graduates to default-on — by being removed
from the overlay — at a **semver major** release, after a **~4-week soak**
as the guideline minimum. The soak is a floor, not a schedule: a feature
that should become default quickly can trigger an earlier major, while one
with no urgency simply rides the next major whenever it is cut. Graduation
is **bundled, not solo-per-feature** — a major turns on *every* overlay
feature that has cleared its soak, and a major is cut either to graduate an
important discipline *or* because some other BC factor (a frozen-surface
change, WD1) already forces one. Majors are therefore **BC-readiness-driven,
not calendar-driven**; their cadence is whatever the queue of soaked
disciplines + surface breaks warrants.

This is close to PHPStan's model — PHPStan promotes its entire bleedingEdge
set to default at each *minor* (`x.y → x.y+1`) — but tied to Rigor's
**major**, because Rigor classes a newly-required discipline as a breaking
change (§ Decision 3) and breaking changes are major-only post-1.0.

**Pre-1.0 (the v0.2.0 trial) rehearses this at minor bumps:** a
bleeding-edge feature may graduate at a `v0.2.x → v0.3.0` step, since the
0.x line does not yet carry the freeze. The cadence hardens to major-only
at v1.0.0 — the same trial-then-freeze spine as the rest of the ADR.

**CHANGELOG.** Bleeding-edge changes get their **own dedicated CHANGELOG
section** (PHPStan keeps `bleedingEdge` separate), so a reader sees the
opt-in-now / default-next-major set at a glance, keyed on the WD2 feature
ids. The exact format is deferred — recorded here as the direction, not the
template.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| Full SemVer 1.0 freeze at v0.2.0 | Rejected | The inference engine is still evolving; freezing now trades the product's core (deep-inference precision) for a premature guarantee. v0.2.0 rehearses, v1.0.0 freezes. |
| Diagnostic output as a hard contract (no new firings in a minor) | Rejected | Would freeze precision/bug-catching improvements — Rigor's whole value. The bleeding-edge gate (WD2/3) protects enterprises from *new disciplines* while letting genuine strengthenings flow. |
| Perf as informational telemetry, no hard gate | Rejected | Does not meet the no-regression axis; a regression must fail the build, not be noticed later. |
| Bleeding-edge as a fourth `severity_profile` value | Rejected (WD2) | Conflates loudness (profile) with discipline-set (bleeding-edge); loses PHPStan parity and the orthogonality that makes both knobs composable. |
| LTS with long backport windows | Deferred | The two-line (latest + previous-minor) window is the bounded-cost start; a longer LTS is revisited if enterprise demand and maintainer capacity justify it post-1.0. |
| A single fat `rigor check --strict-everything` enterprise mode | Rejected | The composition of `severity_profile` + `bleeding_edge` + baseline already expresses every enterprise posture; a monolithic mode would duplicate them. |
| A `rigor upgrade` migration-assist command (detect deprecated config / stale baseline / queued graduations, guide the version step) | Deferred (planned) | Desirable, and the natural home for the upgrade UX; but best designed against a *concrete* first breaking change rather than speculatively. Planned as future work, specced when the first real BC arrives. |

## Consequences

Positive:

- An enterprise can pin a minor and upgrade within the line without a
  build-breaking surprise from either API or *required* diagnostic
  discipline; genuine bug-catches still flow and are absorbed by the
  baseline.
- "No perf regression" becomes a mechanical CI fact, not a hope.
- The PHPStan-shaped `bleeding_edge:` gives new disciplines a real landing
  path that does not break the default line — and gives early adopters a
  way to pre-test the next major.
- The freeze-timing inconsistency (ADR-25/32 vs ADR-37) is resolved with a
  single authority.

Negative / cost:

- A second supported line is real backport work (bounded to one prior
  minor pre-1.0).
- The perf gate adds CI time and a maintained baseline artifact (one more
  thing to refresh deliberately).
- The `bleeding_edge:` flag is a new public-surface knob to document and,
  itself, keep stable.

## Relationship to other ADRs

- **ADR-37 / ADR-25 / ADR-32** — ADR-50 resolves their freeze-timing
  wording (hard freeze = v1.0.0; v0.2.0 begins enumeration).
- **ADR-22 / ADR-8** — the baseline + severity-profile machinery this
  strategy leans on for diagnostic-churn absorption; `bleeding_edge:` is
  the orthogonal third knob.
- **ADR-27** — the distribution model; WD5 reconciles latest-Ruby-only with
  the two-line support window.
- **ADR-44 / ADR-45 / ADR-46** — the profiling/measurement work the WD4
  perf gate turns into a committed CI gate.
- **ADR-47** — its corpus FP-sweep methodology is the instrument WD3 uses
  to classify "strengthening vs new discipline" and WD6 uses as a release
  gate.
- **ADR-31** — supply-chain/contribution policy; release engineering
  operates within it.
- **`rigor-release-prep` / `rigor-regression-sweep` skills** — the WD6
  acceptance gate is wired into release prep; the sweep skill is the FP-gate
  instrument.
