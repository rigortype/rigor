# Session report — typing the plugin contract (2026-06-03)

**Status:** Implemented and landed across 6 commits (`9a4c22c0` … `eed5371c`).
All verification green. This report consolidates what shipped, the model it
realises, the verification evidence, and the open items — including a
terminology question (`protocol`) deferred to a follow-up.

The investigation log behind the decisions is the companion note
[`20260603-plugin-contract-self-typing-spike.md`](20260603-plugin-contract-self-typing-spike.md);
the normative decision is [ADR-43](../adr/43-rbs-complete-ancestor-resolution.md).

## Goal

The session started from one question: *can a Rigor **plugin file** be typed /
constrained against the `Rigor::Plugin::Base` contract, so a plugin that
misuses or mis-implements the contract is caught mechanically rather than at
runtime?* It then sharpened to: *can **`rigor check` itself** (not Steep) emit
those warnings?*

## What shipped — the three-layer model

"Type the plugin contract" decomposed cleanly into three independent layers,
all landed:

1. **State the contract in RBS** — `sig/rigor/plugin/base.rbs` completed from 4
   methods to the full author surface (the ADR-37 DSLs, the override hooks, the
   engine-executed dispatchers, the authoring helpers).
2. **Enforce override conformance with a structural spec** — a pure-Ruby
   `Method#parameters` check that every plugin's hook override stays callable
   with the engine's invocation (param/arity Liskov-compatibility, ADR-5).
3. **Warn on contract misuse from `rigor check`** — ADR-43 allow-listed
   RBS-complete-ancestor resolution makes a plugin's inherited contract calls
   (`manifest.…`, `io_boundary.…`) resolve against `Base`'s RBS, so a call to a
   method the contract does not declare fires `call.undefined-method`. A
   `make check-plugins` gate turns that capability into CI enforcement.

The load-bearing insight: **Rigor is structurally better at this than Steep.**
Steep types a plugin subclass's `self` as the bare RBS `Base`, so it
false-positives on every call to the plugin's *own* un-RBS'd helper methods
(measured: 3 FPs on `rigor-deprecations` alone) — a strict Steep target over
the plugin tree is not viable without per-plugin RBS. Rigor reads each plugin's
`def`s from source, types `self` as the *subclass*, and so resolves own-helper
calls correctly; only genuine contract misuse fires.

## Commits

| Commit | Layer | Summary |
| --- | --- | --- |
| `9a4c22c0` | 1 | Complete `Plugin::Base` RBS (4 → full surface). Immediately surfaced a real gap: `IoBoundary#cache_descriptor` / `#open_url` were called by `Base` but absent from `io_boundary.rbs` — declared. |
| `7eccf0c7` | 2 | `spec/integration/plugin_contract_conformance_spec.rb` — hook-override call-compatibility guard. Green on all 37 plugins; verified to fail on an injected narrowing override. |
| `3be9b1df` | 3 | ADR-43 draft (proposed). |
| `2a183299` | 3 | ADR-43 engine: thread `scope` into `RbsDispatch.lookup_method`; allow-list (`ALLOWED_RBS_COMPLETE_ANCESTORS = ["Rigor::Plugin::Base"]`) ancestor resolution. Completing it surfaced 26 FPs (all `Manifest#id` / `#protocol_contracts`) → completed `manifest.rbs`'s 22 readers → zero net FP. Regression spec added. |
| `3235e218` | 3 | ADR-43 WD6: `make check-plugins` gate (in `make verify` + CI). Cleared the 16 pre-existing tree diagnostics (`Diagnostic` singleton factories + `AccessDeniedError < StandardError` in RBS; one `Prism::Node#block` flow-narrow in `rigor-rspec`). Teeth verified. |
| `eed5371c` | docs | Documented ADR-43 in `docs/internal-spec/` (`inference-engine.md` dispatch surface + `plugin.md` Base self-check note). |

## Engine change (ADR-43) in one paragraph

`RbsDispatch.lookup_method` gained a `scope` parameter and a bounded exception:
when the receiver class is a Ruby-source subclass not known to RBS, and its
discovered superclass chain (`Scope#superclass_of`, ADR-24) reaches a class on
the frozen allow-list `ALLOWED_RBS_COMPLETE_ANCESTORS` (seeded with
`Rigor::Plugin::Base`), the method resolves against that ancestor's RBS. The
allow-list is the false-positive boundary: a blanket version would
false-positive on `class MyController < ActionController::Base` calling any
method a *partial* gem RBS omits, so every non-allow-listed ancestor keeps the
`Dynamic[Top]` fallback. `scope` defaults to `nil`, so every other dispatch
caller is unchanged. It is the dual of ADR-26 `open_receivers:`
(open-to-suppress vs closed-to-enable).

## Verification

- `make check` (`rigor check lib`): green.
- `make check-plugins` (`rigor check plugins/*/lib examples/*/lib`, 141 files):
  exit 0. Teeth: an injected `manifest.bogus` makes it exit non-zero with
  `call.undefined-method`.
- Steep (`lib` target): green.
- Specs: inference (1852) + analysis/integration (1546) + integration/environment
  (1334) + rigor-rspec plugin (47) — all 0 failures.
- RuboCop: clean on changed Ruby. `git diff --check`: clean.

## Open items

- **ADR-43 WD4 — allow-list sourcing.** The allow-list is a hard-coded constant
  seeded with `Rigor::Plugin::Base`. Opening it to a third-party plugin's own
  `Base`-like class via a manifest declaration (the ADR-37 / ADR-40 declarative
  route) is deferred until a consumer needs it.
- **Terminology: `protocol` (axis decided; partly actioned).** Rigor overloaded
  the word across four things: (A) RBS `interface` — the structural-typing
  concept (Python `typing.Protocol` analog), correctly named **interface**, no
  collision; (B) the inert `protocols:` manifest field (declared, **not
  consumed** anywhere — vestigial ADR-2 metadata); (C) ADR-28
  `protocol_contracts:` (path-scoped behavioural method contracts — a real,
  consumed feature); (D) ADR-37's prose "extension protocols" (the narrow plugin
  hooks). **Decision:** the axis is **interface = structural type**;
  **protocol contract = behavioural method-requirement contract** (the
  Smalltalk/Swift sense, kept). **(B) is retired** (removed from the `Manifest`
  surface — it carried the bare, collision-prone "protocol" word for no
  behaviour). **(C) is kept** under its accurate name; (A)/(D) unchanged.
  The **user-facing document** is landed too: the handbook appendix
  [Protocols, interfaces, and structural typing](../handbook/appendix-protocols-and-structural-typing.md)
  draws the distinction sharply (side-by-side table + "which one do I want?"
  guide), cross-linked from the mypy appendix. Only ADR-43 WD4 (allow-list
  sourcing) remains deferred.

## Pointers

- [ADR-43](../adr/43-rbs-complete-ancestor-resolution.md) — the resolution decision.
- [ADR-28](../adr/28-path-scoped-protocol-contracts.md) — path-scoped protocol contracts.
- [Spike note](20260603-plugin-contract-self-typing-spike.md) — the investigation log.
- [`docs/internal-spec/inference-engine.md`](../internal-spec/inference-engine.md) § "Method Dispatch Boundary".
- [`docs/type-specification/structural-interfaces-and-object-shapes.md`](../type-specification/structural-interfaces-and-object-shapes.md) — Rigor's structural-typing model (RBS interfaces, object shapes, capability roles).
