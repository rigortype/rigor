# The tiers that dispatch again, and the parts of an optional count, keep re-entering through `resolve`

- **PR:** [#3366](https://github.com/rigortype/rigor/pull/3366)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-20

## Background

Three places inside the dispatcher dispatch a call again: the composite-receiver tier, once for each member of a `Union` or nil-removing `Difference` receiver; the project-patched tier, for the old name of an alias; and the optional-count split, once or twice for the parts of a `nil`-able count. Each calls `MethodDispatcher.resolve` with keywords, which builds a context. Slice S1 of ADR-116's WD12 amendment adds `resolve_site(context, …)`, and the lane's brief asked whether the composite tier should now re-enter through it with `context.with(receiver: member)`, on two conditions: identical output and no extra allocation.

## Options and trade-offs

- **`resolve_site(context.with(receiver: member), plugin_typed_sink: …)`.** It reads as the site with one field changed. It fails the allocation condition: `CallContext#with` takes its changes as keywords, so each call allocates a Hash beside the new context, two objects where `CallContext.build` allocates one (measured). One check of `lib` re-enters `resolve` 227,878 times, every time from this tier, so the switch would add about 228,000 objects to that run, against a run-to-run noise of about 15,000. It also changes what is carried: `with` copies `self_type_override` and `public_only`, and the tier's own rule is that `self` binds to the projected member, which "falls out of re-entering `resolve` rather than needing a `self_type_override`". Every context that reaches the tier today has both at their defaults, so the output would be identical now; it would stop being so for a site that sets one.
- **`resolve_site(CallContext.new(member, …nine positionals…), …)`.** One object, as today. It writes the field list out in a second place, which `CallContext.build`'s comment reserves for `build`.
- **Stay on `resolve`.** Nothing changes: the same call, the same one context. `resolve` is now a builder in front of `resolve_site`, so the guard, the split and the order are still written once.

The same holds for the split's parts (`resolve_nil_count`, whose body is unchanged) and the alias target, which dispatches a different selector with no call node or scope.

## Decision

All three stay on `MethodDispatcher.resolve`. The composite tier carries a comment saying why, so that a later reader does not make the switch as a tidy-up. The precedent is the amendment's sentence for the slice ("`resolve` builds the context and delegates to `resolve_site`"), which keeps `resolve` as an entry, and the brief's condition, which the measured Hash decides.

## To undo

Give `CallContext` a copy that allocates only the context (a positional `with_receiver`, say), check that the tier's `self` rule survives a carried `self_type_override`, and switch `CompositeReceiver.try_dispatch`. `spec/rigor/inference/method_dispatcher/composite_receiver_spec.rb` stubs `MethodDispatcher.resolve` and reads the keywords of each re-entry, so its group "CompositeReceiver.try_dispatch" changes with the call; `project_patched_spec.rb` does the same for the alias target, and `dispatch_site_spec.rb` for the split's parts.
