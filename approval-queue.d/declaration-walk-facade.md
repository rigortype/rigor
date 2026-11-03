# The plugin declaration-walk facade is `Reflection.declarations_in`, returning class values and yielding calls with a lexical owner

- **PR:** [#2763](https://github.com/rigortype/rigor/pull/2763)
- **Issue:** [#2708](https://github.com/rigortype/rigor/issues/2708)
- **Class:** open-choice
- **Precedent:** [#2688](https://github.com/rigortype/rigor/pull/2688)
- **Decided:** 2026-11-04

## Background

`rigor-alba` and `rigor-typelizer` included `Rigor::Inference::DeclarationWalk::Collector` and read its `Context`. ADR-128's criterion makes a method public plugin API only when `Plugin::Base`, an interface or a listed public namespace declares it, so the plugin-boundary gate carried two allow-list rows for the reach. The issue left the facade's home and shape to the implementer.

## Options and trade-offs

- **Home.** `Plugin::Base` is the hook-registration surface the engine calls; a per-file read a plugin makes at its own time does not fit it. `Rigor::Reflection` is already the public read-side facade and already holds `project_method_defined` (#2688).
- **Shape.** Re-exposing `Collector` and `Context` behind a wrapper would make the walk's control constants, variant rules and context transitions public promises. A value object plus a block keeps what the two collectors read (name, nesting, `ClassNode`, a call's owner) and nothing else.
- **One method or two.** Two methods (classes, calls) would walk alba's files twice. One method with an optional block walks once, and a classes-only caller (typelizer) pays for no call event because the block selects a collector class that does not override `on_call`.
- **Owner.** The walk's `Context#prefix` is lexical (a `Class.new` block or `class << self` keeps the class around it), where alba's own rules handle anonymous-class blocks. The facade passes it through as `String?`, `nil` where empty, rather than reinterpreting it.
- **`singleton_cref`.** Typelizer read it, but a declaration body has it only with an empty prefix, so its guard was dead and is not exposed.

## Decision

`Rigor::Reflection.declarations_in(root) { |call, owner| ... } -> Array[ClassDeclaration]`, with `ClassDeclaration = Data.define(:name, :nesting, :node)`, classes only (no modules). It follows #2688's criterion: a plugin need met by a facade on a public namespace rather than by promoting an engine module.

## To undo

Moving it to another namespace is a rename plus the drift pin and `public-api.md`. Adding module declarations or `singleton_cref` later extends `ClassDeclaration` or adds a sibling value; narrowing the shape needs a `changed` fragment (ADR-128 WD6). The two plugins' `*_collector.rb` files are the only callers.
