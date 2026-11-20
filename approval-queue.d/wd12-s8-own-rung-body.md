# The order pin's stray check reads a rung module's own second entries, in its own file, as the rung's body

- **PR:** [#3374](https://github.com/rigortype/rigor/pull/3374)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-20

## Background

`spec/rigor/inference/call_ladder_spec.rb` fails a method outside the places `CallLadder::ENTRIES` names that asks
the ladder for two or more different things. Since S6 (#3371) it counts a call of a second entry
(`CallLadder::SECOND_ENTRIES`) as asking that entry's rung, spelled at the module: on its constant anywhere, or
with no receiver inside the module's own file. Slice S8 moves the overriding-def rung into
`CallLadder::OverridingDef`, with its gate `overriding_own_def?` as a second entry, as the amendment says. The rung's
`try_call` tests that gate and then asks `CallLadder::UserMethod.infer` for the own `def`'s body, the shape the
amendment gives it. The check read the module's own gate as the `overriding_def` rung and failed `try_call` as a
sequence of two rungs.

## Options and trade-offs

- **Split `try_call`**, so that one function tests the gate and another asks user-method inference. The code takes
  a shape for the gate's sake, and nothing is held that is not held now.
- **List the module's `try_call` as a place**, an entry or an exception row with `written_in`. It is no sequence the
  tables could declare: the rung asks one other rung, and an exception row is for a sequence that departs from an
  entry's rows.
- **Read a rung module's own second entries in its own file as its body.** A rung module holds one rung, so a call
  there of one of that rung's second entries (its gate, its positional entry) is the rung at work, not an ask of the
  ladder. The rung's own entry (`try_call`) is still an ask, so a helper that chains it into another rung still
  fails, and so does a method that asks two other rungs. The typer holds several rungs, so there every rung's call
  still counts, as before. Skipping the rung's own entry too would be wider than the case needs: a helper of any
  rung module could then chain `try_call` into another rung unseen.

## Decision

The third, for second entries only. `CallLadderPin::Reading#ladder_asks` skips a call that only `second_entry_rung`
resolves (not one `rung_of` resolves as the rung's own `asked_as`), when it names the rung whose home is the file's. A
second entry's home is always a rung module (`port_spec.rb` fetches each one's file under `call_ladder/`), so the skip
never reaches the typer. A reading example builds a module that tests its own gate and asks one other rung (no stray),
a function of it that chains its own `try_call` into two other rungs (a stray, the own entry counted), and a typer
method that tests the module's gate and asks another rung (a stray). The mutation table in the PR removes the skip,
its own-home condition and the second-entries-only condition, and each fails an example; so does a helper chaining
`TopLevelDef.try_call` into `OverridingDef.try_call` in `top_level_def.rb`. On this checkout no module but
`CallLadder::OverridingDef` calls its own second entry beside another rung, and no result of the check changes for the
rung modules that existed before. The review of #3374 narrowed a first draft that skipped the rung's own entry too.

The precedent is the amendment's second entries: "a rung module may expose a second named entry when a caller
outside the rung asks part of it", so inside the rung the same function is the rung's own code. S6's change to the
check (`wd12-s6-user-method-gate.md`, condition 4) is still in this queue, so it is a sibling here.

## To undo

Delete the `next if !direct && rung && rung.home == home` line and the reading example, and read
`rung = rung_of(node, home) || second_entry_rung(node, home)` again. The overriding-def rung's `try_call` then fails
the check, and the rung would have to be split as in the first option.
