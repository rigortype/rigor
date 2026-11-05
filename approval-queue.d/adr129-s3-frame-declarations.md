# Each Frame declares one of four G1' statements, as a [kind, argument] pair on its Slot

- **PR:** [#2881](https://github.com/rigortype/rigor/pull/2881)
- **Issue:** [#2709](https://github.com/rigortype/rigor/issues/2709)
- **Class:** open-choice
- **Precedent:** [#2841](https://github.com/rigortype/rigor/pull/2841)
- **Decided:** 2026-11-06

## Background

ADR-129 WD5's G1' requires every Frame slot to declare a witness fixture, `typing_unreachable`, `typing_never_reads` or
`memo_shut_while_installed`, with audit mode asserting the middle two. The ADR names the four but not how a slot
records one, nor which of the 26 existing Frames is which.

## Options and trade-offs

- **One `g1` member on `Slot`, a frozen `[kind, argument]` pair** (`[:witness, "path"]`, `[:typing_unreachable, true]`),
  set from four mutually exclusive keywords of `TypingState.frame`. A Frame declaring none or two raises at
  declaration. A Table, Resource or Memo carries `nil`. Cost: one more `Slot` member.
- **Four boolean/String members on `Slot`:** each read is direct, but "exactly one" becomes a cross-field invariant
  every consumer re-checks.
- **A separate registry of declarations beside `TypingState`:** keeps `Slot` small, but a Frame could then be declared
  without one, which is the failure this feature exists to prevent.

Where the audit hangs: `ExpressionTyper#type_of` reads `MemoAudit.enabled?` once per call and, when on, enters and
leaves a depth counter on the thread's state (`TypingState::FrameAudit`, extended on first use as `KeyAudit` is), so the
plain `State#[]` is untouched. A `typing_never_reads` read counts whatever value it answers, nil included.

Classification judgment calls, each decided by reading the code that reads the slot and by running the audit over
`lib`, the memo-audit integration specs and the witness fixtures:

- `file_digest_run` and `rbs_core_root` first looked like `typing_never_reads` (a run-wide install, read by the cache
  layer). The audit reported both read inside `type_of`: the first `type_of` that names a constant demands the loader's
  known class names, which it fetches lazily from the cache, digesting signature files and, on a miss, building the
  environment. Both are witnesses. `rbs_core_root` is a witness that reads only nil: a configured `core_root:` builds
  the environment eagerly, outside any `type_of`, so no fixture makes typing read a non-nil core root. The witness spec
  records that exception by name. G1 cannot fail it, so the slot is a candidate for a fifth statement or for a
  `type_of`-time build to be forbidden.
- `def_node_resolver_run` was first `typing_never_reads`, on negative evidence (no non-nil read inside `type_of` in the
  specs I ran). #2874's `unsettled_chain_incremental_spec` refutes it: under the audit an incremental recheck types a
  file against handles of unchanged files, and `DefNodeResolver.resolve` reads the slot inside `type_of`. It is a
  witness; the harness runs an `IncrementalSession` baseline, edits a file and rechecks (the fixture's project is the
  sibling directory `def_node_resolver_run/`). The key audit's own #2874 findings are tolerated there.
- `scope_index_unentered_evaluator` and `declared_param_writer_scope` are `typing_never_reads`: typing runs under both,
  and only the index walk and the writer gates read them.
- `patched_scanner_guarded_defs` and `patched_scanner_def_visibilities` are `typing_unreachable`: the scan is a Prism
  traversal that never types.
- `flow_tracer` is `memo_shut_while_installed`: the stage-3 shadow skips under `FlowTracer.active?` (WD4).
  `dependency_recorder` is a witness, not a shut switch: WD4 shuts the memo under ADR-46 recording only until the
  dependency reads are a journaled Table (done in #2852), the shadow runs under `--incremental` with the recorder
  installed, and `read_site` and `read_name` read it inside `type_of`. The witness harness runs with
  `record_dependencies: true`. `self_call_resolution_recorder` and
  `effects_collector` are witnesses: their records are journaled Tables the memo replays, and the ADR names the effects
  switch a witness.
- `key_presence_walk`'s witness run is reported by the key audit as a `KeyMismatch` (the rewalk miss reads `retry_frames` without a
  key term) under the audit; the witness spec ignores diagnostics and asks only whether typing read the Frame.

## Decision

The `[kind, argument]` pair with the keyword-per-kind declaration, and the classification above. It follows #2841's
shape for the slot declarations (a keyword per fact, checked at declaration).

## To undo

Drop the `g1` member and the four keywords, `TypingState::FrameAudit` with its two calls in `ExpressionTyper#type_of`,
the witness fixtures and their spec. A declaration that proves wrong is changed where its Frame is declared.
