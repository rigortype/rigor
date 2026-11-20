# The order pin's stray check reads a rung module's own entries, in its own file, as the rung's body

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
- **Read a rung module's own entries in its own file as its body.** A rung module holds one rung, so a call there of
  that rung's entry or of one of its second entries is the rung at work, not an ask of the ladder. What the module
  asks of any other rung still counts, and a method there that asks two other rungs still fails. The typer holds
  several rungs, so there every rung's call still counts, as before.

## Decision

The third. `CallLadderPin::Reading#ladder_asks` skips a call of the rung whose home is the file's, where that home is a
rung module (`CallLadderPin::RUNG_HOME`, `CallLadder::`). A reading example builds a module that tests its own gate
and asks one other rung (no stray), a function of it that asks two other rungs (a stray), and a typer method that
tests the module's gate and asks another rung (a stray). The mutation table in the PR removes the skip and the
`CallLadder::` condition, and each fails an example. On this checkout no module but `CallLadder::OverridingDef` calls
its own entry beside another rung, and no result of the check changes for the rung modules that existed before.

The precedent is the amendment's second entries: "a rung module may expose a second named entry when a caller
outside the rung asks part of it", so inside the rung the same function is the rung's own code. S6's change to the
check (`wd12-s6-user-method-gate.md`, condition 4) is still in this queue, so it is a sibling here.

## To undo

Delete the `next if rung && own_rung?(rung, home)` line, `own_rung?` and the reading example. The overriding-def
rung's `try_call` then fails the check, and the rung would have to be split as in the first option.
