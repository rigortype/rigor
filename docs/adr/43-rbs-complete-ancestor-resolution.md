# ADR-43 — RBS-complete ancestor resolution (allow-list inherited-method dispatch)

Status: **Accepted — fully landed (WD1–WD6), 2026-06-03.**
Lets `rigor check` resolve a Ruby-source subclass's *inherited* method calls
against an **allow-listed** RBS-only ancestor, so the engine warns on misuse of
that ancestor's contract surface — the motivating case being the
`Rigor::Plugin::Base` plugin contract itself. The allow-list resolution
(WD1–WD3), its `scope` threading (WD2), and the FP measurement (WD5) are
implemented and verified: on the bundled plugin **lib** tree the change adds
**zero net diagnostics** once `manifest.rbs` is completed (the 26 FPs the
resolution first surfaced were all `Manifest#id` / `#protocol_contracts` — a
real gap in `Manifest`'s own RBS, now closed, the same pattern Layer 1 hit with
`IoBoundary`). **WD6 is done**: the 16 *pre-existing* diagnostics the plugin lib
tree carried — unrelated to this ADR (incomplete RBS for `Analysis::Diagnostic`
singleton factories and `Plugin::AccessDeniedError`'s `< StandardError`, plus one
`Prism::Node#block` flow-narrowing gap in `rigor-rspec` fixed by an explicit
`is_a?(Prism::CallNode)` narrow) — are cleaned, and a `make check-plugins` target
(chained into `make verify` and gated in CI on the cold self-check variant) keeps
the plugin lib tree clean. A contract misuse in any bundled plugin now fails the
build with `call.undefined-method`, verified end-to-end (injected
`manifest.bogus` → non-zero exit). The decision, the false-positive boundary, and
the rejected alternatives are recorded below.

Grounding:
[`docs/notes/20260603-plugin-contract-self-typing-spike.md`](../notes/20260603-plugin-contract-self-typing-spike.md)
(the full spike: why Steep cannot enforce the plugin contract without
per-plugin RBS, the `dump_type` probes that located this gap, and the
`call.undefined-method` teeth-and-FP-safety findings).

## Context

### The question

"We type-check `lib` with Steep and `rigor check`; can **Rigor itself**
(standalone, no Steep) warn when a plugin file misuses the `Plugin::Base`
contract — e.g. calls a method the contract does not define, or that was
renamed out from under it?"

Completing `sig/rigor/plugin/base.rbs` ([the plugin-contract RBS], landed) and
the override-arity conformance spec
([`spec/integration/plugin_contract_conformance_spec.rb`], ADR-37 follow-up,
landed) cover two halves. This ADR is about the third: **static misuse of the
typed contract surface from inside a plugin** — calling `manifest.bogus`,
`io_boundary.bogus`, a renamed helper, etc.

### What the spike settled

A `dump_type`-based spike (note § "Can Rigor warn instead of Steep") established
three facts:

1. **The `call.undefined-method` rule has teeth and is FP-safe on a plugin's
   own methods.** A directly-constructed `Rigor::Plugin::Manifest.new(...)`
   resolves to `Nominal[Manifest]`, and `m.totally_bogus_method` fires
   `call.undefined-method` (error). Unlike Steep — which types `self` as the
   bare RBS `Base` and so false-positives on every call to a plugin's *own*
   un-RBS'd helper (note § "Option A") — Rigor reads the plugin's `def`s from
   source, types `self` as the *subclass* (`dump_type(self) →
   Rigor::Plugin::ProbeDump`), and resolves own-helper calls correctly. Rigor
   is structurally better suited to this than Steep.

2. **But inherited-from-RBS-ancestor calls resolve to `Dynamic[top]`.**
   `self.manifest`, `io_boundary`, `signature_paths` — all declared on `Base`
   in RBS, all called on a `self` typed as the subclass — resolve to
   `Dynamic[top]`, not their RBS return types. So the contract surface is
   invisible to the engine, and misuse cannot be caught: the receiver is
   `Dynamic`, which `call.undefined-method` declines by definition.

3. **This is general behaviour, not plugin-specific.** `class MyHash < Hash`
   resolves `self.keys` (inherited from the core `Hash` RBS) to `Dynamic[top]`
   too. Any Ruby-source subclass of an RBS-only class is blind to its
   inherited RBS methods.

### Why the gap exists, and why it is load-bearing

