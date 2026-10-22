# A mixed-in project module that extends an unreadable DSL, or hands a macro the name, may define it

- **PR:** [#2269](https://github.com/rigortype/rigor/pull/2269)
- **Issue:** [#2094](https://github.com/rigortype/rigor/issues/2094)
- **Class:** open-choice
- **Precedent:** [#2086](https://github.com/rigortype/rigor/pull/2086)
- **Decided:** 2026-10-21

## Background

`module OnlyExt; extend SomeGem::Dsl; dsl_method :xdyn; end; String.include(OnlyExt)` made `"s".xdyn` report `call.undefined-method`, although the gem's macro defines the method. Two things were left open: what makes a macro "unknown", and whether the decline covers only the named method or any name.

## Options and trade-offs

- Decline any name only when the module body calls a receiverless macro that resolves nowhere. This is the narrowest reading, but the indexer records no class-body calls by name, so it would need a new discovery table, with its cache and incremental plumbing.
- Read the evidence the indexer already keeps. Each literal name a non-visibility class-body macro is handed is filed as an opaque envelope, so such a module answers that name. A module that `extend`s a module neither RBS nor the project declares, or a hook-capable project module, answers any name: any macro its body calls may come from that module, and so may the module's `extended` hook. This needs no new table.
- Decline on any project module mixed into a core class. That is the broadest option, and it loses every typo report on such receivers.

## Decision

Take the second option. It reuses the readings #2086 settled: an undeclared `include` and a hook-capable module already answer any name, and an `extend` of the same kind now does too. The any-name half stays off on `Object`, `Kernel` and `BasicObject`, as #1697 and #2086 keep it there. The macro-named half also holds on those three roots (`Inference::ObjectMixins`), because a module that may define the very name answers there as well. The same reading covers the class-object side. `Float.extend(M)` written anywhere, and `Float.singleton_class.include(M)` (or `prepend`), are now recorded on `Float`'s extend side and marked unpositioned, as #1722 records `Integer.include(M)`, instead of tainting it. A call on `Float` then asks those modules as an instance-side call asks an included one. This adds two `spec/rigor/declaration_facts/producers.yml` rows (`receiver_extend_recorded?`, `singleton_class_include_recorded?`), which follow the `instance_mixin_recorded?` row that [#1584](https://github.com/rigortype/rigor/pull/1584) added. Because the extend is recorded, `Float.m` is also typed through `M#m`. Some singleton-side mixin calls still cannot be recorded: a non-constant argument (`Integer.extend(m)`), a `send` spelling, or `singleton_class.include` inside `class << self` (Ruby puts that module one level up). These taint the extend side, and a tainted side is read as open on every class but `Object`, `Kernel` and `BasicObject`, so the call declines. One case stays reported: an extend through a local holding the class (`k = Time; k.extend(M)`). Its receiver names no class, so nothing is tainted.

Accepted costs:

- A macro's literal argument that is not a method (`validates :name`) silences that name on the receiver. So does the literal argument of a project-defined no-op macro, or of a misspelled macro (`atr_accessor :x`). The opaque envelope the indexer files does not say which macro wrote it, so this cannot be narrowed to unresolved macros without a new discovery table.
- `extend` of a constant neither RBS nor the project declares opens every name on the receiver, even when the constant is a typo (`extend Typoo`). Ruby raises `NameError` at load, and Rigor reports no unresolved constant for it.
- A no-argument macro from an RBS-unknown `Module` monkey-patch, on a module that extends nothing unknown, is still not seen.

## To undo

Remove `open_extend?`, `macro_names?`, `singleton_mixin_may_answer?` and `extends_answer?` from `CheckRules::RbsReceiverSurface`, and `macro_named?` from `Inference::ObjectMixins`. To stop recording the receiver forms, remove `receiver_extend_recorded?` and `singleton_class_include_recorded?` from `ScopeIndexer` together with their `producers.yml` rows; the calls then taint the extend side again.
