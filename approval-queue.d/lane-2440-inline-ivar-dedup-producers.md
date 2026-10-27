# MemberConsistency.member_keys is recorded in producers.yml as an RBS-only mixin key

- **PR:** [#2467](https://github.com/rigortype/rigor/pull/2467)
- **Issue:** [#2440](https://github.com/rigortype/rigor/issues/2440)
- **Class:** gate-row
- **Precedent:** [#1770](https://github.com/rigortype/rigor/pull/1770)
- **Decided:** 2026-10-28

## Background

The review of #2467 found a second cause of the issue's failure. rbs 4.2 counts a module's instance variables once for each declaration of a class that mixes the module in. So when `sig/` and the inline buffer both write `include M`, the class fails to build. The coordinator ruled that `MemberConsistency.member_keys` should key `include` / `extend` / `prepend` members. The declaration-producer gate (`spec/rigor/declaration_facts/producers_spec.rb`) flags any method that names those three kinds, so `member_keys` now needs a `producers.yml` row.

## Options and trade-offs

- **Record the row with a reason.** The method reads parsed RBS members and turns them into a comparison key. It reads no Ruby source and records no declaration context, which is the same situation as the existing `GatedSignaturePlan#narrowed` row.
- **Rename the key kinds so the gate does not see them.** This would hide a real mention of the three mixin kinds from a gate meant to find them, and it would bend the code's shape around the gate.

## Decision

Record the row, with a reason that follows #1770's `GatedSignaturePlan#narrowed` entry. An unused `mixin_kind?` helper was removed instead of being recorded.

## To undo

Delete the `lib/rigor/environment/member_consistency.rb` entry from `producers.yml`. That only makes sense if the mixin keys leave `member_keys`, which would bring back the double-include build failure.
