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

All 19 keywords are added, typed as their readers. The re-audit moves 20 `Scope` rows to generated or parameter intent: the residue pin for `sig/rigor/scope.rbs` goes 65 to 45, and the `# sig-gen gap: #1154` markers on the ten rows that became generated-equal (and the stale `# authored:` note on `published_constant_sourced`) are removed. Four #1154 markers stay (`match_frame`, `match_rebinding_closure?`, `last_line_closure?`, `declaration_sourced_global_copies`), the last with a corrected reason. No row moved the wrong way.

## To undo

Restore the shorter `initialize` declaration and the removed markers in `sig/rigor/scope.rbs`, and raise the residue pin back to 65.
