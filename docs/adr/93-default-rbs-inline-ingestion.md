# ADR-93 — Default rbs-inline ingestion: reconciling ADR-32's opt-in with the always-parse spec

Status: **Accepted, 2026-07-18.** Proposed 2026-07-16; WD4's first measurement ran the same
day (§ "WD4 — first measurement"), and all three working decisions have since landed: WD1's
default flip ([#186](https://github.com/rigortype/rigor/pull/186)), WD2's `Configuration.load`
auto-wire with the `enabled: false` opt-out, and WD3's `rbs.coverage.inline-annotations-unsynthesized`
routing hint. The `overview.md` § "Compatibility hierarchy" marker now records the resolved
state (conforming wherever `rbs-inline` is present; the standalone residual carried by WD3) per
[ADR-92](92-normative-status-fidelity.md).
**Amended 2026-07-19** — WD5 (below) closes the engine↔plugin version-skew hazard
[#194](https://github.com/rigortype/rigor/issues/194) surfaced in WD2's gem-name require:
bundled-plugin resolution anchors to the engine.
**Amended 2026-09-08** — WD6 (below) closes
[#823](https://github.com/rigortype/rigor/issues/823): WD1's file gate stopped the `untyped`
skeletons at the file boundary but not inside an annotated file, where they still displaced every
unannotated sibling's inferred type. A defaulted type slot now carries
`%a{rigor:v1:inferred-return}` and the dispatcher declines it.

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
byte-identical under the mode. **Landed** ([#186](https://github.com/rigortype/rigor/pull/186)):
the plugin default is now that mode — a diagnostic strengthening
[ADR-50](50-release-engineering-and-stability-strategy.md) allows in a minor (output is
non-contract; the baseline absorbs), with the per-file `# rbs_inline: disabled` escape intact
and the old behaviour one config line away (`require_magic_comment: true`). ADR-32 WD2's
upstream-alignment rationale does not survive contact with a binding MUST NOT — but note the
mode is deliberately NOT upstream-verbatim in the other direction either: upstream's opt-out
generates signatures for unannotated code, and the spec asks Rigor to honour annotations
*whenever present*, not to manufacture untyped shadows.

**WD1a — the flip was blocked on a root fix, per the ADR-57 protocol; both have landed.** With
the gate landed, herb still gained 4 `call.possible-nil-receiver` in the mode — adjudicated in
§ "WD4 — first measurement" as a pre-existing `Regexp.last_match` imprecision that `sig/`'s
`-> untyped` had masked, not something the annotations cause. The protocol says an artifact is
fixed at root before the change that surfaces it lands, so match-success narrowing for
`Regexp.last_match` (#172) shipped first; with it in place the default flip (#186) landed and
the corpus re-measured clean (herb keeps its −3 wins and gains no `possible-nil-receiver`).

**WD2 — default-wire the bundled plugin, presence-gated. Landed.** When the upstream
`rbs-inline` library is resolvable — in Rigor's own environment or through the analyzed
project's bundle per [ADR-90](90-target-library-resolution-from-project-bundle.md)'s fallback —
the bundled plugin activates without a `plugins:` entry, in WD1's conforming (annotation-gated)
mode. The gate is what makes this affordable: a project with no annotations pays a comment scan
and contributes nothing, so default-wiring cannot regress it. This deliberately
reverses [ADR-27](27-tool-distribution-model.md)/[ADR-31](31-contribution-and-supply-chain-policy.md)'s
auto-load deferral for **one bundled plugin**, on three grounds recorded here: the spec
binds; the executed code is the already-bundled plugin plus its declared upstream dependency
(not arbitrary third-party plugin code — the case the deferral guards); and the gate is
[ADR-72](72-gemfile-lock-gated-rbs-overlays.md)'s shape, keyed on what is actually on disk.
Implementation: the injection lives at `Configuration.load` (the real-project route only, so a
bare `Configuration.new` never auto-wires), gated on a side-effect-free
`Gem::Specification.find_by_name("rbs-inline")` probe, appended after the user's own entries and
skipped when they already list the plugin by gem name or manifest id. Opt-out surface:
project-level via a `plugins:` entry with `enabled: false` (the maintainer-chosen shape, now a
first-class `pluginEntry` key in [`schemas/rigor-config.schema.json`](../../schemas/rigor-config.schema.json)
per [ADR-99](99-config-schema-authority.md); the loader skips such an entry entirely)
and per-file (`# rbs_inline: disabled`).

**WD3 — the standalone residual. Resolved via option (ii).** A bare `gem install rigortype`
has no `rbs-inline` library anywhere, and "always parsed whenever present" cannot be satisfied
without one. The honest options were: (i) promote `rbs-inline` to a core runtime dependency —
its dependency closure is `prism` + `rbs`, both already required, but it adds a versioned
surface and contradicts [ADR-0](0-concept.md)'s zero-dep stance; (ii) keep the residual marked
in `overview.md` and emit a routing hint. **(ii) shipped:** the
`rbs.coverage.inline-annotations-unsynthesized` `:info` fires when the library is absent
(so the WD2 auto-wire could not activate it) *and* the project actually carries an
annotation-shaped comment. Detection is a deliberately coarse routing heuristic in the
diagnostic aggregator — `# @rbs` and `#:` immediately followed by the start of an RBS type,
excluding RDoc directives — never the upstream grammar, which is precisely what is unavailable
in this case; it is FP-safe because a project with no real annotations stays silent, and the
hint is suppressed the moment the library resolves (so the deliberate `enabled: false` opt-out,
which resolves, is never nagged). The diagnostic id is normative in
[diagnostic-policy.md](../type-specification/diagnostic-policy.md).

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
  marker alive (the `:info` hint routes around it, but a standalone install still cannot read
  annotations until the user installs the library).
- Carry-over: none open. The opt-out schema for default-wired plugins (WD2) landed as the
  `enabled:` `pluginEntry` key; the WD3 choice landed as option (ii). ADR-94's rbs-4.0
  `RBS::InlineParser` migration, which would retire WD2/WD3 entirely, stays deferred behind the
  rbs 3.x floor.

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
## Addendum — WD5: bundled-plugin resolution anchors to the engine (2026-07-19)

[#194](https://github.com/rigortype/rigor/issues/194) surfaced the hazard WD2 created without
naming: the auto-wire `require`s the bundled plugin **by gem name** on every run, and a gem-name
require resolves against whichever *installation's* `require_paths` happens to win. The gemspec
declares `require_paths = ["lib"] + Dir.glob("plugins/*/lib")`, so under the checkout's own bundle
the checkout's copy wins — but an engine loaded without its own gemspec activation (`ruby -I lib`,
an embedding, a future packaging) falls through to RubyGems, which activates the newest *installed*
`rigortype` and serves **that** gem's plugin copy. In #194's environment this loaded a v0.2.4-era
`rigor-rbs-inline` predating the WD1 `annotated?` gate: the engine ran with a load-bearing FP gate
silently missing, and `rigor plugins` printed an indistinguishable `[OK] rbs-inline v0.1.0` either
way. The engine and its bundled plugins are versioned together; a gem-resolved copy is skew-prone
by definition.

**Decision (user call, 2026-07-19): every bundled plugin anchors to the engine — not only the
auto-wired one.** In the loader, a `plugins:` entry whose `gem` names a directory the engine
itself bundles (`<engine root>/plugins/<gem>/`, engine root anchored from the loader's own
`__dir__`, which resolves identically in a git checkout and inside an installed gem because the
gem ships the `plugins/` tree) is required **by absolute path** —
`<engine root>/plugins/<gem>/lib/<gem>.rb` — instead of by name. When the anchored file does not
exist (a trimmed packaging, the [ADR-27](27-tool-distribution-model.md) single-binary target),
the loader falls back to today's gem-name require, so no install mode regresses. The rule is
uniform across auto-wired and user-listed entries because the skew mechanism is identical for
both: a user listing `rigor-activerecord` means the engine's `rigor-activerecord`, and before
this decision a stale installed `rigortype` could displace it just as silently.

Boundary notes, recorded so they are not re-litigated:

- **This narrows the ADR-31 surface, not widens it.** WD2's auto-load reversal was justified on
  "the executed code is already vendored"; anchoring makes that literally true — the engine loads
  *its own* vendored file rather than whatever RubyGems resolves the name to. No new code source
  appears, and one (the foreign installation's copy) disappears.
- **The `requirer` seam widens from gem names to name-or-absolute-path.** The loader's injectable
  `requirer` (and every spec fake behind it) now receives the anchored path for bundled plugins;
  the resolved-path capture (#194 slice 1) is unaffected — the loaded feature still ends in
  `/<gem>.rb`.
- **No name-level escape hatch back to gem resolution.** Deliberately: "install a different
  version of a bundled plugin as a gem to override the engine's copy" is indistinguishable from
  the accident this closes. If a real workflow ever needs an external copy, it earns an explicit
  per-entry `path:` key (schema change, [ADR-99](99-config-schema-authority.md)), not a silent
  name race.
- **`doctor`'s skew flag (#194 slice 3) stays wanted.** It guards the fallback path and any
  residual mixed-installation state that anchoring cannot see.

Acceptance: loader specs cover anchored-hit, fallback-on-absence, and the widened requirer
contract; the #194 reproduction (`ruby -I lib` with a stale installed `rigortype`) stops loading
the stale copy; the corpus is untouched (resolution changes which identical-version file loads in
every healthy install, and only rescues the skewed one).

## Addendum — WD6: the file gate is not a member gate (2026-09-08)

[#823](https://github.com/rigortype/rigor/issues/823) is WD1's finding one scope down. WD1 stopped
upstream's `-> untyped` skeletons from displacing inference *project-wide* by gating synthesis on a
file that carries an annotation. Inside such a file the mechanism was untouched: upstream still emits
a full `def f: (untyped x) -> untyped` for every unannotated `def`, and Rigor still trusts an accepted
signature over body inference, so one `# @rbs` retyped every other method in its file to `untyped`.
The binding clause does not permit that in either direction — an annotation is a contract for the
member it is written on, and says nothing about its siblings (`overview.md` § "Inline annotation
handling", amended with this).

**Decision: keep the skeleton and change what it claims.** A type slot upstream *defaulted* is
rewritten back to `untyped` and its member is annotated `%a{rigor:v1:inferred-return}`
(`rbs-extended.md`); `MethodDispatcher::RbsDispatch` declines a marked member, so the call takes the
same body-inference tier a method with no signature takes. Everything the declaration does state
survives — the class keeps its full method surface, `new` keeps the arity of an unannotated
`initialize`, cross-file references keep resolving, and the parameter list still governs arity and
argument-type checking, because the rules that read those look the method up in the environment
rather than reading the dispatcher's answer.

Three notes on the shape, each of which was the alternative:

- **Not a member-level drop.** [PR #779](https://github.com/rigortype/rigor/pull/779) removed the
  unannotated members instead, and a partially declared class reads to RBS as a fully declared one:
  measured on this repo's own `lib/` (775 `# @rbs` lines over 234 files), 32 `call.undefined-method`
  and 12 `call.wrong-arity` on `new`, plus 44 classes to `Dynamic[top]` behind one
  `rbs.coverage.definition-build-failed` where an annotation-free class produced no declaration at all
  and cross-file names stopped resolving. Keeping the declaration is the fix's precondition.
- **Marked at synthesis, not inferred from shape.** The engine could have keyed on provenance instead
  — a `virtual:rbs-inline:` buffer plus an all-`untyped` method type — with no plugin change. That
  answer is a guess about authorship, and it is wrong for the one author who states `#: () -> untyped`
  deliberately; it would also silently rot the day upstream changes its default. Which slots upstream
  defaulted is a fact only the synthesizer has, and upstream hands it over through its own public
  `Writer#default_type` accessor: rendering with a distinctive stand-in makes "the author wrote
  nothing here" observable in the output. The stand-in is rewritten to `untyped` before the RBS is
  contributed — an undeclared type alias raises `NoTypeFoundError` for the whole class, which is
  WD4's Finding 5 all over again.
- **The unit is the type slot, not the member.** `# @rbs times: Integer` with no return annotation
  declares a parameter and defaults a return; the parameter binds and the return is inferred. That is
  the same rule, applied where the author actually stopped writing.

Measurement (ADR-57 protocol). **herb**, the WD4 corpus, as its `.rigor.dist.yml` configures it:
byte-identical, 8 diagnostics before and after. That arm is close to vacuous on its own — herb ships
a hand-written `sig/` covering the same code, so 13 of its inline contributions quarantine on the
collision and the mechanism barely runs. The discriminating arm is herb's `lib/` with no `sig/`
alongside it, where the inline lane is the only signature source: 29 of 42 files contribute RBS, and
**314 of their 474 declared members are marked inferred** — every one a member that used to impose
`-> untyped` on its callers. Diagnostics over that tree move **30 → 31**. The single delta is a
`flow.always-truthy-condition` on `herb/dev/runner.rb`, adjudicated as a **pre-existing engine
imprecision** rather than an artifact of this change: `ops.all? { next false unless o; true }` folds to
`Constant[true]` because the `next false` arm does not reach the block's return type, and the same
warning reproduces on a five-line plain-Ruby file with no plugin, no annotation and no synthesis at
all. herb's `-> untyped` skeleton was masking a diagnostic Rigor already emits for everyone else,
which is WD4's Finding 2 with a different root; it routes to its own issue, and unlike WD1a's
`Regexp.last_match` this change does not create the exposure class.
