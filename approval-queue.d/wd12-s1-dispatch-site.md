# `dispatch_site` is `dispatch` for a built site, `dispatch` delegates to it, and no typer call site switches yet

- **PR:** [#3366](https://github.com/rigortype/rigor/pull/3366)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-20

## Background

ADR-116 § "Amendment, 2026-11-19 — WD12's interface (#3345)" gives slice S1 in two sentences: `MethodDispatcher.dispatch_site(context)` takes a site its caller built, and `resolve` builds the context and delegates to `resolve_site`, so no pre-check is copied. The dispatcher had two keyword entries before the slice. `dispatch` is the one the typer calls: it runs the ladder, then makes the transitive-void record and the trace event. `resolve` is the ladder alone, which a tier that dispatches again calls. The amendment does not say which of the two `dispatch_site` stands for, what `dispatch` becomes, or whether anything calls the new entry in this slice. The lane's brief left all three to the lane.

## Options and trade-offs

- **Which entry.** `dispatch_site` as `resolve` for a built site would leave the two records to its caller, and every rung that dispatches would have to make them. As `dispatch` for a built site it is what a rung calls in place of `MethodDispatcher.dispatch`, with nothing else to remember.
- **What `dispatch` becomes.** It could keep calling `resolve` and repeat the two records beside `dispatch_site`'s copy of them: two writings of the same epilogue, which is the duplication the amendment removes for the pre-checks. Or it builds the context and calls `dispatch_site`, so the records are written once. The second costs nothing: one context a call, as before (measured: `dispatch` allocates one object, `dispatch_site` none).
- **A caller in this slice.** One of the typer's nine `MethodDispatcher.dispatch` sites could switch to `CallContext.build` + `dispatch_site` now. The amendment gives that to the rung slices (S6 and later), which build the site once per call and hand it to each rung; a site switched alone now would be built for the dispatcher only and rebuilt when its rung moves. With `dispatch` delegating, `dispatch_site` already runs for every dispatch (2,298,994 in one check of `lib`), so no switch is needed to keep it from being dead code.

One path changes cost. A `dispatch` or `resolve` call with no receiver type returned before a context was built; it now builds one and `resolve_site` returns nil. Keeping a guard in the keyword entries to avoid that would be the copied pre-check the amendment rules out. One check of `lib` makes no such call.

## Decision

`dispatch_site(context)` is `dispatch` for a caller that holds the site: the ladder, then the two records. `dispatch` builds the context and calls it. `resolve_site(context, plugin_typed_sink:, skip_project_patched:)` holds the guard, the split and the order, and `resolve` builds the context and calls it with the two flags. No `ExpressionTyper` call site changes.

The precedent is the amendment itself: "so no pre-check is copied" is applied to the records after the answer as well as to the checks before it, and "built once per site with `CallContext.build`" is why the typer's sites wait for their rung.

What a site answers when it sets `self_type_override` or `public_only` is left unspecified, and `docs/internal-spec/inference-engine.md` says so. No caller of `dispatch` could set them, the tiers read them from any context, and a re-entry through `resolve` builds its context without them.

## To undo

Make `dispatch` call `resolve` again and repeat the two records, or give `dispatch_site` a caller in the typer. The examples that hold the delegation are in `spec/rigor/inference/method_dispatcher/dispatch_site_spec.rb` ("what each entry passes on"); `docs/internal-spec/inference-engine.md` § "Method Dispatch Boundary" and § "Dispatch tier contract" state it, and the code map's "Method dispatch" row describes it. The rung slices of WD12 call `dispatch_site` and depend on its being `dispatch`'s equal.
