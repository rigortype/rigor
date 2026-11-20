# Each entry of the ladder builds its site once for the dispatcher and the user-method rung, and the port is four tables

- **PR:** [#3371](https://github.com/rigortype/rigor/pull/3371)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-20

## Background

Slice S6 of ADR-116's WD12 amendment gives the user-method rung the entry `try_call(site, typer)`, where the site is the call's `CallContext`, "built once per site with `CallContext.build`". The three entries that ask the rung (a call, the read of a compound index write, a literal `send`'s target) asked the dispatcher before it through `MethodDispatcher.dispatch`, with the call's fields as keywords; `dispatch` builds the context inside. The lane's brief made switching those entries to `MethodDispatcher.dispatch_site(site)` optional: allowed only if the output stays identical and the allocation within the run-to-run noise of about 15,000 objects.

The brief also asked for `CallLadder::PORT` and two specs: one that holds a rung's calls on its typer to `PORT`, and one that keeps the callers of the newly public re-entry points inside `call_ladder/` and lists `resolve` and `resolve_site` as the dispatcher's interior. It left the shape of the tables to the lane.

## Options and trade-offs

For the site:

- **Keep `dispatch` and build the site for the rung alone.** Output is identical, and one more context is built for every call the dispatcher does not answer.
- **Build the site once, then `dispatch_site(site)` and `try_call(site, self)`.** `dispatch` was `dispatch_site` behind one `CallContext.build`, so the count is the same, and the rung gets the dispatcher's own site. The index read's wrapper `index_read_dispatch` becomes `index_read_site`, which builds the site its two callers dispatch. `dispatch_miss_result` takes the site beside the values the rungs behind the user-method rung still read.

For the tables:

- **One list, `PORT`.** It gives the reentry spec nothing to tell `scope`, which only reads the frame, apart from the methods that run the typer's code. It leaves a rung module's other public functions, and the dispatcher's interior, as prose in the ADR, which no spec reads.
- **Four tables.** `REENTRY` holds the typer methods made public for a rung, which the reentry spec restricts. `PORT` is `scope` plus `REENTRY`. `SECOND_ENTRIES` lists what a rung module exposes beside `try_call`: one row each, with its reason and whether it is given the typer, so the port spec can hold a module's public functions, and the purity of an entry not given the typer, to the table. `DISPATCHER_INTERIOR` names `resolve` and `resolve_site`.

## Decision

The site is built once and handed to both. Measured with base `df5cc73a6`: `rigor check --no-cache --format json` is byte-identical at `--workers 0` and `2` on `lib/rigor/inference` and `spec/integration/fixtures`, and `tool/engine_alloc_ab.rb` over `lib` gave +1,101, +4,651 and +12,370 objects in three runs (+0.01% at most), inside the about 15,000 objects one engine moves by between runs. The tables are the four above, in `call_ladder.rb`, which the engine does not load. `CallLadderPin`'s table scan counts all seven, so nothing under `lib/` reads them.

The precedent is the amendment's definition of a site and its port: "It calls only the names in `CallLadder::PORT`", and "A spec restricts callers of the re-entry points to `call_ladder/`". Every table here is one of those rules written as data a spec reads, in the way `RUNGS` and `EXCEPTIONS` already are.

## To undo

Switch the three entries back to `MethodDispatcher.dispatch(...)` with keywords and build a site for `try_call` alone; restore `index_read_dispatch`; give `dispatch_miss_result` its old parameters. For the tables, fold `REENTRY` into `PORT`, and `SECOND_ENTRIES` into a list of names, then rewrite the examples of `spec/support/call_ladder_port.rb` that read them. The next rung slices build on the tables. By a static census S5 calls back exactly `PORT`'s four and needs no new row.

S7 calls back `type_of`, the typer's public entry, which can be neither a re-entry point nor marked `@api private`. The rule for it, accepted by the coordinator on #3371's review and not written into code here (no empty constant): `PORT = [:scope, *PUBLIC_CALLBACKS, *REENTRY]`. A `PUBLIC_CALLBACKS` member (`type_of`) counts toward the cut-off of four callbacks, as a re-entry point does. It is exempt from the `@api private` marking check and from the restriction on who calls a re-entry point, both of which stay on `scope` and `REENTRY`. The port spec's ban on typing past the typer (no `ExpressionTyper` or `StatementEvaluator` named, no typing entry such as `type_of` called on a scope, `typer.scope` included) is what keeps the count honest: without it a rung could reach `type_of` through `typer.scope` and leave the cut-off uncounted.
