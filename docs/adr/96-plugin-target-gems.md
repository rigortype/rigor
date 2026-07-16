# ADR-96 — Plugin target-gem declaration, the plugin-gap advisory, and presence-gated umbrella expansion

Status: **Accepted, 2026-07-17.** WD1 (the `target_gems:` manifest field) and WD2 (the
plugin-gap advisory) are the committed slices; **WD3 (presence-gated umbrella expansion)
is proposed and gated on WD2** — see "Why WD2 must precede WD3". WD5 settles
`plugins/rigor-rails/`'s status without deciding its future: the dead Gemfile framing
comes out of the docs now, the meta-gem itself stays.

Prompted by a question with no answer in the corpus: *when the next Rails major ships
`ActionFoobar` as a core feature and Rigor adds `rigor-actionfoobar`, does an existing
Rails project ever find out?* Today it does not — and the investigation found that the
gap is neither hypothetical nor Rails-specific.

Grounding:
[`docs/notes/20260717-install-channel-evaluation.md`](../notes/20260717-install-channel-evaluation.md)
§ 6 (which flagged `rigor-rails`'s stale Gemfile framing as a loose end; this ADR is
where that thread landed).

## Context

`.rigor.yml`'s `plugins:` is a hand-written list, and **nothing keeps it fresh**.
`rigor-project-init` proposes a set once, from the catalogue as it stood on the day it
ran; after that the list is frozen for the project's lifetime. Nothing revisits it when
Rigor's catalogue grows, when the project adopts a new gem, or when a framework adds a
subsystem.

The failure mode is silence, not noise. A plugin that is not enabled does not warn — its
receivers simply type `Dynamic`, i.e. unprotected, which is precisely the class the
protection-coverage arc ([ADR-63](63-type-protection-coverage.md),
[ADR-82](82-dynamic-provenance-wiring.md)) exists to make visible. A stale `plugins:`
list is a coverage hole that reports nothing.

Three findings, all confirmed against the tree:

**1. The one mechanism we have is all-or-nothing.** `rigor doctor`'s Rails check
(`doctor_command.rb:262`) and `rigor skill describe`'s probe (`skill_describe.rb:60`)
both end in the same test:

```ruby
!file_mentions_any?(config_path, RAILS_PLUGIN_MARKERS)
```

**Any one** Rails plugin in the config satisfies it. A full Rails app with only
`rigor-activerecord` enabled is told nothing about the other seven. The `ActionFoobar`
scenario is not a future risk; it is the present state.

**2. The knowledge is duplicated four times, and none of the copies is the plugin.**
`RAILS_LOCK_MARKERS` / `RAILS_PLUGIN_MARKERS` are **byte-identical copy-pasted constants**
in `doctor_command.rb:39-42` and `skill_describe.rb:22-23`; `rigor-project-init` carries a
third as a prose "plugin-recommendation table" in
[`references/01-detect.md`](../../skills/rigor-project-init/references/01-detect.md); the
catalogue in [`plugins/README.md`](../../plugins/README.md) is a fourth. Each plugin knows
what it is for. Nothing asks it.

**3. The umbrella that was supposed to cover this is dead.**
[ADR-12](12-dry-rb-packaging.md) designed `rigor-rails` as a *Gemfile-convenience*
meta-gem — "a single Gemfile line opts the user in" — for a world where each plugin was
its own gem. Commit `9769f5fa` dropped the per-plugin gemspecs and
[ADR-31](31-contribution-and-supply-chain-policy.md) settled distribution on the single
bundled `rigortype` gem. The premise died; the language did not. `gem "rigor-rails"` is
impossible (no gemspec; 404 on RubyGems), `plugins: [rigor-rails]` is rejected by the
loader by design, and five sites still describe it — including the **shipped**
[user manual](../manual/07-plugins.md) served by `rigor docs`.

So the umbrella's *name* is dead. Its *role* — a curated set that tracks a framework as
Rigor grows — was never claimed by anything else.

## Decision

**Criterion 1 — the plugin declares what it is for; the tool never guesses.** A
gem→plugin mapping that lives anywhere but the plugin's own manifest is a copy, and a copy
goes stale silently. The mapping is also not derivable, which is what makes this a field
rather than a convention:

