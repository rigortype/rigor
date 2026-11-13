# A match-yielding block reads group types from a plain regex literal, keeps #2468's receiver rule, and only four proc forms enter unbound

- **PR:** [#3193](https://github.com/rigortype/rigor/pull/3193)
- **Issue:** [#1371](https://github.com/rigortype/rigor/issues/1371)
- **Class:** open-choice
- **Precedent:** [#2468](https://github.com/rigortype/rigor/pull/2468)
- **Decided:** 2026-11-13

## Background

#1371 asks that a `gsub` / `sub` / `scan` block and a lambda or proc body stop reading the match globals the enclosing method narrowed. It leaves open whether the block's groups are typed from the call's own pattern ("only if that stays sound"), and the lane brief left open whether to act on the method name alone or on the receiver's type. #2468 had already bound `$~` in such a block and had tried both halves of the rest. It backed out typing the groups, because the group walk misreads some pattern sources (#2472), and it backed out forgetting them, because that reported `return unless s =~ /(\d+)/; s.gsub(/(\w)/) { w = $1; w.upcase }` on correct code. An unbound `$1` also cannot meet the issue's first acceptance criterion: it reads `String?`, and `w = $1; w.capitalize` then reports a possible nil receiver.

## Options and trade-offs

- **Groups.** Forget them and bind nothing: sound, but it reports the correct code above and the issue's own example. Type them with the existing walk: quiet, but unsound on the sources #2472 lists. Type them with the walk only on an allow-listed "plain" literal and bind nothing otherwise: sound as far as a 1,000,000-source differential check against Ruby found, quiet on the common shapes, and `String?` on every pattern outside the list.
- **Receivers of `scan` / `gsub` / `sub`.** Act on the name alone: simpler, but it reports a project class's yielding `scan` after a guard, where the block does read the guard's `$1`. Keep #2468's rule (String or untyped): no new report on a receiver known to be something else, at the cost of reading an untyped project object as a String.
- **`grep` / `grep_v`.** A rule naming the receivers that count cannot work, since `Enumerable` is mixed into any class. Gate on a regex-literal argument instead, so `grep(Integer)` keeps the enclosing narrowing, and exclude a receiver whose `grep` the project defines, as round 1 of the review asked.
- **Proc forms.** The issue's four (`-> {}`, `lambda {}`, `proc {}`, `Proc.new {}`), or every call that keeps its block. `Enumerator.new` and `Hash.new` also run later, but an existing unit spec pins that their block keeps the narrowing.

## Decision

Groups are typed from a plain regex literal only, and are unbound otherwise. `scan` / `gsub` / `sub` keep #2468's receiver rule, which is the precedent for it. `grep` and `grep_v` gate on a regex-literal first argument, on any explicit receiver but one whose `grep` the project defines. Only the issue's four proc forms enter unbound. Each choice takes the side that adds no report on correct code that master leaves quiet, except where the pattern is outside the allow-list or the receiver is untyped; the PR body lists those two as known limits.

## To undo

Dropping the allow-list is one line in `Narrowing.yielded_capture_groups` once #2472 makes the walk Onigmo-aware. Acting on the name alone is the `string_match_receiver?` line in `MatchRebinding::YieldingMatch`. Adding `Enumerator.new` / `Hash.new` is `FreshFrameBlocks.deferred_body?` (named `proc_body?` when this was decided), with the unit spec that pins them. The fixture cases under `own_match_*` and `closure_*` in `spec/integration/fixtures/regex_global_narrowing.rb` pin each choice.

[#3220](https://github.com/rigortype/rigor/pull/3220) ([#3195](https://github.com/rigortype/rigor/issues/3195)) reverses the "only the four proc forms" choice for the block of `Enumerator.new` and `Hash.new` on the core class: both now enter unbound, and the unit spec and fixture pins moved with it. The other choices above stand.
