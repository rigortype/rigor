# The order pin's stray check counts a re-entry into a place on the typer a module is given as an ask

- **PR:** [#3377](https://github.com/rigortype/rigor/pull/3377)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-20

## Background

`spec/rigor/inference/call_ladder_spec.rb` fails a method outside the places `CallLadder::ENTRIES` names that asks the
ladder for two or more different things. A rung counts, and so does a method a place is written in, since a
continuation is the rungs it holds; the second counted only when called with no receiver in the place's own file.
Slice S4 makes `call_result_type_for`, the call entry's first method, a re-entry point: the refined rung, now
`CallLadder::Refined`, asks it again on the typer it is given (`typer.call_result_type_for(node, receiver_override:
member)`) for each member of a union receiver that no refinement wins. In the typer that call had no receiver and
counted; in the module it has one, so the check would no longer see it. A module function that re-entered the ladder
and then asked another rung would pass. The lane's brief did not cover this.

## Options and trade-offs

- **Leave the reading as it is.** No result changes on this checkout, and the hole stays: before S4 no rung module
  could call a place's method (none was in `PORT`), and S4 is what makes one callable.
- **Count a call on the local `typer` of a typer place's method.** It is the spelling the port spec already knows the
  typer by (`CallLadderPort::TYPER`), now taken from one constant of the pin's reader. In the typer's own file a local
  of that name would be another typer, whose ladder is still asked; no method there has one today. A typer reached
  another way is not seen, as for the port spec.
- **Resolve every call on the local `typer` to the typer's home**, rungs included. Wider than the case: no rung homed
  in the typer is in `PORT`, so the port spec already fails such a call.

## Decision

The second. `CallLadderPin::Reading#place_ask?` counts a place's method asked with no receiver in its own file, as
before, and asked on the local `typer` for a place of the typer. A reading example builds a rung module that re-enters
once (no stray), a function that re-enters and asks another rung (a stray), and one that does the same on another
local (not the typer's). On this checkout the refined rung's `refined_receiver_result` re-enters once
and asks no rung, so no result of the check changes.

The precedent is the check's own rule that a method a place is written in counts as an ask, read for the spelling a
rung module has. S8's change to the same reader (`wd12-s8-own-rung-body.md`) is still in this queue, so it is a sibling
here.

## To undo

Delete `place_ask?`'s second branch and the reading example, and read
`node.receiver.nil? && place_methods.include?([home, node.name])` again in `ladder_asks`. `CallLadderPort::TYPER` can
keep its literal back.
