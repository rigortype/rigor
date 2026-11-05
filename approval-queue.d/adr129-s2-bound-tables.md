# A Table whose stores live with their owners is declared `bound`, and its journal records key on `[store, key]`

- **PR:** TBD
- **Issue:** [#2709](https://github.com/rigortype/rigor/issues/2709)
- **Class:** open-choice
- **Precedent:** [#2803](https://github.com/rigortype/rigor/pull/2803)
- **Decided:** 2026-11-05

## Background

ADR-129 stage 2 puts the four advisory tables (`dynamic_origins`, `void_origins`, `plugin_typed_calls`, `optimistic_origins`) behind journaled Table slots. A Table's journal record is `(slot, key, value)`, and a stage-1 Table keeps its store as the slot's value, so the slot names the store. The advisory tables are not like that: each is an identity Hash that one file's scopes share by reference, a fresh body scope can start its own, and `Scope#with_isolated_side_tables` copies all four. Several stores of one table exist at once, so `(slot, node)` cannot say which store a read observed or where a write should be replayed. The effects, self-call and ADR-46 dependency records that later stage-2 PRs journal have the same shape: their store is the recorder installed in a Frame. ADR-129 does not say how such a Table is journaled.

## Options and trade-offs

- **Key the record on `[store, key]`, built only while a capture is open** (`TypingState.table(…, bound: true)`, `State#log_bound_read` / `#log_bound_write`). The four-entry record stays as WD3 states it. A run with no capture open allocates nothing, which is every production run until stage 3. The ADR-84 return memo already journals a composite key built only while capturing (`[def_node, memo_key]`, #2803).
- **Widen every journal record to five entries** `(op, slot, store, key, value)`. No pair allocation while capturing, but it changes WD3's record shape for every Table to serve some of them.
- **Move the stores into the slot** (one per-thread Hash of stores keyed by owner). It would rewrite how `Scope` threads its tables through `#join` and `#rebuild` and add a lookup to every record and read, for no gain over naming the store in the key.

## Decision

The first option. It keeps WD3's record, follows the return memo's composite-key precedent, and costs nothing while the memo is off. A bound Table cannot be `run_scoped`, since its slot holds no store a run could release. Replaying a write slice (`store[key] = value`) is left to stage 3, where hits first exist and G2's perturbation specs can check it.

## To undo

Drop `bound:` and the two `log_bound_*` methods, and log the advisory tables with the five-entry record or per-owner slots instead. The four Scope slots and their readers (`Scope#dynamic_origin`, `#void_origin`, `#optimistic_origin`, `#plugin_typed_call?`) would stay; only what they log changes.
