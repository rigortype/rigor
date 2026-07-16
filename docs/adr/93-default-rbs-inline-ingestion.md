# ADR-93 — Default rbs-inline ingestion: reconciling ADR-32's opt-in with the always-parse spec

Status: **Proposed, 2026-07-16 — WD4's first measurement ran the same day; it found and
fixed one blocker and reshaped WD1/WD2 (see § "WD4 — first measurement").** The default
flips themselves remain unimplemented. The divergence this reconciles is marked in
[`overview.md`](../type-specification/overview.md) § "Compatibility hierarchy" per
[ADR-92](92-normative-status-fidelity.md).

Grounding: [`docs/notes/20260716-dspec-formal-spec-substrate-evaluation.md`](../notes/20260716-dspec-formal-spec-substrate-evaluation.md)
§ "第四の事例" — the adjudication, with the timeline and the upstream `disabled`-handling
verification.

## Context

The binding spec ([`overview.md`](../type-specification/overview.md), 2026-04-28) makes
inline rbs-inline annotations **official type sources**: "always parsed and used whenever
present", "MUST NOT require `# rbs_inline: enabled` to begin parsing them", with only the
upstream configuration directives interpreted (so `# rbs_inline: disabled` remains the
per-file opt-out). [ADR-32](32-rbs-inline-comment-ingestion.md) (2026-05-25, shipped
v0.1.10) contradicts it on both axes without citing it: ingestion is an opt-in plugin, and
the plugin's WD2 default requires the magic comment — listing the spec-mandated always-on
behaviour as a rejected alternative. Per CLAUDE.md the spec binds, so the shipped default is
non-conforming.

