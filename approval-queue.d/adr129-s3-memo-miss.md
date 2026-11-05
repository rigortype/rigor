# WD1's Memo-miss rule is enforced at MemoAudit.key_audit and the two read-through records' misses

- **PR:** [#PRNUM](https://github.com/rigortype/rigor/pull/PRNUM)
- **Issue:** [#2709](https://github.com/rigortype/rigor/issues/2709)
- **Class:** open-choice
- **Precedent:** [#2868](https://github.com/rigortype/rigor/pull/2868)
- **Decided:** 2026-11-06

## Background

ADR-129 WD1 has two Memo rules: a Memo miss that writes a Table counts as a Resource touch, and so does a read-through
Table's miss whose computation writes another Table. G1′ lists a fault switch for each, so stage 3 needs them. Stage 2
did not implement either: every Memo miss could write `dynamic_origins` and the other Tables without refusing the
enclosing capture, so an enclosing `type_of` entry could replay writes that the Memo, now filled, no longer makes. The
ADR does not say where the rule hooks in.

## Options and trade-offs

- **At `MemoAudit.key_audit`**, which stage 2 made the wrapper of every audited Memo's miss and of the return memo's
  (the memo-audit spec holds every audited label to a `key_audit` site), plus the loop and inject records' two miss
  sites. One `TypingState.current` read per miss with the audit off, and a journal scan from the miss's mark only while
  a capture is open.
- **Track every Table write against an open-miss depth**: no scan, but a branch on every logged write and a counter
  on every miss.
- **A Memo declaration naming its miss method**, wrapped by metaprogramming: no site edits, but a hidden wrapper on hot
  paths.

## Decision

The `key_audit` hook and the two read-through sites (`LoopValueRecord.miss`, the inject fold), through
`TypingState::State#memo_miss`. The refusal is made on the way out even when the miss raises, since the journal keeps
what a raising miss wrote. A refusal here is not a slot touch (`State#refuse_captures`), so it names no Resource. Memos
held in fields (`TypingState.memo_field`, a Frame's `memos:`) are not wrapped: their misses are small lookups, and G1
reports a stale replay they would cause as a table mismatch.

## To undo

Remove `State#memo_miss` and its three call sites; `key_audit` goes back to `yield`.