| Plugin | Actual gem | Why a name rule fails |
| --- | --- | --- |
| `rigor-factorybot` | `factory_bot` | underscore — `factorybot` is 404 on RubyGems |
| `rigor-rspec` | `rspec-core` | the suffix names the family, not the gem |
| `rigor-sorbet` | `sorbet-runtime` | ditto |
| `rigor-rails-routes` | `actionpack` / `railties` | the target is a *different* gem |
| `rigor-typescript-utility-types` | *(none)* | not every plugin has a target gem |

**Criterion 2 — presence is evidence for advice, not for execution.** Finding a gem in
`Gemfile.lock` justifies *telling* the user a plugin exists for it. It does not by itself
justify *running* that plugin's code: that needs the user's explicit opt-in. This is
[ADR-27](27-tool-distribution-model.md) / [ADR-31](31-contribution-and-supply-chain-policy.md)'s
plugin auto-load deferral, and it is the line [ADR-72](72-gemfile-lock-gated-rbs-overlays.md)
deliberately did not cross — its lock-gated overlay loads RBS **data**, never plugin code.
Criterion 2 is what splits WD2 from WD3.

### WD1 — `target_gems:` on the manifest

Each bundled plugin declares the gem(s) whose presence makes it relevant. An empty list
is a valid, meaningful answer: the plugin has no target gem (`rigor-typescript-utility-types`)
and is never advised. Following [ADR-88](88-incremental-plugin-fact-soundness.md)'s
opacity precedent, a plugin declaring nothing is *named as such* rather than silently
skipped, so the absence is a choice on the record.

This is a public plugin-contract addition and freezes at v1.0 under
[ADR-50](50-release-engineering-and-stability-strategy.md) WD1. It lands in the ADR-60
pre-freeze window for the same reason ADR-60's own changes did.

### WD2 — the plugin-gap advisory (the committed slice)

`rigor doctor` and `rigor skill describe` read `target_gems:` instead of their
copy-pasted constants, and report **per plugin**: this gem is locked, this plugin exists
for it, it is not in `plugins:`. Generalising beyond Rails is not extra work — it is what
deleting the Rails-specific tables leaves behind.

Severity is **`:warn`, not `:fail`**. Not adopting a plugin is a legitimate choice, and a
choice must not fail the command forever; `doctor` exits non-zero only on `:fail`. The
existing `:fail` for *"a framework is locked and not one of its plugins is enabled"* is
preserved — that one is genuinely unconfigured, and it is today's behaviour.

The advisory is **not** a `check` diagnostic. It is setup state, which is
[ADR-77](77-doctor-and-upgrade-commands.md)'s frame: route the evidence a run already
produces, do not invent a rule.

### WD3 — presence-gated umbrella expansion (proposed)

`plugins: [rigor-rails]` activates those members whose `target_gems:` are actually in
`Gemfile.lock`. The user's opt-in is explicit — they wrote `rigor-rails` — and the
expansion is justified by evidence on disk, which is exactly ADR-72's shape ("gating on
actual gem presence is what makes it sound"). This is the `ActionFoobar` scenario:
`rigor-actionfoobar` joins the umbrella, and a project that has adopted ActionFoobar gets
it on upgrade without editing `.rigor.yml`.

Two things must be settled before it ships, which is why it is proposed and not committed:

- **The upgrade surprise.** A new member silently strengthens the check on an existing
  project. Diagnostic output is non-contract and a baseline absorbs it (ADR-50), but a
  *new required discipline* is BC and rides the `bleeding_edge:` overlay. Which of the two
  an auto-joined plugin is has to be decided, not assumed.
- **Per-member opt-out.** [`plugins/README.md`](../../plugins/README.md) promises
  activation stays per-plugin "so users can opt out of any individual member". An umbrella
  needs an exclusion form to keep that promise.

### WD4 — what stays rejected

**C1, the blanket umbrella** (`plugins: [rigor-rails]` → every member regardless of the
lock). It re-imports ADR-12 WD1's own bloat argument — *"every loaded plugin participates
in dispatch even when its receiver classes never appear"* — and runs code for gems the
project does not have. WD3's gate costs nothing and removes both objections.

### WD5 — `plugins/rigor-rails/` stays; its documentation does not

