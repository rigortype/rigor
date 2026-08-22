# Configuration — `.rigor.yml` semantics

Status: **Stable.** This document specifies how `.rigor.yml` is validated: the three independent
tiers, which artifact is authoritative for what, and the rule for a namespace this implementation
reserves but never reads. The rationale lives in
[ADR-99](../adr/99-config-schema-authority.md); this document binds when the two disagree.

The user-facing key reference is [Manual ch. 3 — Configuration](../manual/03-configuration.md);
the frozen-surface commitment is [`docs/compatibility.md`](../compatibility.md) (the
[ADR-50](../adr/50-release-engineering-and-stability-strategy.md) WD1 surface document).

## Sources of truth

`.rigor.yml`'s surface has **two** co-equal sources of truth, and a change to one is incomplete
without the other:

| Artifact | Owns |
| --- | --- |
| [`lib/rigor/configuration.rb`](../../lib/rigor/configuration.rb) | `DEFAULTS` — which keys exist, their defaults, and the coercers that give each value its runtime meaning. |
| [`schemas/rigor-config.schema.json`](../../schemas/rigor-config.schema.json) | The declared shape of every key, including keys this implementation never reads (§ Reserved namespaces). |

The schema is **not documentation of the loader** — it is authoritative in its own right, and it is
the config schema for the `rigor-rs` port too, which carries this repo as a submodule and vendors the
file verbatim rather than maintaining its own. A key's shape is therefore settled here before any
implementation reads it (§ The reserve pipeline).

The schema reaches an editor through the `# yaml-language-server: $schema=` comment: `.rigor.dist.yml`
carries a relative path; `rigor init` writes an absolute URL. That URL and the schema's `$id` MUST
name the same location and MUST resolve — a schema that fails to load is indistinguishable from a
schema with no complaints, so silent rot here disables validation without any symptom.

## The three validation tiers

`.rigor.yml` is validated at three independent tiers. **Which tier a key answers to is part of its
design, not an implementation detail** — a key may sit in one tier, or all three.

| Tier | Checker | When | On failure |
| --- | --- | --- | --- |
| **1. Schema** | editor / CI | edit time | An editor squiggle. **No runtime effect whatsoever.** |
| **2. `Configuration` load** | this implementation | load time | `Rigor::ConfigurationError` (an `ArgumentError`) — the run stops. |
| **3. Config audit** | this implementation | check time | A STDERR warning, and a tagged entry under `config_warnings` in the `--format=json` payload. **The exit code is unchanged.** |

Tier 2 is for a value the loader cannot proceed on (a malformed `dependencies.source_inference[]`
entry, an out-of-range `budget_per_gem`, an `effects.snapshot.gate` outside the enum, an
`effects.snapshot.reach` entry naming no registered entry-point preset, a member of `effects.tolerated`
/ `effects.labels` / `effects.attribution` / `effects.envelopes[].effect` that is not a well-formed
effect label, an `effects.attribution` key that is not a method key, an `effects.envelopes[]` entry
naming both or neither of `match:` / `namespace:`, or one carrying no `effect:` bound at all). Tier 2
answers *shape*, not *meaning*: a label the effect registry has never heard of loads fine wherever it
appears, because an unknown label fails open and is `effect.unknown-label`'s business.

A file that is not parseable YAML at all fails the same way, one step earlier, with the position
re-rendered as `path:line:column` rather than in Psych's own prefix form.

