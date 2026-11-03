# ADR-128 slice 1 types every hook's scope as non-nil and types `services.reflection` / `services.type` as the public modules

- **PR:** [#2714](https://github.com/rigortype/rigor/pull/2714)
- **Issue:** [#2684](https://github.com/rigortype/rigor/issues/2684)
- **Class:** open-choice
- **Precedent:** [ADR-128](../docs/adr/128-plugin-hook-surface-interfaces.md)
- **Decided:** 2026-11-04

## Background

Slice 1 types `sig/rigor/plugin/base.rbs`. The issue leaves each hook position's `scope` nilability to the implementer ("non-nil only where every engine call site provably passes a `Scope`"), and ADR-128 WD2 says `_Services` narrows `reflection` and `type` "to the members plugins call".

## Options and trade-offs

- **`_Scope` beyond WD1's list.** The boundary gate found `examples/rigor-web` calling `Scope#with_local`. Allow-listing it or migrating the example would have kept `_Scope` at five members, but `examples/` is the walkthrough authors copy, and rebinding a parameter before `type_of` is a legitimate need.

- **Scope nilability.** `_Scope?` everywhere is the cautious reading, but it would make every plugin that calls `scope.type_of(...)` unguarded draw `call.possible-nil-receiver` once slice 3 makes the types live. Non-nil is sound where the engine never passes nil.
- **`reflection` and `type`.** Narrow `_Reflection` and `_TypeFactory` interfaces follow WD2 literally. But both are already public namespaces (`Rigor::Reflection`, `Rigor::Type::Combinator`) that plugins also reach by constant, so the gate cannot tell a `services.reflection.x` call from a `Rigor::Reflection.x` one, and a narrow interface would promise less than the namespace already does.

## Decision

`_Scope` gains `with_local` beyond WD1's list, found by the gate in `examples/rigor-web`; precedent ADR-128 WD1's criterion (a member a bundled plugin uses).

Every hook's `scope` is non-nil. The per-file hooks receive the seeded `Scope.empty(...)`, `MethodDispatcher#try_plugin_contribution` returns before consulting a plugin when its scope is nil, and `StatementEvaluator#apply_plugin_assertions` has already read its own. `_Services#reflection` and `#type` are typed `singleton(Rigor::Reflection)` and `singleton(Rigor::Type::Combinator)`, so the gate does not watch them.

## To undo

Making a position nilable is one `?` in `base.rbs` and the matching line in the doc, and narrows nothing at runtime. Narrowing `reflection` or `type` later adds an interface and a gate row; it is a promise narrowed (ADR-128 WD6), so it needs a `changed` fragment.