Located at
[`rbs_dispatch.rb` `lookup_method`](../../lib/rigor/inference/method_dispatcher/rbs_dispatch.rb)
(~L270): dispatch on a `Nominal[Sub]` receiver calls
`instance_method_definition("Sub", …)`, which fails immediately because the
Ruby-source subclass name is absent from the RBS environment's `class_decls`
(`rbs_loader.rb` ~L968). **No ancestor walk runs** — the RBS
`DefinitionBuilder` would walk ancestors if reached, but the class-existence
check short-circuits first. Dispatch falls through every later tier
(`user_class_fallback` also requires the class to be RBS-known) and defaults to
`Dynamic[top]`.

The inheritance edge is *known*: `class Sub < Base` is recorded in
`Scope#discovered_superclasses` (ADR-24 Slice 2) and is already used by
`ExpressionTyper#resolve_user_def_through_ancestors` for cross-file *user*
method resolution. It is simply never consulted by `RbsDispatch` to reach an
RBS ancestor.

Whether or not the `Dynamic[top]` fallback was a conscious decision, its
**effect is false-positive protection** and removing it globally is unsafe:
`class MyController < ActionController::Base` calling `params`, `render`,
`head`, … against a *partial* gem RBS would turn every inherited method the RBS
omits into a `call.undefined-method` false positive on working code. The
precision gain (resolving inherited return types) and the risk (firing
`undefined-method` on inherited calls) flow through the **same** resolution
path — you cannot get one without the other. This is the crux the design must
respect, and it is why a blanket fix is rejected (WD-rejected-A) and a scoped,
allow-listed one is proposed.

This sits beside ADR-26's `open_receivers:`, which is the *inverse* knob:
ADR-26 marks a receiver **open** to *suppress* diagnostics on a class whose
real surface exceeds its RBS (ActiveRecord relations). This ADR marks a small
set of ancestors **closed / RBS-complete** to *enable* diagnostics on
subclasses. The two are duals; both exist to keep false positives at zero while
maximising the precision the engine can safely claim.

## Decision

Add **scoped inherited-method resolution**: when dispatch on a `Nominal[Sub]`
receiver finds `Sub` is not RBS-known, consult `Sub`'s discovered superclass
chain; if an ancestor is on an **RBS-complete allow-list**, resolve the method
against that ancestor's RBS definition (return type + arity + visibility), so
the normal `call.undefined-method` / `call.wrong-arity` / override rules apply
to inherited contract calls. Every ancestor *not* on the allow-list keeps the
current `Dynamic[top]` fallback unchanged.

The allow-list's membership criterion is **"this class's RBS is authoritative
and complete — a call it does not declare is genuinely a mistake."** That is
true of `Rigor::Plugin::Base` (the contract is the RBS, by construction; this
repo owns both) and false of `ActionController::Base`, `Hash`, and essentially
every third-party / core class whose objects routinely answer to methods their
RBS omits.

### Working decisions

- **WD1 — Allow-list seed = `{ "Rigor::Plugin::Base" }`.** The dogfood target
  and the only class we presently *know* is RBS-complete (we author both the
  code and `base.rbs`, and the conformance spec + `rigor check lib` keep them
  in lock-step). The list is a constant in v1 (WD4 revisits sourcing).

- **WD2 — Injection point = `RbsDispatch.lookup_method`** (rbs_dispatch.rb
  ~L270). After the direct `instance_method_definition` lookup returns `nil`
  and *before* falling through, if the receiver class is not RBS-known, read
  its superclass from `Scope#discovered_superclasses`, and if that superclass
  (transitively, WD3) is allow-listed, return
  `instance_method_definition(ancestor, method_name)`. Singleton calls take the
  symmetric `singleton_method_definition` path. The change is additive: a class
  with no allow-listed ancestor behaves exactly as today.

- **WD3 — Walk the full discovered-superclass chain, stopping at the first
  allow-listed ancestor.** A plugin is always a *direct* subclass of
  `Plugin::Base` today, so the immediate parent suffices for the seed, but
  walking the chain costs nothing extra and future-proofs deeper hierarchies.
  Included modules are **out of scope for v1** (plugins do not mix in the
  contract; revisit if a use case appears). The walk reuses ADR-24's existing
  `discovered_superclasses` map — no new bookkeeping.

- **WD4 — Allow-list sourcing: constant now, plugin-manifest later.** v1 hard-
  codes the constant. A future iteration MAY let a plugin declare "my contract
  base is RBS-complete" through the manifest (the ADR-37 / ADR-40 declarative
  route), so an out-of-tree plugin gem can opt its own `Base`-like class in
  without editing the engine. Deferred because the seed needs no it and the
  manifest surface is real design cost; recorded so the constant is understood
  as a placeholder, not the endpoint.

