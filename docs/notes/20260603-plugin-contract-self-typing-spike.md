# Typing plugin files against the `Plugin::Base` contract — spike findings

**Date:** 2026-06-03
**Status:** Spike complete. Layer 1 (RBS) + Option B (structural spec) landed;
Option A (strict Steep over the plugin tree) measured **not viable** and shelved;
the "can Rigor warn standalone?" follow-up traced to a scoped inference gap,
written up as **ADR-43**, and the engine + `manifest.rbs` half (WD1–WD5) landed
with zero net FP on the plugin lib tree (WD6 `make check` wiring pending).

## Question

Can plugin files (`plugins/*/lib`, `examples/*/lib`) be type-checked /
constrained against the `Rigor::Plugin::Base` contract using "protocols"
(RBS / structural typing), so a plugin that misuses or mis-overrides the
contract is caught mechanically?

## What was already true

- `sig/rigor/plugin/base.rbs` declared **4 of ~30** methods (`manifest` /
  `initialize` / `init` / `prepare`). The ADR-37 extension DSLs, the
  override hooks, the engine-executed dispatchers, and every authoring
  helper were untyped.
- `make check` (`rigor check lib`) and `make steep-check` both target
  **`lib` only**. `base.rb` is in `lib` (checked); plugin *subclasses* in
  `plugins/*/lib` are in **neither** check target.
- `sig/` is sparse — 37 of 249 lib files — and Steep runs
  `D::Ruby.lenient`, so unsigned collaborators are `untyped`.

## Layer 1 — complete `base.rbs` (landed)

Declared the full author-facing surface (DSLs, hooks, dispatchers,
helpers), receiving still-unsigned collaborators (Diagnostic,
Cache::Descriptor, FlowContribution, NodeContext, Prism nodes) as
`untyped`. Both self-checks stay green. Completing it **immediately
surfaced a real RBS gap the lenient check had masked**:
`IoBoundary#cache_descriptor` (and `#open_url`) were called by `Base` but
absent from `io_boundary.rbs` — now declared. This is the value in
miniature: a complete contract turns a silent untyped hole into a
checked one.

## Option A — strict Steep target over the plugin tree — **NOT VIABLE**

Hypothesis: add a `:plugins` Steep target (`check "plugins/*/lib"`, …)
with `NoMethod` promoted to error, so contract misuse in plugin code is
caught against the now-complete Base RBS.

Measured reality:

