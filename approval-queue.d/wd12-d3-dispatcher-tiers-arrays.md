# Every tier `resolve` follows with no record is a row of a tier array, and the array of the stub and universal tiers is `STUB_AND_UNIVERSAL_TIERS`

- **PR:** [#3365](https://github.com/rigortype/rigor/pull/3365)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-20

## Background

ADR-116 § "Amendment, 2026-11-19 — WD12's interface (#3345)" says where `MethodDispatcher.resolve` asks a tier module: "One with no bookkeeping after its answer joins an array at its own position (a new one where straight-line calls with bookkeeping surround it)", and one whose answer `resolve` follows with a record stays a straight-line call. #3363 and #3364 applied that to the tiers they moved and left two older modules as they were: `SingletonMixinDispatch`, asked by a call between `BUNDLED_OVERRIDE_TIERS` and `RbsDispatch`, and `UniversalObjectDispatch`, asked by a call between `STUB_TIERS` and the user-class fallback. Neither is followed by a record. #3363 left them because an array then cost one object for every answer; #3364's `while` walk removed that cost and called the rest a matter of taste.

#3365 is the last dispatcher slice. Its brief asked for the two to be folded into the arrays beside them if they have no bookkeeping and the order is preserved, and for the composite-receiver tier to move if the move rule allows. Three calls came out of that which the brief did not make.

## Options and trade-offs

**The two straight-line tiers.**

- *Fold them.* `BUNDLED_OVERRIDE_TIERS` becomes `[HktBuiltinReturn, StaticRefinement, SingletonMixinDispatch]` and the stub array `[SynthesizedStub, UniversalObjectDispatch]`. Each joins the array it stood directly behind, so no tier is asked earlier or later than before. `resolve` loses the last two `try_dispatch` calls it followed with no record. Rigor's self-check typed each straight-line call, its result and its `return … if` line, and a row is one constant in an array, so the self-typing ratchet loses 14 precise expressions and 2 call sites of `method_dispatcher.rb` (precision −0.000014, Dynamic call share +0.000010, measured), with no Dynamic call site added.
- *Leave them.* The ratchet keeps the two call sites, and `resolve` keeps two exceptions to "a tier with no record is a row".

**The composite-receiver tier.** Nothing in `resolve` follows it, but it is not a tier with no bookkeeping: it buffers the plugin-typed records of the members it re-dispatches and commits them to the scope itself when every member answers.

- *An array of one, `COMPOSITE_TIERS`.* The amendment's rule read literally, as #3364 read it for `SYNTHETIC_TIERS`: what decides is whether `resolve` does anything after the answer, and it does not.
- *A straight-line call, last in `resolve`.* It marks the tier as one that writes to the scope. The write is inside the tier either way, so the call form would say something about `resolve` that is not true of it.

**The name of the second array.** `STUB_TIERS` named its one member. With `UniversalObjectDispatch` in it the name describes half of it.

- *Keep `STUB_TIERS`.* No rename, and a name that misleads the next reader of `resolve`.
- *`STUB_AND_UNIVERSAL_TIERS`.* Names both members, and has to change again if a third joins.
- *A name for what the two share* (`FLOOR_TIERS`, `UNNAMED_RECEIVER_TIERS`). Both answer for a receiver with no signature of its own to read. Every candidate also describes the user-class fallback just below them, or is false of one member (a synthesized stub has a name).

`BUNDLED_OVERRIDE_TIERS` keeps its name with a third member. The singleton-mixin tier overrides nothing, since the upstream RBS declares no `instance` for it to override, but it is the same kind of thing as the other two: what Rigor bundles about a stdlib method, asked ahead of the RBS answer. The comment over the array says so.

## Decision

Both tiers are folded, the composite-receiver tier is asked through `COMPOSITE_TIERS`, and `STUB_TIERS` becomes `STUB_AND_UNIVERSAL_TIERS`. After this `resolve` itself holds no `try_dispatch` call except the ones it follows with a record, which is the amendment's rule, and the reason #3363 gave for the two exceptions is gone. Two things near it are left as they are: `MethodFolding.try_backward`, asked ahead of every tier, is that module's second entry and not a row, and the precise band (`dispatch_precise_tiers`) still asks `DataFolding` and `StructFolding` by calls, which the brief did not name.

The precedent is the amendment's sentence quoted above. It fits the fold and the array of one closely. It says nothing about what an array is called, and the two existing names (`BUNDLED_OVERRIDE_TIERS`, `SYNTHETIC_TIERS`) each name what their members are, which is the pattern the new name follows.

## To undo

To unfold a tier, drop it from its array in `lib/rigor/inference/method_dispatcher.rb` and put `result = Module.try_dispatch(context)` and `return result if result` back at the position its comment in `resolve` holds. The example that holds each in its array is the last one of `singleton_mixin_dispatch_spec.rb` and of `universal_object_dispatch_spec.rb`; both pass either way.

The array's name appears in `method_dispatcher.rb` (the constant, its `private_constant` and the walk in `resolve`), in the header comments of `synthesized_stub.rb` and `universal_object_dispatch.rb`, and in comments of `synthesized_stub_spec.rb`, `universal_object_dispatch_spec.rb` and `tier_walk_spec.rb`. Nothing outside the repository can name a private constant.
