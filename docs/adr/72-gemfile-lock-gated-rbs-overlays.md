# ADR-72 — Gemfile.lock-gated bundled RBS overlays

Status: **Accepted — implemented 2026-06-17.** When a gem is locked in
the project's `Gemfile.lock` but ships no RBS through any resolution
path (the `:missing` coverage class), Rigor auto-loads a bundled
per-gem RBS overlay for its core-class extensions, so a Rails project
stops seeing a systematic false `call.undefined-method` on
`3.minutes` / `"x".underscore` / `hash.symbolize_keys` while a project
WITHOUT the gem still sees the genuine diagnostic. ActiveSupport is the
first (v1: only) bundled overlay. Precision-additive in the FP-safe
direction: the overlay can only *remove* a diagnostic, and only where
the gem is actually loaded (so the method is real at runtime). Twin of
the opt-in [`rigor-activesupport-core-ext`](../../plugins/rigor-activesupport-core-ext/)
plugin, which it stands down for when loaded.

Grounding: the 2026-06-17 `evidence_tier` calibration feedback. A
downstream consumer trusting `evidence_tier == "high"` as a true-positive
floor (ADR-65) auto-promoted **171 of 512** high-tier
`call.undefined-method` diagnostics on Mastodon (~33%) to "live latent
bug" — all of them ActiveSupport core-ext call sites
(`undefined method 'minutes' for 3`, …) that are real, callable methods
at runtime and false only because the ActiveSupport RBS was not loaded.

## Context

`call.undefined-method` carries `evidence_tier: :high` (ADR-65 WD1: a
per-rule property) because its firing gate — a concrete, statically-known
receiver whose RBS-declared method surface does not contain the method —
is normally high-confidence. That premise has a systematic exception in
the Rails ecosystem: **open-class monkeypatching of core types.** The
receiver IS concrete (`Integer`), but its method surface is NOT closed —
a loaded gem (`activesupport`) extends it at runtime. Rigor only fails to
see it because the gem ships no RBS and none was installed.

The feedback proposed two fixes: (a) ship an ActiveSupport core-ext RBS
overlay, and (b) a per-firing tier gate that demotes core-type
undefined-method when a known unsignatured monkeypatcher is in the
lockfile. It recommended (b) as more durable. We chose (a), because the
project's first-order value is false-positive discipline ("never frighten
working code"), and (b) does not serve it:

- **The tier never feeds severity** (ADR-65 WD2). Down-tiering
  `3.minutes` from `high` to `medium` leaves it firing as a red `error` —
  all 171 FPs stay on screen. (b) fixes only the automated consumer, not
  the human.
- (b) is exactly ADR-65's explicitly-**rejected** "per-firing dynamic
  tiers" alternative, and contradicts WD1. Adopting it would be a
  reversal of a recorded decision for marginal gain.

Resolving the FP at the source removes the systematic subpopulation
entirely, so `evidence_tier: :high` keeps meaning "real type error" with
no change to ADR-65.

Two existing facts made (a) cheap and safe:

1. **Rigor already detects the trigger.** `RbsCoverageReport.classify`
   already reports each Gemfile.lock gem's RBS provenance and surfaces
   the `:missing` set (the `rbs.coverage.missing-gem` notice). The
   overlay reuses that classification verbatim.
2. **Rigor already maintains the RBS.** The opt-in
   `rigor-activesupport-core-ext` plugin ships the curated core-ext
   signatures. The overlay is its auto-applied, lock-gated twin.

## Decision

### WD1 — The gate: locked, `:missing`, and no conflicting plugin

For each gem locked in the project's `Gemfile.lock`, the overlay loads
iff:

- it ships no RBS through any resolution path — `RbsCoverageReport`
  classifies it `:missing` (not a default library, vendored stub,
  bundle-`sig/`, or `rbs collection` entry), AND
- Rigor bundles an overlay for it (`data/gem_overlay/<gem>/`), AND
- the opt-in plugin that ships the same signatures is not **reachable**
  (`GEM_OVERLAY_PLUGIN_IDS` maps `activesupport` →
  `activesupport-core-ext`; the overlay stands down so the two never both
  declare the methods and raise `RBS::DuplicatedDeclarationError`).

Reachable is two questions, not one. The plugin id being in the registry
is the route this ADR first anticipated. Issue #672 found the second: a
project that wires the plugin's signatures through `signature_paths:`
rather than `plugins:` reaches the same `.rbs` with no registry entry to
key on, so both halves loaded and every class they share collapsed —
`RBS::DefinitionBuilder` raised `DuplicatedMethodDefinitionError` while
`class_known?` kept saying yes, and the run reported *less* while still
exiting 0. The stand-down therefore also asks whether the user's own
`signature_paths:` already **load** the engine's bundled twin `sig/`
(`Plugin::Loader.bundled_plugin_sig_path`).

