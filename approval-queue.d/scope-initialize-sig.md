# Declare every keyword of Scope#initialize in the sig, and retire the #1154 markers that follow

- **PR:** [#2316](https://github.com/rigortype/rigor/pull/2316)
- **Issue:** [#2313](https://github.com/rigortype/rigor/issues/2313)
- **Class:** gate-row
- **Precedent:** [#2311](https://github.com/rigortype/rigor/pull/2311)
- **Decided:** 2026-10-23

## Background

#2311 added three omitted keywords to the hand-written `Scope#initialize` declaration in `sig/rigor/scope.rbs` so their readers rendered. The declaration still omitted 19 more, and each omitted keyword leaves the ivar it seeds without a declared parameter type (#2199's credit), so the matching reader stays unrenderable and its `# sig-gen gap: #1154` marker (or an unmarked residue row) stays. Completing the declaration edits a hand-written `.rbs` and moves the provenance gate's markers and residue pin, which needs a decision.

## Options and trade-offs

- **Add every keyword** (taken) with the optional status of the Ruby default (all optional) and the type the already-declared reader of the seeded ivar has. Every keyword has such a reader, so no type was invented. `match_frame:` stays `untyped` because its reader is `untyped` (`Inference::MatchRebinding::Frame` carries no signature). This is parameter intent, not a forced return type.
- **Add only the keywords whose readers are marked.** Leaves the unmarked residue rows and keeps the declaration incomplete; the omission would stay a trap for the next reader.
- **Re-derive the types from the Ruby defaults.** Rejected: where a reader declaration exists it is the authority, and a wider or narrower parameter type would contradict it.

## Decision

All 19 keywords are added, typed as their readers. `declared_refinements:` and its reader are `Array[String | Symbol]`, since the list can hold `InEffectRefinements::UNKNOWN`. Plainly: the parameter types were copied from the very readers they now earn, so the rows that left residue are parameter intent echoed through #1154, not types proved from a body. The re-audit moves 20 `Scope` rows to generated or parameter intent, and the residue pin for `sig/rigor/scope.rbs` goes 65 to 45. The `# sig-gen gap: #1154` markers on ten rows that became generated-equal or parameter intent are removed (`constant_narrowing` and `published_constant_sourced?` are parameter intent, the rest generated). Three Set readers (`published_constant_sourced`, `declaration_sourced`, `struct_fold_safe_locals`) carry `# authored:` notes: the audit compares an un-elaborated type, but `rigor sig-gen --print` still proposes `Set[untyped]` (#2177), tracked in [#2317](https://github.com/rigortype/rigor/issues/2317). Four #1154 markers stay (`match_frame`, `match_rebinding_closure?`, `last_line_closure?`, `declaration_sourced_global_copies`), the last with a corrected reason. No row moved the wrong way.

## To undo

Restore the shorter `initialize` declaration and the removed markers in `sig/rigor/scope.rbs`, and raise the residue pin back to 65.