- **WD5 — Measurement gate before flag-on.** Because precision and
  `undefined-method`-firing are coupled (Context), the change ships behind a
  measured-clean bar, not on assertion: (a) full `rigor check lib` stays green;
  (b) the bundled plugin tree (`plugins/*`, `examples/*`) under `rigor check`
  surfaces only *genuine* contract misuse, zero FP on conforming plugins; (c) a
  real-project sweep (Redmine / Mastodon `app + lib`, per the
  `reference_survey_external_projects` protocol) shows **zero** new diagnostics,
  confirming the allow-list scoping leaves open hierarchies untouched. Any FP
  on (b)/(c) blocks the merge — false-positive discipline outranks the feature.

- **WD6 — Wire the plugin tree into the check gate (DONE).** A dedicated
  `make check-plugins` runs `rigor check plugins/*/lib examples/*/lib` (lib dirs
  only — the `demo/` trees deliberately exercise un-modelled framework DSLs and
  are not a clean target). It is chained into `make verify` and gated in CI as a
  "Run plugin-contract check" step on the cold self-check variant. This
  self-enforces the contract on every bundled plugin file — delivering what a
  strict Steep target could not (note § "Option A"), without Steep's FP wall.
  Reaching a green tree required clearing 16 pre-existing diagnostics unrelated
  to the resolution itself: completing `Analysis::Diagnostic`'s singleton
  factories (`from_node` / `from_location`) and `Plugin::AccessDeniedError`'s
  `< StandardError` in RBS, and one `Prism::Node#block` flow-narrowing gap in
  `rigor-rspec`'s `let_scope_index` (a custom `describe_call?` predicate
  guarantees a `CallNode` at runtime but does not narrow the analyzer's
  `Prism::Node` view — fixed with an explicit `is_a?(Prism::CallNode)` re-state,
  not a `# rigor:disable`, so the narrow is real). Teeth verified: an injected
  `manifest.bogus` in a plugin makes `make check-plugins` exit non-zero with
  `call.undefined-method`.

## Rejected / deferred alternatives

- **(rejected) Blanket inherited-RBS-ancestor resolution.** Resolve inherited
  methods for *every* RBS ancestor, not an allow-list. Rejected: reintroduces
  the Rails-controller false-positive wall (Context) — partial gem RBS turns
  every omitted inherited method into a `call.undefined-method` FP on working
  code. Violates the project's top-tier false-positive discipline.

- **(rejected) Strict Steep target over `plugins/*`** (note § "Option A").
  Steep types `self` as the bare RBS `Base`, so it false-positives on every
  call to a plugin's own un-RBS'd helper (measured: 3 FPs on `rigor-deprecations`
  alone). Making it viable needs per-plugin RBS for all 37 plugins — rejected by
  scale and by the sig-gen-first / avoid-hand-RBS policy (AGENTS.md § "RBS
  Authorship"). Rigor's source-reading dispatch does not have this wall, which
  is the whole reason this ADR prefers the engine route.

- **(deferred) Per-plugin RBS via `rigor sig-gen`.** If sig-gen over the plugin
  tree made per-plugin RBS cheap and accurate, Steep *and* a blanket-resolution
  Rigor would both gain teeth without an allow-list. Deferred: sig-gen does not
  yet target the plugin tree, and the allow-list reaches the goal now with less
  surface. Revisit if sig-gen coverage lands.

- **(deferred) Plugin-manifest-declared allow-list** — folded into WD4.

## Relationship to other ADRs

- **ADR-24** (self-method-call resolution) — supplies the
  `discovered_superclasses` edge this ADR consumes; this is the natural next
  step of the same "resolve self/inherited calls" arc, extended from
  user-method ancestors to RBS-complete ancestors.
- **ADR-26** (`open_receivers:`) — the inverse knob (open-to-suppress vs
  closed-to-enable); the two share the goal of zero false positives.
- **ADR-34** (toplevel unresolved-self-call) — same `Dynamic[top]`-as-safety
  default this ADR carves a scoped exception out of.
- **ADR-35** (override signature compatibility) — its rules are *both-sides-
  authored* gated; once a plugin's inherited hooks resolve through this ADR, the
  override rules gain a second, RBS-ancestor-vs-Ruby-override surface to act on
  (a possible follow-up; not in v1 scope).
- **ADR-37 / ADR-40** — the declarative manifest route WD4 defers to.

[the plugin-contract RBS]: ../../sig/rigor/plugin/base.rbs
[`spec/integration/plugin_contract_conformance_spec.rb`]: ../../spec/integration/plugin_contract_conformance_spec.rb
