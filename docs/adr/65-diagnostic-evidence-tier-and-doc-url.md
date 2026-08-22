# ADR-65 — Diagnostic evidence tier and documentation URL

Status: **Accepted — implemented 2026-06-15; `documentation_url` moved off
the GitHub blob path to the published docs host (Amendment 2026-08-23).**
Two additive fields on
the public diagnostic surface: every built-in rule carries an
**`evidence_tier`** (`high` / `medium` / `low`, or none for an
informational helper) — Rigor's own confidence that a firing is a true
positive — and a stable **`documentation_url`** pointing at the rule's
anchor in the published diagnostics catalogue. Both are emitted per
diagnostic on `rigor check --format json` and per rule on the rule
catalogue (`rigor explain` / `rigor explain --format json`).
Precision-additive: no new diagnostic, no severity change, the diagnostic
set is byte-identical. Follow-up to
[ADR-61](61-agent-friendly-diagnostic-statistics.md) (structured
fields on the stream); this adds a *confidence* axis and a *reference*
axis. In the same change it closes a catalogue gap — `call.unresolved-
toplevel` had no `RuleCatalog` entry — and adds a completeness spec so
the gap cannot recur.

Grounding: the 2026-06-15 type-tool-comparison developer-feedback report
(`rigor-developer-feedback-2026-06-15.md`, §4 + §5.1). §4 is the headline
ask: an external classifier collapses Rigor's `signal_lower` to 0 because
it can only promote a diagnostic to "live latent bug" via cross-tool
positional agreement, and Rigor's strongest rules fire at positions the
peer tools never reach. A *tool-self-reported confidence field* lets such
a consumer promote a high-confidence firing without peer corroboration.
§5.1 is the reference ask: peers (Sorbet's `srb-NNNN`) ship per-rule doc
URLs; Rigor named its rules but pointed nowhere.

## Context

Rigor already runs its diagnostics through a strong false-positive
discipline (`feedback_false_positive_discipline`): a rule fires only when
its firing gates are satisfied — a concrete statically-known receiver, no
metaprogramming escape, both-sides-authored RBS, and so on. That
discipline is *invisible* to a consumer: the JSON stream says `error` /
`warning` / `info` (impact) and a rule id, but nothing about how much the
analyzer trusts the individual firing. The feedback's external classifier
therefore could not distinguish a `call.undefined-method` on a concrete
`String` (almost certainly a real bug) from a `call.unresolved-toplevel`
that is usually a resolution gap (the defining file is simply not in the
analyzed set).

Two structural facts made the gap cheap to close:

1. **The confidence is already a property of the rule.** Because the
   FP-discipline filters the uncertain cases *before* a rule fires, the
   residual confidence is dominated by which gates the rule applies — i.e.
   it is a property of the rule kind, not of the individual call site.
   The feedback's own §3 reasons this way: it groups the *new* rule kinds
   into "coverage warnings" vs "real type-rule firings" — per kind, not
   per firing.
2. **A single-source-of-truth rule catalogue already exists.**
   [`RuleCatalog`](../../lib/rigor/analysis/rule_catalog.rb) carries
   `summary` / `fires_when` / `does_not_fire_when` / `severity_by_profile`
   / `since` for every rule and backs `rigor explain`. A tier and a doc
   URL are two more columns of the same table.

Why now: ADR-50 freezes the public output surface at v1.0; this lands in
the pre-freeze window so the field names enter the freeze correct.

## Decision

### WD1 — `evidence_tier` is a per-rule property, not a per-firing computation

The tier lives on the `RuleCatalog::Entry`, one value per rule, **not**
computed at each diagnostic site. This follows from the FP-discipline
observation above: a per-firing tier would have to thread a confidence
signal through every rule's suppression and firing logic for marginal
gain, since the gates have *already* collapsed the site-to-site variance
the per-firing form would measure. The per-rule form is also what the
consumer wants — a stable, documentable contract per rule id, the dual of
Sorbet's per-`srb-NNNN` semantics.

### WD2 — Tier semantics, orthogonal to severity

Three tiers, assigned by the *kind* of evidence the rule's firing gates
rest on:

- **`high`** — fires only on a concrete, statically-known type with no
  metaprogramming escape; the FP-discipline has filtered the uncertain
  cases, so a firing is almost always a genuine problem and a consumer (or
  classifier) can act on it without cross-checking. (`call.undefined-
  method`, `call.wrong-arity`, `call.argument-type-mismatch`,
  `call.possible-nil-receiver`, `def.method-visibility-mismatch`,
  `flow.always-raises`, `flow.unreachable-branch` (literal-only),
  `def.ivar-write-mismatch`, the `def.override-*` family,
  `assert.type-mismatch`.)
- **`medium`** — rests on a flow- or inference-level proof that inherits a
  *documented* false-positive envelope (loop / mutation / RBS-strictness
  modelling gaps, narrowed by the rule's `does_not_fire_when` list).
  Usually right, not literal-provable. (`flow.always-truthy-condition`,
  `flow.unreachable-clause`, `flow.dead-assignment`,
  `def.return-type-mismatch`.)
- **`low`** — a resolution- or coverage-gap signal: a firing frequently
  reflects context the analyzer cannot see rather than a definite bug, and
  routes to a review path (e.g. `call.unresolved-toplevel` →
  `pre_eval:`). (`call.self-undefined-method`, `call.unresolved-
  toplevel`.) Informational helpers (`dump.type`) carry no tier.

The tier is **orthogonal to severity** and to the severity profile: it
never changes whether a diagnostic surfaces and never feeds gating — it
only routes attention. This preserves the FP-discipline guardrail (the
same one ADR-61 observed): a confidence axis that fed severity would let
"this is low-confidence" silently downgrade a real error, or "high"
manufacture a gate, neither of which the user asked for.

### WD3 — `documentation_url` is a per-rule anchor in the published catalogue

*The base URL below is superseded by the 2026-08-23 amendment; the
per-rule anchor scheme is unchanged.*

The URL is the published diagnostics manual page anchored per rule —
`…/docs/manual/04-diagnostics.md#rule-<id-with-dots-as-dashes>` — mirroring
the gemspec `documentation_uri` scheme. The catalogue page carries the
matching `<a id>` anchors and names `rigor explain <rule>` as the
authoritative per-rule reference; the catalogue (not a separate docs site)
stays the single source of truth. No `rigor.dev/rules/<kind>` site is
invented: shipping a URL to a page that does not exist would be worse than
none, and the FP/honesty ethos says emit only what resolves. A
configurable base (`<base>/<rule>`, for an org hosting its own rule docs)
is the obvious extension but is deferred until demand exists.

### WD4 — Surfacing, and the flat-field shape

Both fields are emitted:

- **Per diagnostic** on `rigor check --format json` — enriched in the CLI
  JSON path from the rule id (a pure catalogue lookup), so no diagnostic
  construction site changes. Only built-in rules carry the metadata; a
  plugin / `rbs_extended` / parse-error diagnostic is left untouched
  (those host their own docs and confidence). `evidence_tier` is omitted
  when nil.
- **Per rule** on the catalogue: `rigor explain <rule>` prints both, and
  `rigor explain --format json` carries them — which makes that command
  the machine-readable rule taxonomy with doc URLs the feedback's §5.1
  also wanted, for free.

The field is **flat** (`"evidence_tier": "high"`), matching the existing
`receiver_type` / `method_name` convention, not the feedback's suggested
nested `{ "evidence": { "tier", "rationale", "fp_suppression_considered" }}`
object. The `rationale` is exactly the catalogue's `fires_when` /
`does_not_fire_when`, already reachable via `rigor explain`; duplicating it
per diagnostic would bloat the stream and drift. `fp_suppression_considered`
is true for every Rigor diagnostic by construction (the discipline runs
before any rule fires), so it carries no information.

## Rejected alternatives

- **Per-firing dynamic tiers** — compute confidence from the live
  receiver concreteness / metaprogramming signals at each site. Rejected:
  the firing gates already collapse that variance (WD1), so it is a large
  cross-rule surface for marginal gain, and a wrong dynamic tier is a new
  way to mislead.
- **Nested `evidence` object with `rationale` / `fp_suppression_considered`**
  — rejected per WD4 (rationale lives in `rigor explain`; the suppression
  flag is universally true).
- **A `rigor.dev/rules/<kind>` documentation site** — rejected for v1: a
  URL to a non-existent page is dishonest; the catalogue + `rigor explain`
  is the real per-rule reference, and the manual anchor resolves today.
- **Feeding the tier into severity or the exit code** — rejected: the tier
  routes attention, it does not gate (WD2 guardrail).

## Amendment (2026-08-23) — the URL drops the git ref ([#438](https://github.com/rigortype/rigor/issues/438))

WD3 shipped a base of `…/blob/main/docs/manual/04-diagnostics.md`.
This repository's default branch is `master` and `origin` has never had a
`main`, so **every `documentation_url` Rigor has ever emitted 404ed** —
for the whole life of the field, on every `rigor check --format json` and
every `rigor explain`. The catalogue anchor was right; the page it hung
off did not exist. `DOCUMENTATION_BASE` is now
`https://rigor.typedduck.fail/manual/04-diagnostics/`.

**The form, and why not the obvious repair.** Rewriting `main` to
`master` fixes today and reinstates the defect class: a branch name is a
*mutable* component sitting inside a contract we froze, and the rename
that breaks it need not even happen here — GitHub's default-branch
migration is exactly the event this repository would eventually take. A
released tag (`blob/v0.3.4/…`) is immutable but resolves only after that
tag is pushed, so every build between a version bump and its tag — the
window in which contributors and agents actually read these URLs, and the
window in which #438 was found — would emit 404s again, harder to notice
because most versions work. The published docs host carries no ref at
all: there is nothing in the string that a rename or a release can
invalidate. It renders `docs/manual/04-diagnostics.md` verbatim,
`<a id="rule-…">` tags included, so the fragment half of WD3 — the half
`spec/docs/manual_drift_spec.rb` axis 4 already guarded — is unchanged,
and the anchors carried over one-for-one at the cut.

This does **not** reverse WD3's rejection of a documentation site. What
was rejected was *inventing* `rigor.dev/rules/<kind>`, a per-rule surface
that did not exist — "a URL to a non-existent page is dishonest". The
docs host publishes the catalogue chapter itself, which is what WD3 chose
to point at; only the rendering moves. The single source of truth is
still `docs/manual/04-diagnostics.md` in this repository, and
`rigor explain <rule>` is still the offline authority.

**Is changing a frozen contract value a breaking change?** No, and it
needs no deprecation dance. ADR-50 freezes the public output surface so
consumers can *rely* on it; what is frozen is the field's presence, name,
type, and meaning — "a stable URL to this rule's entry in the published
catalogue" — all of which are untouched. The value was never usable: it
resolved for nobody, so no consumer can have built on it, and the only
behaviour that changes for anyone is that following the link now works.
A deprecation window here would mean deliberately emitting a known-404
for another release to protect a compatibility nobody has. The
FP/honesty ethos WD3 invokes runs the other way: emit only what resolves.
The rule this sets for the next such case is narrow — a frozen field's
*value* may be corrected without ceremony when the old value is
demonstrably inoperative (it 404s, it fails to parse, it names something
that does not exist); a value that works and merely displeases us is a
breaking change and takes the full dance.

**The invariant, and what now enforces it.** No frozen public contract
may embed a mutable git ref. Two gates, both network-free so they fail on
a rename rather than on a flaky connection:

- `spec/docs/manual_drift_spec.rb` axis 4 now checks the *page* as well
  as the fragment — the base must be a `<host>/manual/<slug>/` URL whose
  host README.md itself uses, whose `docs/manual/<slug>.md` the gemspec
  actually packages, and which contains no `blob` / `tree` / `raw` path
  segment.
- `spec/docs/link_integrity_spec.rb` sweeps every shipped surface for
  self-referential `github.com/rigortype/rigor/<blob|tree|raw>/<ref>/`
  URLs and requires `<ref>` to be the default branch named in
  `.github/workflows/ci.yml`. It found three more live 404s that shipped
  with the same assumption: the `rigor init` config template's plugins
  link, and the VS Code extension's `homepage` and README.