**Load, not look like.** The test is whether an entry is a directory
that `RbsLoader.project_sig_files` — the loader's own acceptance test —
would read one of the twin's `.rbs` files from, with both sides
canonicalised through `File.realpath`. Comparing path strings is wrong
in both directions, and the false-positive direction is the expensive
one: `signature_paths:` naming the twin's `.rbs` *file*, or a
subdirectory of the twin that does not exist, match the twin as strings
while the loader reads nothing from them (`SignaturePathAudit` reports
them `:not_directory` / `:missing`). Standing the overlay down for those
leaves the project with *neither* copy, so ordinary `3.minutes` and
`"x".camelize` draw `call.undefined-method` — a check firing on correct
code, which WD2 and [ADR-5](5-robustness-principle.md) both forbid.
The quiet direction is the mirror image: a symlink to the twin, or a
case-variant spelling of it where the filesystem folds case, loads the
twin's declarations while matching no prefix, so the overlay would stay
and the class would collapse. Canonicalising resolves both.

**Still not a content test.** A *vendored copy* of these signatures
collides identically and is deliberately not caught: catching it means
standing the overlay down on a declaration overlap, and then every
selector the copy omits becomes a fresh `call.undefined-method` on
correct code — WD2's forbidden direction again — while an edited copy
defeats the test anyway. The vendored copy keeps the collision report
instead of a guess, and how loud that report should be is
[#696](https://github.com/rigortype/rigor/issues/696).

Lockfile resolution piggybacks on `bundler.auto_detect` (default
**true**), so the fix is on by default for any project with a
`Gemfile.lock` next to its root and needs no configuration.

**Gating on actual gem presence is what makes the overlay sound.** A
plain-Ruby project with no `activesupport` in its lockfile still gets the
genuine `undefined method 'minutes' for 3` — the overlay is not loaded,
because the method genuinely does not exist there.

### WD2 — FP-safe direction only

The overlay can only ever *remove* a `call.undefined-method` (additive
RBS resolves a method that was flagged), and only on a project that loads
the gem (so the method is real at runtime). It cannot manufacture a new
diagnostic. A genuine typo on a core receiver (`5.minuets`) is *not* in
the overlay, so it still fires at `evidence_tier: :high` — the
discrimination the down-tier alternative could not make without a
method-name allow-list. This is the same robustness stance as ADR-58
(declaration-sourced facts are not diagnostic fuel): precision is added
only where being wrong cannot frighten working code.

### WD3 — Mechanism: ride the signature-path digest

Overlay directories are appended to `Environment.for_project`'s
`loader_signature_paths` (last, so any RBS the project already supplies
wins). This reuses every existing channel for free:

- The env cache descriptor (`Cache::RbsDescriptor`) already digests
  `loader.signature_paths`, so the env invalidates when the overlay's
  presence changes (adding/removing the gem from the lockfile toggles the
  path in the digest) — no new cache plumbing.
- `RbsLoader#build_env` already loads `@signature_paths`.

New surface is one data tree (`data/gem_overlay/<gem>/*.rbs`) and one
loader accessor (`RbsLoader.gem_overlay_sig_paths`). Eligibility lives in
`Environment.for_project` (a private `gem_overlay_paths` helper); the
`RbsLoader` constant surface (`Environment::GEM_OVERLAY_PLUGIN_IDS`,
`RbsLoader::GEM_OVERLAY_SIGS_ROOT`) stays off the ADR-50-frozen public
API.

### WD4 — Relationship to ADR-65 (evidence tier) and ADR-27/31 (auto-load)

This **preserves ADR-65 WD1**: the tier stays a per-rule property; no
per-firing dynamic tier is introduced. The calibration complaint is
resolved by removing the FP subpopulation, not by relabelling it.

It **does not reverse the ADR-27/31 plugin auto-load deferral**: that
deferral is about auto-loading plugin *code* (which runs `prepare`,
walkers, IO). This auto-loads RBS *data* only — no code execution —
gated on the gem's actual presence, a strictly narrower and safer surface
than a plugin. It is the unconditional `core_overlay` mechanism made
lockfile-conditional (and conditional is mandatory here: ActiveSupport
methods, unlike `core_overlay`'s always-present core methods, exist only
when the gem is loaded).

### WD5 — Generalization

`GEM_OVERLAY_PLUGIN_IDS` and the `data/gem_overlay/<gem>/` tree are the
durable, generalizable form of the feedback's "generalizes beyond
ActiveSupport" ask: another systematic core-class monkeypatcher (i18n,
Sequel, …) is onboarded by adding an overlay directory and, if it has an
opt-in plugin twin, a map entry — no engine change. Additional overlays
are demand-gated.

## Rejected alternatives

- **Per-firing tier demotion (the feedback's (b)).** Reverses ADR-65
  WD1 and its rejected per-firing-dynamic-tiers alternative, and — because
  the tier never feeds severity (ADR-65 WD2) — leaves the red FP on
  working code, fixing only the automated consumer.
- **Suppress / downgrade the severity of core-class undefined-method
  under monkeypatch risk.** Removes the human-facing FP and generalizes,
  but trades a false-negative on real typos on core types (`5.minuets`
  would be silenced too) and is a coarser instrument than resolving the
  actual method. A method-name allow-list narrows it but re-implements,
  worse, what the RBS overlay states precisely.
- **Auto-load the full opt-in plugin.** Runs plugin code; conflicts with
  the ADR-27/31 auto-load deferral.
- **Unconditional overlay (like `core_overlay`).** Unsound: a plain-Ruby
  project that calls `3.minutes` without ActiveSupport would lose the
  genuine `call.undefined-method`.
