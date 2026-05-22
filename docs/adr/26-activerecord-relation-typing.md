# ADR-26 — ActiveRecord relation typing

Status: **accepted, 2026-05-22 — implemented.** Records the design
for typing `ActiveRecord::Relation`-returning call sites in
`rigor-activerecord` (`has_many` accessors, `Model.where`, `scope`s)
after a first implementation attempt regressed the project's
false-positive discipline and was reverted. The decision is a
four-part design whose only engine-side change is a narrow
`call.undefined-method` exemption for plugin-declared "open" receiver
classes. All five implementation slices landed; re-verified against
Mastodon's `app/models` (237 models) with zero scope-on-relation
false positives.

## Context

`rigor-activerecord` types class-side finders (`Model.find` →
`Nominal[Model]`, `find_by` → `Nominal[Model] | nil`), singular
associations (`post.user` → `Nominal[User]`), and instance-side
column accessors (`user.name` → `Nominal[String]`). One large surface
is still untyped: every call that returns an `ActiveRecord::Relation`
— a `has_many` / `has_and_belongs_to_many` accessor (`user.posts`),
`Model.where(...)` / `Model.all` / `Model.order(...)`, and
user-declared `scope`s (`Post.published`). Those call sites degrade
to the RBS-erased `untyped` envelope: chained query methods, finders,
and block iteration over a relation carry no element type.

### The reverted first attempt

A first implementation (commit `82dc9e0`, reverted by `c2b5d8f`)
bundled a generic `ActiveRecord::Relation[Elem]` RBS with the plugin
(via ADR-25 `signature_paths:`) and contributed
`Nominal[ActiveRecord::Relation, [Nominal[Model]]]` for the relation
call sites.

It was verified by running `rigor check` with the plugin active
against Mastodon's `app/models` (237 model files). The result was a
**false-positive regression**: 17 of 20 `call.undefined-method`
diagnostics were user-defined scopes invoked on a typed relation —
`User.approved.confirmed`, `relation.with_domain`,
`relation.by_rank`, `relation.newest_first`, `relation.unresolved`,
and so on.

The root cause is structural. An `ActiveRecord::Relation`'s real
method surface is **unbounded**: a relation responds to every
`scope` declared on its model (via the `scope` DSL, or in a concern's
`included do … end` block, or as a plain `def self.…` class method),
because ActiveRecord delegates unknown relation calls to the model
class. No static RBS can enumerate that set. Typing the relation as a
closed `Nominal[ActiveRecord::Relation]` makes the class "known" to
the `call.undefined-method` rule, so every scope call on the relation
— canonical, working Rails code — surfaces as an error. That
frightens working code, which the project's first value forbids.

### The intersection investigation

Typing the relation as `Intersection[Relation[Model], untyped]` was
investigated as a fix. The undefined-method rule
(`Analysis::CheckRules`) keys off `concrete_class_name(receiver)`,
which returns `nil` for `Union` / `Dynamic` / `Intersection` / `Top`
/ `Bot` — so an `Intersection` receiver **does** suppress the false
positive. But the method dispatcher does not full-dispatch
`Intersection` members through the RBS tier
(`ShapeDispatch#dispatch_intersection` only projects shape carriers;
a plain `Nominal` member is not reached). Empirically — confirmed by
the integration test `resolves the block element type through the
relation end-to-end` — `relation.each { |p| … }` then fails to type
`p` as the model, and chained query methods lose their element type.
`Intersection` alone trades the false positives for the loss of *all*
relation precision, leaving the feature no better than the RBS-erased
envelope.

## Goals

A correct relation typing must satisfy all four:

- **G1 — chained query precision.** `User.where(x).order(y).limit(n)`
  stays `Relation[User]`.
- **G2 — finder extraction.** `relation.first` → `Model?`,
  `relation.find(id)` → `Model`.
- **G3 — block-element typing.** `user.posts.each { |p| … }` types
  `p` as `Model`; this composes with the column-accessor typing so
  `user.posts.each { |p| p.title }` resolves `p.title` to the
  column's value type.
- **G4 — zero false positives.** A call to *any* user-defined scope /
  class method on a typed relation MUST NOT produce
  `call.undefined-method`.

G1–G3 require the relation receiver to be a concrete carrier the
engine can dispatch and block-fold against — i.e. a plain `Nominal`.
G4 requires the relation receiver to be non-concrete so the
undefined-method rule skips it. With a single carrier the two pull in
opposite directions; the intersection attempt resolved the conflict
on the type carrier and lost G1–G3 to an engine limitation.

## Decision