1. **Steep *does* check plugin files against Base's RBS** — a probe
   `manifest.totally_bogus_method` in a plugin subclass is caught as
   `Ruby::NoMethod` ("`::Rigor::Plugin::Manifest` does not have method
   `totally_bogus_method`")… but only at `[information]` severity,
   because the `lenient` preset downgrades `NoMethod`. Default
   `steep check` hides it; `--severity-level=information` reveals it.

2. **The fatal false-positive wall:** a plugin subclasses Base (RBS-known)
   but ships **no RBS of its own**, so Steep types `self` as the bare
   `Rigor::Plugin::Base`. Every call to the plugin's **own private helper
   methods** therefore reports `NoMethod`. Measured on
   `rigor-deprecations` alone: 3 false positives —
   `matches?`, `receiver_source`, `deprecation_diagnostic`, all defined
   on the plugin itself (lines 86/93/99). Across 37 plugins this is
   pervasive: every plugin defines private helpers.

   There is no clean way to separate the real signal ("calls a
   non-existent *Base* method", e.g. a typo'd `node_rul`) from the FP
   ("calls its *own* helper") — both render as "`Base` does not have
   method X".

3. Making A viable would require **per-plugin RBS for all 37 plugins** so
   Steep sees each plugin's own methods. That is rejected by scale and by
   the repo's sig-gen-first / avoid-hand-RBS policy
   (AGENTS.md § "RBS Authorship"), and would itself be a large
   FP-bearing surface.

Per the false-positive-discipline value ("never frighten working code"),
A is shelved. The `:plugins` Steep target was **not** committed.

> ⚠️ Gotcha for any re-attempt: `library "set"` in a Steep target
> **crashes** RBS 4.0.2 (`set` is core in Ruby 4.0, not a findable
> library) — it hangs the run via a signature-service thread exception.
> And `steep check <path>` positional filters / `Dir.glob(...).each { check }`
> silently checked **zero** files in this version; only literal
> `check "<dir>"` entries were exercised. Both cost real time here.

## Option B — structural conformance spec — **LANDED**

`spec/integration/plugin_contract_conformance_spec.rb`. Pure-Ruby
`Method#parameters` comparison, no RBS needed, **no FP on a plugin's own
methods**. For each author-overridable hook (`init`, `prepare`,
`flow_contribution_for`, `diagnostics_for_file`) it derives the engine's
call shape from **Base's own signature** (auto-following any contract
change) and asserts every plugin *override* is still callable with it —
lenient on widening (extra optional params / `*rest` / `**keyrest` all
pass; ADR-5 Postel), failing only a *narrowing* override that drops a
required parameter.

Catches the one violation that actually breaks a plugin at runtime —
`def diagnostics_for_file(path:)` dropping `scope:`/`root:` →
`ArgumentError` at dispatch. Verified green on all 37 plugins and
verified to fail (with a precise offender message) on an injected
violation.

## Can Rigor warn instead of Steep? (→ ADR-43)

Follow-up question: Option A used **Steep** to catch contract misuse and
hit a false-positive wall. Can **`rigor check`** (standalone) do it
instead? `dump_type` probes settled it:

- **`call.undefined-method` has teeth and is FP-safe on a plugin's own
  methods.** `Rigor::Plugin::Manifest.new(...)` resolves to
  `Nominal[Manifest]` and `m.totally_bogus_method` fires the rule
  (error). Crucially `dump_type(self)` inside a plugin →
  `Rigor::Plugin::ProbeDump` (the *subclass*), because Rigor reads the
  plugin's `def`s from source — so it does **not** have Steep's
  own-helper FP wall. Rigor is structurally the better tool here.

- **But the contract surface is invisible: inherited-from-RBS-ancestor
  calls resolve to `Dynamic[top]`.** `self.manifest`, `io_boundary`,
  `signature_paths` (all on `Base` in RBS) → `Dynamic[top]`, so misuse
  cannot be caught (Dynamic receiver = open). `class MyHash < Hash` →
  `self.keys` is `Dynamic[top]` too: this is **general** behaviour, not
  plugin-specific.

- **Located:** `rbs_dispatch.rb` `lookup_method` (~L270) — a Ruby-source
  subclass name is absent from the RBS `class_decls`, so method lookup
  short-circuits to `nil` before any ancestor walk; dispatch defaults to
  `Dynamic[top]`. The `class Sub < Base` edge *is* recorded
  (`Scope#discovered_superclasses`, ADR-24 Slice 2) but never consulted
  by `RbsDispatch`.

- **Why it can't be flipped globally:** the `Dynamic[top]` fallback is
  load-bearing FP protection. `class MyController < ActionController::Base`
  calling `params`/`render` against a *partial* gem RBS would FP on every
  inherited method the RBS omits. Precision (inherited return types) and
  risk (`undefined-method` on inherited calls) share one path.

- **The viable shape** — an **allow-list of RBS-complete ancestors**
  (seed `{Rigor::Plugin::Base}`) for which inherited resolution *is*
  performed; everything else keeps the Dynamic fallback. FP-safe by
  construction, dogfoodable, delivers Option A's goal via Rigor with no
  Steep FP wall. Written up as **ADR-43** (proposed, measurement-gated);
  injection point is `rbs_dispatch.rb` `lookup_method`. This ADR-26
  `open_receivers:` knob's dual — open-to-suppress vs closed-to-enable.

## Net

- "Type the plugin contract" splits cleanly: **RBS states the contract
  (Layer 1, landed)**; **a structural spec enforces override conformance
  (Option B, landed)**; **strict Steep over plugin files cannot enforce
  misuse without per-plugin RBS (Option A, shelved on FP grounds)**; and
  **Rigor *can* enforce misuse standalone, blocked only by a scoped
  inference gap (ADR-43, proposed)**.
- The remaining unenforced surface is *misuse of the typed contract from
  within a plugin* (calling a non-existent Base/helper method). Today
  caught at runtime by the plugin's own integration spec, not
  statically. ADR-43's allow-list ancestor resolution is the path to
  catching it in `rigor check` — preferred over per-plugin RBS (which
  would dissolve A's wall too but costs 37 hand-written sig sets).
