# Compatibility and the public surface

Status: **Trial (v0.2.0 evaluation line; the enumerated surface below is committed as a minor-non-break discipline — a rehearsal of the v1.0.0 freeze).**

This is the human-readable companion to [ADR-50](adr/50-release-engineering-and-stability-strategy.md)
(release engineering and stability strategy) — the document the
release publishes so a user can see, in one place, **what surface
Rigor commits to keeping stable, what it deliberately keeps free to
change, and from which release each guarantee binds.** ADR-50 is the
authority; if this file disagrees with it, the ADR binds and this file
is out of date. The machine-enforced subset of this surface is pinned
by [`spec/rigor/public_api_drift_spec.rb`](../spec/rigor/public_api_drift_spec.rb)
(see [§ Machine enforcement](#machine-enforcement)); for the
plugin-author view of those pinned namespaces, see
[`docs/internal-spec/public-api.md`](internal-spec/public-api.md).

## Where we are on the trajectory

Rigor follows a **trial-then-freeze** path (ADR-50 § Decision 1):

| Line | What stability means here |
| --- | --- |
| **`0.1.x` — preview** | The surface was still *extending*, and a breaking change to it was allowed within the line. This document **enumerated** the surface so the freeze has a target; it did not yet bind. (E.g. [ADR-60](adr/60-pre-freeze-plugin-contract-consolidation.md) intentionally took the last-window plugin-contract BC breaks in this line.) |
| **`v0.2.0` — evaluation trial (current)** | The first version that **pledges minor-non-break on the enumerated surface** as an operating discipline — a rehearsal of the v1.0.0 contract, run while the inference engine still evolves. The surface is enumerated and committed-to-as-a-trial, not frozen. |
| **`v1.0.0` — hard freeze** | The enumerated surface below becomes **binding** under the compatibility policy. A change that invalidates a conforming user's configuration, plugin, or suppression is a breaking change and is major-version-only from here. |

So today (the `v0.2.0` cut) this is a **committed trial**: the
enumerated surface below is the discipline Rigor pledges to keep
minor-non-break, and v1.0.0 will freeze it. Pin a specific Rigor version
while the engine still evolves through the trial.

## The compatibility model

Two principles draw the line between what binds and what stays free
(ADR-50 § Decisions 2 and 3):

1. **Public surface frozen, engine internals free.** A change is
   *breaking* only when it alters the enumerated public surface (below)
   in a way that invalidates a conforming user's configuration, plugin,
   or suppression. The inference engine — `Rigor::Inference::*`,
   `Rigor::Scope`'s internal mechanism, the `Rigor::Type::*` carriers,
   the dispatch tiers — is **explicitly not public** and may change in
   any release. (The same internal/public split [ADR-19](adr/19-language-server-packaging.md)
   already relies on for the LSP.)

2. **Diagnostic output is non-contract; the diagnostic *vocabulary*
   is.** *Which* diagnostics fire on a given file is **not** part of the
   compatibility contract — strengthening a rule so it reports a genuine
   error it previously missed is allowed in a minor, and the
   [baseline](manual/06-baseline.md) is the standing absorber. What *is*
   contract is the stable **vocabulary** a user's configuration and
   suppressions are written against: rule identifiers, the suppression
   markers, the baseline format, and the `severity_overrides:` keys — so
   those keep working across an upgrade even as firings change. A change
   that would force the user to **comply with a new authoring discipline
   they were not previously held to** is treated as breaking and lands
   off-by-default behind the `bleeding_edge:` opt-in until a major turns
   it on (ADR-50 § WD2/WD3). The opt-in mechanism is wired
   (`bleeding_edge:` config + the `rigor show-bleedingedge` inspector);
   the overlay it draws from is empty today, so nothing is gated yet.

## The enumerated public surface

Each row points to the **authoritative enumeration** (the source of
truth, which this document does not duplicate so it cannot drift) and
the **user-facing reference**. The "Contract" column states when the
row binds and what the guarantee is.

| Surface | Authoritative enumeration | User reference | Contract |
| --- | --- | --- | --- |
| **CLI commands + flags** (`check`, `triage`, `baseline`, `sig-gen`, `lsp`, `mcp`, `annotate`, `type-of`, `coverage`, `plugins`, `plugin`, `skill`, …) | `CLI::HANDLERS` + the per-command `OptionParser` in [`lib/rigor/cli.rb`](../lib/rigor/cli.rb) and `lib/rigor/cli/` | [Manual ch. 2 — CLI reference](manual/02-cli-reference.md) | **yes** — a documented command/flag keeps its name and meaning; removal/rename is breaking |
| **`.rigor.yml` keys + value grammar** | `Configuration::DEFAULTS` + the coercers in [`lib/rigor/configuration.rb`](../lib/rigor/configuration.rb) | [Manual ch. 3 — Configuration](manual/03-configuration.md) | **yes** — a documented key keeps its name, shape, and default semantics |
| **Plugin contract** — `Plugin::Base` hooks + manifest fields (the [ADR-37](adr/37-plugin-interface-segregation.md) narrow protocols: `node_rule` / `dynamic_return` / `narrowing_facts` (renamed from `type_specifier` in ADR-80; the old verb, its reader, its engine consumer, and its `rigor plugins --capabilities` key were all removed in 0.3.0) + the declarative fields) and the read-side namespaces (`Scope`, `Type`, `Reflection`, `Environment`, …) | [`docs/internal-spec/public-api.md`](internal-spec/public-api.md), pinned by [`public_api_drift_spec.rb`](../spec/rigor/public_api_drift_spec.rb) | [ADR-2](adr/2-extension-api.md) + the plugin examples under [`examples/`](../examples/README.md) | **yes** — the narrow ADR-37 protocols (the deprecated fat hooks are removed pre-1.0, e.g. ADR-52 slice 5b / ADR-60) |
| **Diagnostic identifiers** (`flow.always-truthy-condition`, `call.unresolved-toplevel`, …) + **suppression markers** (`# rigor:disable <id>` / `# rigor:disable-file <id>`) + **`severity_overrides:` keys** | rule IDs in [`lib/rigor/analysis/check_rules.rb`](../lib/rigor/analysis/check_rules.rb) (`ALL_RULES`, `LEGACY_RULE_ALIASES`), metadata in [`lib/rigor/analysis/rule_catalog.rb`](../lib/rigor/analysis/rule_catalog.rb) | [Manual ch. 4 — Diagnostics](manual/04-diagnostics.md); `rigor explain <rule>` | **yes — the vocabulary, not the firing set** (§ compatibility model 2) |
| **Baseline file format** (`.rigor-baseline.yml`) | `Baseline::CURRENT_VERSION` in [`lib/rigor/analysis/baseline.rb`](../lib/rigor/analysis/baseline.rb) (currently `1`) | [Manual ch. 6 — Baselines](manual/06-baseline.md) | **yes** — the on-disk format; a version bump invalidates, never mis-reads |
| **Cache schema version** | `Store::PAYLOAD_ABI_VERSION` (= `Rigor::VERSION`) + `Descriptor::SCHEMA_VERSION` + `Store::FORMAT_VERSION` in [`lib/rigor/cache/`](../lib/rigor/cache/) (marker `<version>.4.2`) | [Manual ch. 12 — Caching](manual/12-caching.md) | **yes** — a schema/format bump invalidates the cache, never silently mis-reads it |
| **`RBS::Extended` annotation grammar** (`%a{rigor:v1:…}` — predicate / assertion / return-override / `conforms-to`) | [`lib/rigor/rbs_extended.rb`](../lib/rigor/rbs_extended.rb) | [Spec — rbs-extended.md](type-specification/rbs-extended.md) (normative) | **yes** — the `rigor:v1:` directive grammar |

## What is explicitly *not* contract

These may change in any release — relying on them is unsupported:

- **Engine internals** — `Rigor::Inference::*`, the internals of
  `Rigor::Scope`, the `Rigor::Type::*` carriers, the dispatch tiers, the
  synthetic `Rigor::AST::*` nodes, and `Rigor::Analysis::{Runner,CheckRules,FactStore}`.
  See [`docs/internal-spec/public-api.md` § Internal surfaces](internal-spec/public-api.md).
- **Which diagnostics fire on a given file** — precision and bug-catching
  improve freely within a minor (§ compatibility model 2). The
  [baseline](manual/06-baseline.md) absorbs the churn.
- **`rigor sig-gen` output precision** — the *inferred shapes* sharpen
  over time; the command, flags, and RBS validity are contract, the
  precision of what it emits is not.

## Format and schema versions

The format/version markers a tool or CI pipeline can key on. Every bump
is an **invalidate-never-misread** event: a newer Rigor reading an older
artifact treats it as absent/stale, never as silently-wrong data.

| Artifact | Constant | Current value |
| --- | --- | --- |
| Baseline file | `Rigor::Analysis::Baseline::CURRENT_VERSION` | `1` |
| Persistent cache | `Cache::Store::PAYLOAD_ABI_VERSION`.`Cache::Descriptor::SCHEMA_VERSION`.`Cache::Store::FORMAT_VERSION` (the `schema_version.txt` marker) | `<Rigor::VERSION>.4.2` |
| `RBS::Extended` directives | the `rigor:v1:` namespace tag | `v1` |

## Machine enforcement

The pinned subset of the public surface is enforced mechanically:

- [`spec/rigor/public_api_drift_spec.rb`](../spec/rigor/public_api_drift_spec.rb)
  snapshots the instance/singleton method sets of every pinned namespace
  (`Scope`, `Environment`, `Type::Combinator`, `Reflection`, the
  `Plugin::*` contract surface, `Source::Literals`, `FlowContribution`,
  …). A signature change must update the matching snapshot in the same
  commit, so accidental drift is a failing test, not silent breakage.
- The [release acceptance gate](adr/50-release-engineering-and-stability-strategy.md)
  (ADR-50 § WD6) requires this drift spec green, plus the corpus
  false-positive sweep, `make check-incremental`, and the `make bench-perf`
  performance gate, before a release is cut.

## The trajectory in brief

Summarised from ADR-50 (the authority for all of these):

- **v0.2.0** ships the release-engineering machinery and pledges
  minor-non-break on the surface above as a trial discipline.
- **v1.0.0** freezes the surface; breaking it becomes major-version-only.
- **Versioning model** (ADR-50 § WD5): post-1.0 Rigor follows an
  edition-style cadence, not strict semver. A **patch** is fixes only; a
  **minor** may add features and diagnostics, but they arrive off-by-default
  behind `bleeding_edge:` or are absorbed by your baseline, so a minor
  upgrade is always possible (at most a baseline refresh) — a *soft* break;
  a **major** is the *hard* break, where the frozen surface may change,
  bleeding-edge disciplines turn on by default, and deprecated forms are
  removed. (PHP's `8.4`/`8.5` vs `8.0`/`9.0`; PHPStan's `bleedingEdge`.)
- **Support** (ADR-50 § WD5) is two separate things. Answering questions and
  troubleshooting is always-on, whatever version you run. A *maintenance
  line* — security and correctness backports, never features or new
  diagnostics, keeping the line's own Ruby pin — exists only for the release
  behind the most recent *hard* break: pre-1.0 the previous minor
  (`0.y-1`), post-1.0 the previous major (`(N).x` after `(N+1).0`). There is
  no per-minor maintenance within a major, because a minor upgrade is soft.
  Backports are **on demand and not guaranteed** — an older line is patched
  when a user who cannot cross the break needs a fix, and tapers once the
  next line is the default; no fixed support window is promised.
- **New disciplines** (a rule that demands an authoring change of
  previously-idiomatic code) land off-by-default behind the
  `bleeding_edge:` opt-in and turn on only at a major (ADR-50 § WD2/WD3/WD7).
  The opt-in foundation is shipped — `bleeding_edge:` config (`true` /
  feature-id list / `{ all:, except: }`) + the `rigor show-bleedingedge`
  inspector, composed into severity resolution below your own
  `severity_overrides:`. The first discipline,
  `reject-unparseable-signatures`, is queued in the overlay.

## See also

- [ADR-50](adr/50-release-engineering-and-stability-strategy.md) — the
  governing release-engineering and stability strategy (the authority).
- [`docs/internal-spec/public-api.md`](internal-spec/public-api.md) — the
  plugin-author view of the pinned namespaces and the promotion path.
- [Manual ch. 11 — Running Rigor in CI](manual/11-ci.md) § version
  pinning — how to pin a Rigor version in a pipeline.
- [`docs/ROADMAP.md`](ROADMAP.md) § "Release strategy — the road to
  v0.2.0" — the forward-looking commitment envelope.
</content>
</invoke>