[ADR-92](92-normative-status-fidelity.md)'s discipline applies to its own fourth
instance, in the plugin-packaging corpus rather than the type spec: **separate the status
question from the design question.** The status question is settled now and
unconditionally — the five sites instructing `gem "rigor-rails"` describe an impossible
action and come out, because silence is never the honest state and a marker is always
cheap. The design question (does the umbrella get WD3, or get deleted?) waits on
evidence.

Deleting the directory today would be the [ADR-60](60-pre-freeze-plugin-contract-consolidation.md)
WD1 move — it is a never-wired surface that is *documented-impossible*, which is exactly
the criterion ADR-60 used to remove `external_files:`. It is not made here only because
WD3 reopened the role: the concept has no other home, and removal would foreclose the
answer before the question is decided. If WD3 is rejected, ADR-60 WD1's criterion applies
unchanged and the directory goes.

Also corrected as a plain bug, independent of all of the above: `loader.rb:73-75`'s
worked example is `{ "gem" => "rigor-rails", "id" => "rails" }`, and **there is no plugin
with id `rails`** (the real ids are `actionmailer`, `actionpack`, `activejob`,
`activerecord`, `factorybot`, `rails-i18n`, `rails-routes`). The same fictional shape is
mirrored in `spec/rigor/configuration_spec.rb:156`.

## Why WD2 must precede WD3

Not caution — **WD2 is what proves the table.** WD1's `target_gems:` is 30 hand-written
claims about the world, and a wrong entry costs differently in each slice: under WD2 it
prints a bad hint the user ignores; under WD3 the same entry silently activates a plugin
the project has no gem for, or silently withholds one it needs. WD2 buys the primitive's
correctness at advisory stakes before WD3 spends it at execution stakes.

This mirrors [ADR-82](82-dynamic-provenance-wiring.md) WD5 (land the cheap slices, measure
what re-buckets, *then* decide whether the expensive one is worth it) and
[ADR-58](58-ivar-field-typing.md)'s sequencing rule — precision is deliberately staged
after the policy change so it cannot manufacture the very problem it is meant to fix.

## Rejected alternatives

| Alternative | Why not |
| --- | --- |
| Derive the gem from the plugin name | Measured false — `factory_bot` / `rspec-core` / `sorbet-runtime` / `actionpack`, and `rigor-typescript-utility-types` has no gem at all |
| Keep the tables in `doctor` / `skill_describe` | Four copies of one fact, none of them the plugin; they are identical today by luck, not by construction |
| C1 — blanket umbrella activation | WD4 |
| Delete `plugins/rigor-rails/` now | WD5 — forecloses WD3's only home; revisit if WD3 is rejected |
| A `check` diagnostic for a missing plugin | Setup state is not code state (ADR-77); and it would fire on every deliberate non-adoption |
| Make the advisory `:fail` | Turns a legitimate choice into a permanently red command |

## Consequences

- **Positive.** One fact, one home. The Rails-specific tables and their copy-paste twin
  disappear, and the advisory covers every plugin with a target gem — the `ActionFoobar`
  case included — with no auto-load risk. WD3 gains a gate it does not have to invent.
- **Negative.** 30 hand-written `target_gems:` claims to keep true, and a new public
  contract field to freeze at v1.0. A project that deliberately declines a plugin sees a
  standing `:warn` from `doctor`; if that proves noisy, an opt-out is the follow-up.
- **Carry-over.** WD3's two open questions above. `rigor-project-init`'s prose table is
  the fourth copy and is left alone here — generating it from `target_gems:` is the
  obvious follow-on once WD1 exists.

## Relationship to other ADRs

- [ADR-12](12-dry-rb-packaging.md) — designed the meta-gem for a Gemfile world; its
  packaging premise is superseded by ADR-31, which this ADR records rather than leaves
  implicit.
- [ADR-72](72-gemfile-lock-gated-rbs-overlays.md) — the lock-gated precedent WD3 extends
  from RBS data to plugin activation, and the line Criterion 2 draws.
- [ADR-77](77-doctor-and-upgrade-commands.md) — WD2 is a doctor check in its frame.
- [ADR-92](92-normative-status-fidelity.md) — WD5 is its status/design split, applied to a
  fourth instance of the same disease.
- [ADR-60](60-pre-freeze-plugin-contract-consolidation.md) — WD1 lands in its window;
  WD5 defers its removal criterion rather than rejecting it.