**A tier-2 failure MUST reach the user as a `rigor:` line, never as a backtrace.** `Rigor::CLI#run`
rescues `Rigor::ConfigurationError` for every command, prints `rigor: <message>` and exits `64` — the
same shape a bad flag takes, because a mistake in `.rigor.yml` is the same kind of event. This is why
the class is narrower than `ArgumentError`: it separates *the user got the file wrong* from *Rigor got
itself wrong*, and only the first is presentable. It stays an `ArgumentError` subclass so the
long-standing tier-2 contract, and every caller outside the CLI that rescues by that name, are
unaffected. The message is the whole diagnostic — it MUST name the offending key, and where the answer
is knowable it MUST carry it (`effects.snapshot.reach`'s unregistered-preset error enumerates the
presets this project's plugins did register).

One tier-2 check does not run at load: an `effects.snapshot.reach` **preset name** is validated where
the snapshot expands it, because presets are registered by plugins and the plugins load *from* the
configuration being validated. Load time checks the entry's shape; the registry is only complete once
analysis begins. The two halves are `Configuration#coerce_effects_reach` and
`Rigor::Effects::EntryPoints.resolve!`, and the CLI renders both the same way. Tier 3 is for a
value that is well-formed but **silently resolves to nothing** — a missing signature path, an unknown
library name, an inert suppression, an unrecognised top-level key; the class of mistake whose only
symptom is confusing and downstream.
Tier 3 warns and never errors, because a partial or forward-looking config is a valid setup, and it
never fires on an unset default.

Tiers 1 and 3 overlap on unrecognised **top-level** keys, and both are needed: tier 1 catches the
mistake as it is typed but only for a user whose editor loads the schema, while tier 3 always runs.
`Configuration::KNOWN_KEYS` is the complete set a conforming file may carry (the `DEFAULTS` keys +
`includes:` + the reserved namespaces); anything else is recorded on `Configuration#unknown_keys` —
the loader fetches each key it owns and never enumerates the rest, so without that record the keys
are gone before the audit sees a Configuration.

**Tier 3 covers top-level keys only.** A nested check would need each group's known key set, and
`DEFAULTS` cannot supply it: `DEFAULTS["dependencies"]` omits `budget_overrun_strategy`, which is
real, documented, and schema-declared — a `DEFAULTS`-keyed nested check would flag a working config.
`severity_overrides:` is an open map of rule ids besides. Nested unknown keys are tier 1's job: every
nested object in the schema is `additionalProperties: false`, and the gate below keeps it complete.

## Reserved namespaces

A **reserved namespace** is a top-level key this implementation declares in the schema and never
reads. It exists so a sibling implementation can carry keys for concepts this one does not have,
while a single `.rigor.yml` still feeds both.

A reserved namespace answers to **tier 1 only**:

- It is declared in the schema, with its shape constrained — an undeclared key inside it is an error,
  because the reservation is authoritative rather than a mirror of whatever the other implementation
  happens to ship (ADR-99 WD2).
- This implementation **never reads, validates, or coerces it**, and **never errors on it** however
  invalid its value. It does not reach `Configuration`, and the config audit produces no finding for
  it. A value the schema itself would reject still loads and checks clean.

Reserved namespaces are enumerated in `Rigor::Configuration`. `rigor_rs:` (the `rigor-rs` port) is
the only one today.

## The reserve pipeline

A key belonging to a sibling implementation follows a fixed order:

> propose in the sibling → **reserve in this repo's schema** → implement in the sibling → release here
> → release the sibling

Reserving *before* implementing is what keeps a user's editor from flagging a key their newly-updated
sibling just started requiring. A sibling key therefore cannot ship faster than this repo's release
cadence; that cost is the ordering's price and is accepted deliberately (ADR-99).

## Gates

Both sources of truth are pinned, and the two axes are separate because one cannot reach the other:

- **`DEFAULTS` → schema, nested.** Every key in `Configuration::DEFAULTS`, at every depth, has a
  schema entry with a matching shape (`spec/rigor/config_schema_spec.rb`). Enum-valued keys are
  pinned against the runtime `VALID_*` constants.
- **Reserved namespace → schema.** A separate axis: a reserved namespace is **by definition not a
  `DEFAULTS` key**, so the axis above can never reach it. Every reserved namespace has a schema
  entry, and every schema-declared reservation is in the reserved list.
- **`$id` ↔ the init-written URL.** Read from one constant so they cannot disagree.

Every config appearing in the manual validates against the schema.
