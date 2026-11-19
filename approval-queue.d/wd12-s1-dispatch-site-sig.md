# `dispatch_site` and `resolve_site` are declared `-> Type::t?`, and the unrenderable row moves from `dispatch` to `resolve_site`

- **PR:** [#3366](https://github.com/rigortype/rigor/pull/3366)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-20

## Background

Slice S1 of ADR-116's WD12 amendment adds two functions to `MethodDispatcher`, and the lane's brief asked for both to be declared in `sig/`. `rigor sig-gen` proposes nothing for either: it skips both as `sig.skipped.untyped-return`, because the ladder answers what `RbsDispatch.try_dispatch` and other tiers answer, and those are declared `untyped`. Before the slice it skipped `dispatch` for the same reason, and `dispatch`'s declaration (`-> Type::t?`, hand-written) was an `unrenderable` row, one of the 68 residue rows pinned for `sig/rigor/inference.rbs`.

## Options and trade-offs

- **`-> untyped` on both.** Each is a `parameter_only` row, as the fourteen `try_dispatch` rows whose return sig-gen cannot render are (#3363, #3364, #3365). `SIG_PROVENANCE_PARAMETER_ONLY` moves 14 → 16 and the residue pin stays. A rung that calls `MethodDispatcher.dispatch_site(site)` then gets an untyped answer where `MethodDispatcher.dispatch(…)` gives it `Type::t?` today, so every rung slice would add Dynamic call sites against the self-typing ratchet, the cost the amendment avoids for `CallContext#scope`.
- **`-> Type::t?` on both.** `resolve_site` is `unrenderable` residue, as `dispatch` was: the claim sig-gen cannot check sits on the function that holds the ladder. `dispatch_site` returns `resolve_site`'s declared answer and `dispatch` returns `dispatch_site`'s, so sig-gen renders both and each is earned (`parameter_intent`). One residue row arrives and one leaves: the pin stays 68, and `SIG_PROVENANCE_PARAMETER_ONLY` stays 14. The number of declarations sig-gen cannot confirm is the same as before; two more are confirmed from it.

## Decision

Both are declared `-> Type::t?`. This was the expectation written down before the change, and the audit found it: `dispatch` `unrenderable` → `parameter_intent`, `dispatch_site` `parameter_intent`, `resolve_site` `unrenderable`; residue 68, `parameter_only` 14, 1,074 declarations compared with a recorded `def` (1,072 before) and none mismatched. No pin moves the looser way; the compared floor is raised to 1,074.

The precedent is the amendment's own reason for what a rung may read: it has a rung take the scope from the typer because `CallContext#scope` is `untyped` in `sig/`, "and reading it would add `Dynamic` call sites against the self-typing ratchet". The same reason decides the return of the entry every rung will call. It fits loosely: the amendment rules on a reader, not on these two declarations. For `resolve_site`, whose row sig-gen does not render, what carries the declaration is that `dispatch`'s own `-> Type::t?` stood on the same body with the same standing; #3365 declared `CompositeReceiver.try_dispatch` `-> Type::t?` the same way, there with sig-gen rendering it.

## To undo

Declare `resolve_site` `-> untyped`. `dispatch_site` and `dispatch` then lose their rendered return: declare them `-> untyped` as well (`parameter_only`, pin 14 → 16 or 17) or keep `-> Type::t?` on them as residue (pin 68 → 70). The pins and their comments are in `spec/rigor/sig_gen/provenance_spec.rb`.