Resolve the conflict **at the diagnostic layer, not the type
carrier.** The relation stays a plain
`Nominal[ActiveRecord::Relation, [Nominal[Model]]]` — so method
dispatch and block-fold are entirely normal and fully precise (G1–G3)
— and the `call.undefined-method` rule is taught to *exempt* the
relation class (G4). Four parts:

### Part 1 — engine: an `open_receivers` exemption

A class may be declared **open** — statically known to respond beyond
its RBS-declared method surface. `Analysis::CheckRules`'
`undefined_method_diagnostic` skips a receiver whose class is open:
after the existing `discovered_method?` / `rbs_class_known?` /
`definition_available?` / `lookup_method` guards and before
`build_undefined_method_diagnostic`, `return nil` when the class is
open.

The set of open classes is contributed by plugins through a new
optional **`open_receivers: [String]`** plugin-manifest field (array
of fully-qualified class names). `CheckRules` consults the plugin
registry (reachable as `scope.environment.plugin_registry`, the same
handle `MethodDispatcher#plugin_owns_receiver?` already uses) and
treats a receiver class as open when any loaded plugin lists it.

This is the *whole* engine change. The relation type stays a plain
`Nominal`, so the dispatcher, the RBS tier, and the block-fold are
untouched — G1–G3 work because nothing about dispatch changes; only
the diagnostic *check* is exempted.

### Part 2 — plugin: the bundled relation RBS

`rigor-activerecord` ships `sig/active_record/relation.rbs` — a
generic `class ActiveRecord::Relation[Elem]` that
`include Enumerable[Elem]` and declares the query-builder (return
`self`), finder (return `Elem` / `Elem?`), aggregate, persistence,
and instantiating-builder surface. It is contributed through the
manifest's `signature_paths: ["sig"]` (ADR-25). The manifest also
declares `open_receivers: ["ActiveRecord::Relation"]`.

The RBS is deliberately generous — a method genuinely on `Relation`
but missing from the file would, absent the Part 1 exemption, be a
false positive; with the exemption a miss merely costs precision (the
call resolves to `untyped`). The RBS exists for G1–G3 precision, not
for G4 soundness.

### Part 3 — plugin: relation-typed contributions

`flow_contribution_for` contributes
`Nominal[ActiveRecord::Relation, [Nominal[Model]]]` for:

- `has_many` / `has_and_belongs_to_many` association accessors;
- class-side `Model.where` / `all` / `order` / `limit` / `none`;
- class-side calls whose name is a discovered `scope` of the model.

### Part 4 — plugin: scope-on-relation interception

A scope call on an already-typed relation
(`User.where(active: true).published`) must keep the relation type
through the chain. `flow_contribution_for` — consulted before the RBS
tier — recognises a receiver typed
`Nominal[ActiveRecord::Relation, [Nominal[Model]]]` and, when the
method name is a discovered `scope` of `Model`, contributes
`Relation[Model]` again. Non-scope methods decline, so the RBS tier
still resolves `where` / `each` / `first` precisely.

## Working decisions

- **WD1 — the exemption mechanism is a dedicated `open_receivers:`
  manifest field.** Rejected alternatives: (a) extend the existing
  `owns_receivers:` field to *also* suppress undefined-method —
  smallest change, but overloads a field whose current meaning is
  "the plugin handles dispatch routing for this receiver" with an
  unrelated diagnostic-suppression concern; (b) an RBS class
  annotation (`%a{rigor:v1:open}`) or inferring openness from a
  declared `method_missing` — the most general (works without a
  plugin) but the largest change, and the `method_missing` inference
  has a hazard: `BasicObject#method_missing` is in core RBS and
  resolves through every class's ancestry, so a naive "declares
  method_missing ⇒ open" rule would exempt *every* class unless it
  carefully excludes the `BasicObject` default. The dedicated field
  is explicit, plugin-scoped (the exemption is active exactly when
  the relation RBS is also loaded), needs no new grammar, and carries
  no ambiguity.

- **WD2 — the relation type is a plain `Nominal`, never an
  `Intersection` or `Dynamic`.** The conflict between G1–G3 and G4 is
  resolved by exempting the *diagnostic*, not by weakening the *type*.
  A non-concrete carrier was shown to forfeit dispatch and block-fold
  precision.

- **WD3 — `first` / `last` / `find_by` on the relation return
  `Elem?`.** This is honest — those methods genuinely return `nil` on
  an empty relation. It is the one place relation typing can newly
  raise `call.possible-nil-receiver` (on `relation.first.foo` without
  a guard). Calibration point: the Mastodon `app/models` run already
  shows 5 `possible-nil-receiver` from the pre-existing `find_by`
  contribution across 237 models — a low rate. If the relation
  finders push that materially higher, reconsider against the
  column-accessor precedent (WD-non-nullable in the column-accessor
  work), which chose leniency over a nil-flood. Decision for v1:
  keep `Elem?`; revisit on measured evidence.

