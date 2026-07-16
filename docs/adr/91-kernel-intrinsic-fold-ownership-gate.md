# ADR-91 — Kernel intrinsic fold ownership gate + spelling-parity invariant

Status: **Accepted — implemented 2026-07-16 (WD1–WD4, same branch).** The WD4 gate came back
stronger than the adjudication expectation: mail / kramdown / haml `lib` and Mastodon
`app/models` are **byte-identical** to master (the corpora contain no foreign-receiver
intrinsic-spelling call sites, so even the expected hijack-removal diffs did not arise),
`make verify` green, and the WD3 parity spec (34 examples) pins the invariant.

Grounding: the rigor-rs port's upstream-feedback note (rigor-rs
`docs/notes/20260716-upstream-feedback.md`, item 1) and the PR
[#110](https://github.com/rigortype/rigor/pull/110) fix it prompted.

## Context

PR #110 fixed one instance of a bug class: `Kernel.p(42)` declined the identity fold while
`Kernel.format("%d", 1)` folded — two spellings of the same `module_function` surface with
opposite polarities. The fix unified those two sites by hand. The *class* is still open,
because the structure that produced it is unchanged:

- **The ownership check is per-fold and opt-in.** `kernel_owned_call?`
  (`kernel_dispatch.rb` ~L150) is consulted by `p`/`pp`/`String`/`Hash` and — since #110 —
  `format`/`sprintf`, but **not** by `Array` / `Integer` / `Float` / `Rational` / `Complex`
  in the same tier. A user class defining `def Integer(x)` has `conv.Integer("42")` folded
  to `Constant[42]` today — the same hijack shape #110 removed from `obj.format(...)`, still
  live one screen away.
- **The Kernel module-function surface has two owners.** The identity/conversion folds live
  in `KernelDispatch`; the `format`/`sprintf` fold lives in `LiteralStringFolding`
  (`fold_format`). The #110 asymmetry existed precisely because two tiers implemented one
  surface under two guard policies.
- **Nothing pins spelling parity.** `module_function` makes the implicit-self and explicit
  `Kernel.` spellings the same runtime call, but no spec asserts the engine types them
  identically, so the next fold added to either tier can regress the polarity silently — a
  second implementation (rigor-rs) probing at byte level is currently the only detector.

## Decision

**A Kernel module-function fold runs only behind a single dispatcher-held ownership gate,
its method-name surface is data, and the implicit-self / explicit-`Kernel.` spelling parity
is a spec-enforced invariant derived from that same data.**

The criterion is the ADR-52/ADR-53 gate-by-held-key rule applied to a built-in tier: a
capability keyed on "this call is Kernel's own module function" must be gated once, by the
dispatcher, on a key it already holds (method name ∈ a compiled table, receiver
nil/self/`Singleton("Kernel")`, no discovered user redefinition) — never re-derived
per-fold inside tier bodies, where forgetting it is the default failure mode.

## Working decisions

- **WD1 — hoist the gate.** `MethodDispatcher.dispatch_precise_tiers`
  (`method_dispatcher.rb` ~L738, the `PRECISE_TIERS_TAIL` walk) consults `KernelDispatch`
  only when `context.method_name` is in a new `KernelDispatch::INTRINSIC_NAMES` table AND
  the hoisted `kernel_owned_call?` passes. The per-fold guards inside the tier are then
  deleted, not duplicated — after WD1 a fold that "forgets the guard" is unrepresentable.
  Unit probes that call `KernelDispatch.try_dispatch` directly keep today's
  caller-vouches contract.
- **WD2 — one owner per surface.** `fold_format` / `fold_format_constant` move from
  `LiteralStringFolding` into `KernelDispatch`, so every Kernel module-function fold sits
  behind the WD1 gate. `String#%` stays in `LiteralStringFolding` — it is a receiver-typed
  String method, not a Kernel module function.
- **WD3 — parity as a table-driven spec.** A spec iterates `INTRINSIC_NAMES` (the same
  constant the gate reads) with one representative call per name and asserts the inferred
  type of the implicit-self spelling equals the explicit-`Kernel.` spelling. Because the
  spec derives its case list from the gate's own data, a fold added to the table is
  parity-checked automatically, and a fold added *without* the table entry never runs at
  all — both halves of the #110 bug class are closed mechanically.
- **WD4 — gate.** Corpus adjudication rather than zero-delta: the only expected diffs are
  foreign-receiver hijack removals (`obj.Integer(...)`-shaped, strictly FP-reducing —
  `Kernel#Integer` is private, so an explicit non-`Kernel` receiver is necessarily a user
  method). `make verify` plus a Mastodon/GitLab-corpus diff sweep, every diff adjudicated.

## Rejected / deferred alternatives

- **Normalize the spelling instead (rewrite explicit-`Kernel.` calls to the implicit form
  before dispatch).** Strongest form — asymmetry becomes unrepresentable — but the rewrite
  is visible to every tier below, including RBS resolution (public-singleton vs
  private-instance lookup paths), a blast radius WD1 doesn't have. Rejected as
  disproportionate; WD1+WD3 achieve the same guarantee at the fold layer.
- **Keep per-fold guards, just add the missing ones.** Repeats #110's shape: correct today,
  recurrence guaranteed at the next fold. Rejected — this is the structure being retired.
- **Rely on the rigor-rs differential harness.** It found item 1, and its probe corpus is a
  good seed, but it is an external, port-schedule-coupled detector, not a gate in this
  repo's CI. Deferred as a complement (feedback note item 7), demand-gated.

## Consequences

- Positive: the #110 bug class is closed structurally (gate exists once) and pinned
  observably (parity spec); the five currently-ungated conversion folds get the ownership
  guard for free, removing a live hijack-FP hazard; one fewer tier owns Kernel semantics.
- Negative / cost: `dispatch_precise_tiers` gains one table lookup on the hot path
  (bounded, same shape as the `STDLIB_SINGLETON_FOLDERS` precedent); `LiteralStringFolding`
  and `KernelDispatch` unit specs move with the code.
- Carry-over: the WD3 parity spec covers folds only; RBS-tier spelling parity
  (`Kernel.p` resolving via the public singleton vs implicit private instance) is untouched
  and stays the RBS environment's contract.

## Relationship to other ADRs

- **ADR-52 / ADR-53** — supplies the criterion (gate-by-held-key, compiled name tables for
  built-in tiers); WD1 is the same move `STDLIB_SINGLETON_FOLDERS` already made for the
  stdlib singleton folders.
- **ADR-62** — kinship in spirit: WD3 turns an externally-discovered false-negative
  detector (the rigor-rs differential probe) into an in-repo invariant gate.
- **ADR-5** — WD4's FP-reducing direction is the robustness principle's preferred failure
  mode: declining an unowned fold can only remove wrong precision, never reject working
  code.
