# A rung's row spells its call as a home and a method, the entries and exceptions are tables beside `RUNGS`, and the engine does not load them

- **PR:** [#3367](https://github.com/rigortype/rigor/pull/3367)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-20

## Background

ADR-116 § "Amendment, 2026-11-19 — WD12's interface (#3345)" gives slice S2′ in a paragraph. `Rigor::Inference::CallLadder::RUNGS` is "plain frozen data: one row per rung, in order, with the entries that ask it", and a spec reads the typer with Prism and fails unless the rung calls appear in the order and subsets the table declares. Two sequences are exceptions with a row each: the index read, which leaves out the refined rung (#3358), and the index read under a splat.

The amendment does not say what a row holds beyond its entries, how the spec tells which call in the typer is which rung, where an entry's methods are named, what an exception row looks like, or whether the engine loads the file. The slices after this one move rung bodies out of `ExpressionTyper` into modules under `call_ladder/`, and the lane's brief asked that such a move change one row and leave the spec alone. Four choices followed, and the brief left them to the lane.

## Options and trade-offs

**How a row names its call.**

- *The typer method now, a module later.* Two fields of which one is set, and a reader that branches on which.
- *`home` and `asked_as`.* `home` is the constant whose method is called, written from `Rigor::Inference`: `"ExpressionTyper"` for a rung that is still a typer method, `"MethodDispatcher"` for the dispatcher, `"CallLadder::UserMethod"` once that body has moved. `asked_as` is the method names. The reader then has one rule: a call with no receiver is a method of the file it is written in, and a call on a constant is a method of what the constant names. The dispatcher's `dispatch` and `dispatch_site` are two names in one row.
- *The spelling kept in the spec.* The table would not say what its rows mean in code, and every rung slice would edit the spec.

**Where the entries and the exceptions are declared.** In the spec, as the method names its reader looks for, or in `call_ladder.rb` beside `RUNGS`, as `ENTRIES` and `EXCEPTIONS`. In the spec, slice S7 edits the reader, because it moves the literal `send`'s sequence into a module. Beside `RUNGS`, the file someone opens to place a rung also says where each sequence is written, and the reader names no method of the typer.

**What the spec holds a place to.** The amendment asks for the rung calls in order. Read as "the calls to rungs the table knows, in source order", a rung added to the typer with no row passes: the spec cannot know the new method is one. The other reading takes everything a method can answer with (a `return`'s argument and the last expression, through `||` and through locals) and requires all of it to be declared: a rung, or what the entry lists as answering ahead of its ladder. That costs an `ahead` list on each entry (indexed narrowing for a call, the receiver's own `send` for a literal `send`) and a reader that follows a fixed set of statement shapes and fails on any other.

**Whether the engine loads the file.** Required from `expression_typer.rb`, the constant exists wherever the engine runs, for one more file loaded and one more line in a file that was 8 lines under its budget. Not required, nothing the engine executes changes, and a search of `lib/` finds a file that nothing requires.

## Decision

A row carries `home` and `asked_as`. `ENTRIES` and `EXCEPTIONS` are tables in `call_ladder.rb`. The spec holds each place to everything it can answer with, and also fails a method outside the places that asks two or more different rungs. The engine does not load the file, and an example fails when a file under `lib/` requires it or names one of its tables.

The precedent is the amendment. It says "no method is generated from the table, and no rung is wrapped in an adapter to fit it", and it rejects a table the typer walks at run time; tables the engine never reads follow from both. Its "Done when" asks that a new rung be a row and a call "which the pin spec rejects if it disagrees with the row", and that no sequence of two or more rungs be written "without the pin spec checking it"; the reading by answers and the check on other methods are what make those two sentences true of a rung nobody declared. It fits closely on what the spec must reject and loosely on the table's fields, which it does not list.

Three details of the tables come from the same paragraph of the amendment:

- An exception row either omits rungs for its whole entry (`index_read_without_refined`) or is a branch, a method the entry's first method returns through (`splat_index_read`). A branch is held to what the entry asks ahead of that return, then to the entry's rungs less the ones it omits. So the fix of #3358 can ask the refined rung once, ahead of the splat branch, and delete one row; an example runs that edit.
- The splat row names the own-`def` rung's gate by its method (`overriding_own_def?`) and the answer given where it holds (`dynamic_top`). The reader spells the gate at the rung's `home`, so slice S8 changes the rung's row and the gate follows.
- Every row whose `home` is the typer says why in `in_typer_because`: the slice that moves it, or why it stays (the two dropped slices, and the cluster #3359 decides). The amendment's "every rung left in the typer is named with its reason" then holds at each step, not only at the end.

The spec's examples run from two files, `spec/rigor/inference/call_ladder_spec.rb` and one under `spec/rigor/inference/expression_typer/`, through a shared group. `verify-changed` picks a spec by the `lib/` file it mirrors, and an edit to either the tables or the typer has to run the pin before it is pushed.

## To undo

To load the tables in the engine, require `call_ladder` from `expression_typer.rb` and delete the example "are read by nothing under lib/" of `spec/rigor/inference/call_ladder_spec.rb`; `docs/internal-spec/inference-engine.md` § "The call ladder" says the engine MUST NOT read them, and the header of `call_ladder.rb` says it does not load the file.

To change a row's fields, edit `Rung`, `Entry`, `ExceptionRow` or `Gate` in `lib/rigor/inference/call_ladder.rb` and the reader in `spec/support/call_ladder_pin.rb` (`Reading#rung_of`, `#at_home?`, `#expected`, `#written`). The examples under "the reading" build their own tables from those row classes.

To go back to the weaker reading, `Reading#written` would list only the calls `#rung_of` recognises; the examples "shows a call with no row" and "finds a second sequence in another method" go with it, and so do the `ahead` lists.

The slices S6, S5, S7, S8 and S4 each change a row's `home` and `asked_as`, and S7 changes the `send_target` entry's `home` and `written_in`. They depend on the reader taking every spelling from the tables.
