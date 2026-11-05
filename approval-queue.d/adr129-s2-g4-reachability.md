# G4 accepts a declared Memo or Resource whole, keys its ratchet by field, and samples the top-level fixtures

- **PR:** [#2865](https://github.com/rigortype/rigor/pull/2865)
- **Issue:** [#2709](https://github.com/rigortype/rigor/issues/2709)
- **Class:** open-choice
- **Precedent:** [#2841](https://github.com/rigortype/rigor/pull/2841)
- **Decided:** 2026-11-06

## Background

ADR-129 WD5 G4 says: sampling `type_of` entries over the fixtures, every object reachable from a scope field, including through `scope.environment`, and from slot values must be frozen, a Prism node, a slot, or a declared Memo. The ADR does not say how a Memo outside a TypingState slot is declared, how deep a declared Memo or a Table is walked, what the allow list looks like, or which fixtures are sampled.

## Options and trade-offs

- **Declaring Memos outside slots:** a registration API in `typing_state.rb` called where the owner names the field (`TypingState.memo_field`, `TypingState.store_field` for a bound Table's store, Frame `memos:`), against a list kept in the spec. The first keeps G3's "declared where the state is declared" rule.
- **Depth:** a declared Memo or Resource is accepted whole (MemoAudit checks a Memo's purity; a Resource refuses captures), while a Table's container is accepted but its entries are walked, since a hit replays entries by identity. Walking Memo contents strictly would flag every lazily filled cache again.
- **Memo holders:** an unfrozen object whose class declares a memo field is accepted, and its other ivars must keep the object they held when the holder was first reached, checked at each later sample and once more when the run ends; this is what caught `MatchRebinding::Frame`'s first-ask caches (#2864).
- **Ratchet shape:** rows keyed by field with a class set and a reason, rather than G3's `[count, reason]`, because counts depend on the sampling stride. A finding fails when its field is unlisted or a class is outside its row; a row is stale only when the walk never passes through its field, because whether a field holds a given class at the sampled calls is sparse evidence. The rows are the union of what all 50 offsets of the stride found (plus strides 25, 37, 150 and 1000).
- **Skips and leaves:** `Prism::` and `RBS::` objects are accepted without a walk (parse trees, and RBS definitions the loader owns), each with a stated reason. Modules are leaves: their class-level ivars are G3's. A Proc or Method is never walked (its binding and receiver are not followed) and is reported whether frozen or not, so it needs a row naming what it captures (the ScopeIndexer unentered-evaluator lambda); a Hash's `default_proc` is walked as a child.
- **Sample:** each file's `type_of` calls are counted on their own, and every 50th of a file is sampled, over the 145 top-level `spec/integration/fixtures/*.rb` (about 1.2K samples, about 20 s), so one file's phase does not move with another's call count; subdirectories and plugin fixtures are not sampled. `RIGOR_G4_STRIDE` and `RIGOR_G4_OFFSET` move the sample.
- **One mechanical freeze:** `ContributionIndex`'s `@dynamic` and `@narrowing_facts` Sets, built once and only read.

## Decision

As above. The registry write (`@fields`) in `typing_state.rb` falls under TypingState's own G3 allowance. Rows for the discovery index, reporters, construction inputs and the return memo stay on the ratchet with reasons until stage 2 or 3 freezes, splits or declares them.

## To undo

Walk declared Memos strictly, key the ratchet by count or exact class sets, widen the sample, walk Proc bindings, or move the declarations into the spec; each is local to `spec/support/typing_state_reachability.rb`, the spec and the `typing_state.rb` registry.
