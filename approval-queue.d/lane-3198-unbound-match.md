# An unbound `$~` reads `MatchData?` only where the frame provably never matches

- **PR:** [#3255](https://github.com/rigortype/rigor/pull/3255)
- **Issue:** [#3198](https://github.com/rigortype/rigor/issues/3198)
- **Class:** open-choice
- **Precedent:** [#3220](https://github.com/rigortype/rigor/pull/3220)
- **Decided:** 2026-11-15

## Background

#3198 asks for an unbound `$~` to read `MatchData?`, as `Regexp.last_match` does. #3220 measured the plain version
of that change and backed it out. Every unbound read answering `MatchData?` added 11 `call.possible-nil-receiver`
rows on redmine. In the analyzer, "unbound" also means "forgotten after a match it could not bind", and a correct
program relies on that `$~` being non-nil. The brief said to prefer the conservative answer wherever the slot could
be non-nil through a path the engine cannot see.

## Options and trade-offs

- Every unbound `$~` reads `MatchData?`. This is the issue as written. It costs the redmine false positives, and any
  match the forget rules miss would report correct code.
- Seed `$~` as `MatchData?` at method entry and let the statement-level forget rules drop it. This is flow-sensitive
  and wins the read before the first match. But those rules are narrower than the broad reading: an unresolved
  `when` constant, for example, does not forget. A seed would survive such a match and report correct code.
- Seed only when the whole frame, by the broad reading, cannot set `$~`, and bind `grep_v` blocks, which Ruby
  enters after a failed `===`. This loses the read before a later match and keeps lambda and proc bodies untyped,
  but it adds no row on six survey targets.

## Decision

The third option. False positives outrank precision (AGENTS.md, ADR-5). It follows #3220, which left the change out
for the same reason, and adds only what can be shown sound.

## To undo

Remove `MatchRebinding.frame_start` and its call in `StatementEvaluator#build_method_entry_scope`, and restore
`scope.forget_match_globals` in `YieldingMatch#grep_entry`. The fixture cases `UnboundLastMatch3198` and
`lastline_frame_local.rb`'s `match_entry` pin the current reading.