The practical cost is real: a user writing `def foo #: void` — a form the spec's own style
guidance *strongly recommends* — gets silence through three stacked gates (plugin not
configured, magic comment absent, upstream's top-level-def gap), and nothing tells them
which gate ate the annotation.

Two facts make reconciliation cheap. Upstream honours `# rbs_inline: disabled`
**unconditionally** (`rbs-inline` `parser.rb:73`, checked before the `opt_in` branch), so
the plugin's existing `require_magic_comment: false` mode (ADR-32 WD10) is *exactly* the
spec's semantics — parse whenever present, `disabled` opts out. And the bundled plugin plus
the upstream library are already the vendored, reviewed code path; no new code source is
introduced by wiring them on.

## Decision

> **The spec's activation model is the contract: annotation comments are type sources
> whenever present, and only the upstream configuration directives gate them. Conformance is
> delivered by wiring and defaults — never by re-implementing the grammar (ADR-32 WD1/WD3
> stand) and never by narrowing the spec to bless the accident.**

## Working decisions (proposed shapes, open to adjustment)

**WD1 — the magic-comment-free mode gates on annotation presence, then becomes the default.**
Two steps, and the first is a correction the WD4 measurement forced: `require_magic_comment:
false` used to mean "parse every file", which made upstream fabricate a
`def f: (untyped x) -> untyped` skeleton for every unannotated def — and since Rigor trusts an
accepted signature over body inference, the skeleton *replaced* real inferred types (mail:
26 → 42 diagnostics). **Landed:** the mode now contributes only for a file that actually
carries an annotation, detected with upstream's own `AnnotationParser` (not a regexp — the
grammar stays upstream's per ADR-32 WD3) and filtered for RDoc directives, since upstream
reads `class Foo #:nodoc:` as a type assertion. All four annotation-free corpora are now
byte-identical under the mode. **Remaining:** flip the plugin default to that mode — a
diagnostic strengthening [ADR-50](50-release-engineering-and-stability-strategy.md) allows in
a minor (output is non-contract; the baseline absorbs), with the per-file `# rbs_inline:
disabled` escape intact and the old behaviour one config line away. ADR-32 WD2's
upstream-alignment rationale does not survive contact with a binding MUST NOT — but note the
mode is deliberately NOT upstream-verbatim in the other direction either: upstream's opt-out
generates signatures for unannotated code, and the spec asks Rigor to honour annotations
*whenever present*, not to manufacture untyped shadows.

**WD1a — the flip is blocked on a root fix, per the ADR-57 protocol.** With the gate landed,
herb still gains 4 `call.possible-nil-receiver` in the mode — adjudicated in § "WD4 — first
measurement" as a pre-existing `Regexp.last_match` imprecision that `sig/`'s `-> untyped` had
masked, not something the annotations cause. The protocol says an artifact is fixed at root
before the change that surfaces it lands, so match-success narrowing for `Regexp.last_match`
is a prerequisite of the default flip, not a follow-up.

**WD2 — default-wire the bundled plugin, presence-gated.** When the upstream `rbs-inline`
library is resolvable — in Rigor's own environment or through the analyzed project's bundle
per [ADR-90](90-target-library-resolution-from-project-bundle.md)'s fallback — the bundled
plugin activates without a `plugins:` entry, in WD1's conforming (annotation-gated) mode.
The gate is what makes this affordable: a project with no annotations pays a comment scan and
contributes nothing, so default-wiring cannot regress it. This deliberately
reverses [ADR-27](27-tool-distribution-model.md)/[ADR-31](31-contribution-and-supply-chain-policy.md)'s
auto-load deferral for **one bundled plugin**, on three grounds recorded here: the spec
binds; the executed code is the already-bundled plugin plus its declared upstream dependency
(not arbitrary third-party plugin code — the case the deferral guards); and the gate is
[ADR-72](72-gemfile-lock-gated-rbs-overlays.md)'s shape, keyed on what is actually on disk.
Opt-out surface: project-level (a `plugins:` entry disabling it — exact shape open, the
plugin-entry schema has no `enabled:` key today) and per-file (`# rbs_inline: disabled`).

**WD3 — the standalone residual.** A bare `gem install rigortype` has no `rbs-inline`
library anywhere, and "always parsed whenever present" cannot be satisfied without one. The
honest options: (i) promote `rbs-inline` to a core runtime dependency — its dependency
closure is `prism` + `rbs`, both already required, but it adds a versioned surface and
contradicts [ADR-0](0-concept.md)'s zero-dep stance; (ii) keep the residual marked in
`overview.md` and emit a routing hint (an `rbs.coverage.*`-style `:info`) when
annotation-shaped comments are seen with no synthesizer available. Deferred to the WD4
measurement; (ii) is the conservative default.

**WD4 — measurement gate before any default flips.** A corpus sweep with WD1+WD2 active:
count files carrying annotation-shaped comments without the magic comment, and adjudicate
every new diagnostic per the ADR-57 protocol (genuine = the spec working; artifact = fix at
root). The known upstream top-level-def gap (ADR-32 WD9) is measured, not assumed, and its
routing (hint vs upstream issue) decided on the numbers. The first pass ran 2026-07-16 and is
recorded below; it refuted WD1's original shape twice, which is the whole reason the gate
exists.

## WD4 — first measurement (2026-07-16, herb + mail)

The natural experiment is **herb** (marcoroth's HTML+ERB toolchain): pervasive real
rbs-inline annotations (method types, attr annotations, `-> void` returns) across ~25 files,
only 2 carrying the magic comment — **and a hand-written `sig/` covering the same code**.

**Finding 1 — a blocker, found and fixed (an engine bug that predates this ADR).** Enabling
the plugin on herb collapsed the whole RBS env (1,490 classes → 0), un-typing the project
and manufacturing 74 false `call.unresolved-toplevel` — on `require` itself. Mechanics:
`RBS::Environment#add_source` appends to `sources` *before* inserting decls, so a virtual
entry whose constant collides with `sig/` raises mid-insert, the per-entry rescue skips it,
but the poisoned source stays behind and `resolve_type_names` — which rebuilds from
`sources` — re-raises outside every rescue. Overlap between `sig/` and inline annotations is
the *expected* state for a migrating project, and this hit every opt-in user with both. The
fix (landed with this measurement) makes the skip transactional, adds a resolve-time backstop
for the rbs `>= 3.0, < 5.0` range where detection timing may differ, keeps the explicit
`.rbs` as the winner, reports the dropped files via the cache-hit-safe
`virtual_rbs_collision_quarantined`, and warns once naming them.

**Finding 2 — post-fix A/B/C on herb `lib` is sane.** A (no plugin) 11 diagnostics; B
(opt-in, magic default) 11 — zero delta, herb's 2 magic files both collide with `sig/` and
quarantine cleanly; C (`--treat-all-as-inline-rbs`, this ADR's target mode) 12: **−3 genuine
wins** (annotations resolving false `undefined-method` / override-FP pairs) **+4
`call.possible-nil-receiver`**, adjudicated as a *pre-existing* engine imprecision unmasked,
not caused: the receiver is `Regexp.last_match(1)` after a successful `=~` whose group
always participates (`/\n([ \t]+)\z/`), so nil is unreachable at runtime; mode A never saw
it because herb's `sig/` declares those methods `-> untyped`. Routes to a future
match-success narrowing fact, not to this ADR.

**Finding 3 — the naive always-parse wiring fails the no-op property; WD1 rewritten and the
gate landed.** On mail (zero annotations), `--treat-all-as-inline-rbs` moved diagnostics
26 → 42. Cause: upstream's opt-out mode synthesizes a **full `-> untyped` skeleton for every
unannotated def**, and an accepted signature outranks body inference — so the mode actively
*fights* Rigor's inference-first analysis on exactly the projects that write no annotations.
The spec binds Rigor to honour *annotations* whenever present; it does not ask for untyped
shadows of unannotated code. The magic-comment-free mode therefore gates on the file actually
carrying an annotation, detected with upstream's own `AnnotationParser` (ADR-32 WD3 keeps the
grammar upstream's, so the gate must not re-implement it as a regexp).

**Finding 4 — `#:nodoc:`, found because Finding 3's first fix only got mail to 31.** RDoc
directives collide lexically with `#: <type>`, and upstream reads `class Foo #:nodoc:` as a
type assertion of an alias named `nodoc` (it consumes the word, drops the trailing colon). It
is one of the most common comments in Ruby: **61 of mail's files** opted into synthesis on
that alone. Reported upstream as [soutaro/rbs-inline#248](https://github.com/soutaro/rbs-inline/issues/248).

**Finding 5 — the directive is not harmless, and gating on it is not enough.** The initial
read (that the mis-parse only affects the gate, because a directive on a *class* renders back
as a `# :nodoc:` comment) held only for the leading position. In the trailing positions
upstream emits the directive name **as the type**: `def f #:nodoc:` becomes
`def f: (untyped x) -> nodoc`, and `nodoc` resolves to nothing, so
`RBS::DefinitionBuilder#build_instance` raises `NoTypeFoundError` **for the whole class** and
every real annotation in it is silently lost — measured on a class whose
`#: (String) -> Integer` method fell back to body inference because a sibling carried
`#:nodoc:`. Rigor's `stub_missing_referenced_types` does not cover it: that tier takes
`project_sig_files`, so a virtual buffer's undeclared references are never stubbed. rbs-inline
emits 29 of these for Ruby's own `lib/fileutils.rb` (49 across 8 first-party files in
ruby/ruby, plus 128 more in vendored copies). The plugin therefore rewrites every directive to
its spaced spelling (`#:nodoc:` → `# :nodoc:`, which upstream's grammar ignores) before
synthesis, matching on shape (`/\A#:[a-z_][\w-]*:/`) so all 17 directives the Ruby docs list
are covered with no name list. With this, **mail / kramdown / haml / liquid are all
byte-identical** under the mode, and herb keeps its −3 wins.

One trap is worth recording: `Prism::Location#start_offset` counts **bytes** while
`String#insert` indexes **characters**, so the first cut of the rewrite put the space mid-word
(`#:n odoc:`) on any file with multi-byte content and left the directive live. mail's own
`field.rb` caught it (26 → 32); `start_character_offset` is the fix, pinned by a spec.

Verification: 11 plugin specs (no-annotation → no contribution; unannotated inference
survives; annotated file still contributes; `#:nodoc:`-only → nothing; directive never emitted
as a type; a sibling's annotation keeps binding; argument-taking directives; the spaced
spelling untouched; a directive-shaped string literal untouched; the multi-byte regression),
the loader collision specs, the no-plugin path byte-identical on mail, and the full suite
green.

## Rejected alternatives

- **Re-implement the annotation grammar in core.** ADR-32 WD1's grammar-drift rejection
  stands; the binding clause mandates behaviour, not an implementation route.
- **Narrow the spec MUST to match ADR-32.** It reverses a founding commitment ("official
  type sources") that the user report validates, and the clause predates the ADR — the
  accident does not get to rewrite the intent it violated.
- **Keep the status quo unmarked.** Forbidden by ADR-92; the marker already landed.

## Consequences

- Positive: the spec, the ADR corpus, and the shipped default stop disagreeing; `#: void`
  and friends work out of the box wherever the library exists, which is what both the spec
  and the user report ask for.
- Negative / cost: a behaviour-changing default (bounded by WD4's adjudication + the
  baseline); a recorded partial reversal of the ADR-27/31 deferral; WD3's residual keeps a
  marker alive until resolved.
- Carry-over: the opt-out schema for default-wired plugins (WD2); the WD3 choice.

## Relationship to other ADRs

- **ADR-94** — records that rbs 4.0 absorbed the inline reader (`RBS::InlineParser`), which
  would retire this ADR's WD2 (default-wiring a plugin) and WD3 (the standalone residual, an
  artifact of `rbs-inline` being a separate gem). That migration is deferred behind the rbs
  3.x floor, so both stay live; a reader inside `rbs` is the long-run shape of this ADR's
  problem.
- **ADR-32** — the contract this amends: WD2's default and the opt-in activation are
  superseded on acceptance; WD1/WD3/WD4–WD10 (upstream library, synthesizer hook, caching,
  fail-soft) are untouched.
- **ADR-92** — supplies the criterion that forced the reconciliation and holds the marker.
- **ADR-72 / ADR-90** — the presence-gated shape and the bundle-fallback resolution WD2
  composes.
- **ADR-27 / ADR-31** — the auto-load deferral WD2 partially and explicitly reverses.
- **ADR-50** — classifies WD1/WD2 as minor-legal strengthenings; WD4 is their gate.