- **WD4 — scope interception covers the `scope` DSL only.** Scopes
  declared in a concern's `included do … end` block, and class
  methods used as scopes (`def self.recent`), are not discovered, so
  a chain through them loses the relation type *after* that call.
  This is a precision gap, not a false positive — the Part 1
  exemption keeps G4 intact regardless. Concern-scope discovery and
  `def self.…`-as-scope discovery are demand-driven follow-ups.

- **WD5 — the bundled RBS conflicts degrade through ADR-25's
  failure memo.** A project that supplies its own ActiveRecord RBS
  (e.g. via `rbs collection`) conflicts with the bundled
  `ActiveRecord::Relation`; the conflict is handled by the existing
  plugin-RBS failure memo (ADR-25 WD4) — the richer upstream
  definition wins, and `open_receivers` still exempts the class.

- **WD6 — `open_receivers` is additive to the pre-1.0 plugin
  contract.** A new optional manifest field; no existing plugin
  breaks; safe within v0.1.x / v0.2.x.

## Alternatives rejected

- **`Array[Model]`.** Typing the relation as an array makes every
  chained `.where` / `.order` a false `call.undefined-method` (those
  methods are not on `Array`). Violates G4.

- **`Dynamic[Relation[Model]]`.** Suppresses the false positives
  (a `Dynamic` receiver is non-concrete) but loses G1–G3 — a
  `Dynamic` receiver dispatches to `Dynamic`. Empirically equivalent
  to no typing.

- **`Intersection[Relation[Model], untyped]`.** Suppresses the false
  positives but the dispatcher does not full-dispatch `Intersection`
  members through RBS, so block-element typing and chained-query
  precision are lost (G1–G3). Empirically verified.

- **An engine change to full-dispatch `Intersection` members through
  every dispatch tier (and the block-fold).** This would make the
  intersection approach work, and is a defensible general
  improvement, but it touches the dispatcher *and* the block-fold and
  is materially larger than the Part 1 exemption. The
  `open_receivers` exemption achieves G1–G4 with a strictly smaller,
  better-contained change; the Intersection-dispatch generalisation
  is left as an independent future improvement.

## Implementation slices

1. **Engine — `open_receivers`.** Add the optional `open_receivers:`
   field to `Plugin::Manifest` (with validation, mirroring
   `owns_receivers`); add a `Plugin::Registry#open_receiver?` helper;
   `Analysis::CheckRules#undefined_method_diagnostic` consults it and
   skips an open receiver. Specs: manifest field accept / default /
   validation / `to_h`; a `CheckRules` example proving an open class
   is exempt and a non-open class still flags.

2. **Plugin — bundled RBS.** Re-land `sig/active_record/relation.rbs`
   and the manifest `signature_paths: ["sig"]` +
   `open_receivers: ["ActiveRecord::Relation"]`; add `sig/**/*.rbs`
   to the gemspec `files`.

3. **Plugin — relation contributions.** Re-land the
   `flow_contribution_for` relation-typed contributions for
   `where` / `all` / `order` / `limit` / `none`, `has_many` /
   `has_and_belongs_to_many` accessors, and class-side scopes.

4. **Plugin — scope-on-relation interception.** `flow_contribution_for`
   recognises a `Nominal[ActiveRecord::Relation, [Model]]` receiver
   and re-contributes the relation type for a discovered-scope method.

5. **Re-verify against Mastodon `app/models`.** Confirm zero
   scope-on-relation false positives and that block-element precision
   is present (`user.posts.each { |p| p.<column> }` resolves). Record
   the run alongside the existing survey notes.

No slice is scheduled by this ADR.

## References

- Commits `82dc9e0` (the reverted first attempt) and `c2b5d8f` (the
  revert, whose message records the verification finding and the
  intersection investigation).
- [ADR-25](25-plugin-contributed-rbs.md) — the plugin-contributed-RBS
  mechanism Part 2 builds on.
- [ADR-10](10-dependency-source-inference.md) § 5a — the
  `owns_receivers` manifest field and `plugin_owns_receiver?`, the
  precedent for WD1's rejected alternative (a) and the registry
  handle Part 1 reuses.
- [ADR-5](5-robustness-principle.md) — the leniency principle that
  makes the Part 1 exemption sound: a class with an unbounded dynamic
  method surface warrants a lenient (false-negative-tolerant) read.
- `lib/rigor/analysis/check_rules.rb` `#undefined_method_diagnostic`
  — the rule Part 1 amends.
- `plugins/rigor-activerecord/README.md` § "Future direction" — the
  relation-typing track this ADR designs.
