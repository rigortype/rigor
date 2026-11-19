# The synthetic-method tier's module is `SyntheticMethodDispatch`, not `SyntheticMethod`

- **PR:** [#3364](https://github.com/rigortype/rigor/pull/3364)
- **Issue:** [#3345](https://github.com/rigortype/rigor/issues/3345)
- **Class:** open-choice
- **Precedent:** [ADR-116](../docs/adr/116-hot-file-restructuring.md)
- **Decided:** 2026-11-19

## Background

ADR-116 § "Amendment, 2026-11-19 — WD12's interface (#3345)" lists the dispatcher's tiers by what they are ("plugin contribution, HKT builtin return, static refinement, synthetic method, …") and does not name their modules. #3363 named each module for its tier in CamelCase (`MetaIntrospection`, `HktBuiltinReturn`, `StaticRefinement`, `SynthesizedStub`). The same rule gives the synthetic-method tier the name `SyntheticMethod`, and `Rigor::Inference::SyntheticMethod` is already a class: the record the `SyntheticMethodIndex` holds and the tier reads.

## Options and trade-offs

- **`SyntheticMethod`.** One naming rule for all eleven modules. Inside `Rigor::Inference::MethodDispatcher` the constant would then resolve to the module, in Ruby and in `sig/`: a tier that wrote `SyntheticMethod.new(…)`, or an RBS declaration nested there that named the record as a parameter type, would get the module with no error at the place it was written. No code does either today. The moved code's comments do say "the SyntheticMethod is not a Tier B entry", meaning the record.
- **`SyntheticMethodDispatch`.** No shadowing. It follows `SingletonMixinDispatch` and `UniversalObjectDispatch`, the two tier modules asked beside it in `resolve`, and `RbsDispatch`, `ShapeDispatch` and `KernelDispatch`. The four modules of this batch then do not share one rule: `PluginContribution`, `ProjectPatched` and `DependencySource` are named for their tier alone.
- **`SyntheticMethodTier`.** No shadowing, and no existing tier module has that suffix.

## Decision

`SyntheticMethodDispatch`, in `lib/rigor/inference/method_dispatcher/synthetic_method_dispatch.rb`. A constant that quietly resolves to the wrong thing costs more than a name that is one word longer than its neighbours'. The other three modules keep the plain form because nothing they could shadow exists (`ProjectPatchedMethods`, `DependencySourceInference` and `FlowContribution` are other names).

The precedent is the amendment, which leaves the names open, and the existing `…Dispatch` tier modules. It fits loosely: no earlier decision says how to name a tier whose plain name is taken.

## To undo

Rename the module and its file, its spec (`spec/rigor/inference/method_dispatcher/synthetic_method_dispatch_spec.rb`), its row in `sig/rigor/inference.rbs`, its path in `spec/rigor/typing_state_closure_spec.rb`, the `SYNTHETIC_TIERS` member and the `require_relative` in `method_dispatcher.rb`, the three callers of its second entries (`MethodDispatcher.plugin_member_answers?`, `ProjectPatched.try_dispatch`, `ProjectPatched`'s `require_relative`), and the mentions in `lib/rigor/plugin/macro/heredoc_template.rb` and `plugins/rigor-devise/README.md`. Nothing outside the repository names it.
