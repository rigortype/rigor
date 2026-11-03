# The plugin declaration-walk facade is `Reflection.class_declarations_in`, returning class values and yielding `DeclaredCall` values with a lexical owner

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
- **Method name.** `class_declarations_in`, so modules can arrive later as their own method rather than as extra entries in this array (a caller that reads `ClassDeclaration` as a class would otherwise meet modules). Call-site context a plugin may later want (body, `def`, `class << self`) would arrive as a new `DeclaredCall` field or a new method, not as a change to what is yielded today.
- **Block argument.** One `DeclaredCall` (`node`, `owner`) rather than positional `(call, owner)`, so a field added later does not break an arity-2 lambda. The field is `node`, not `call`, since a `Data` member named `call` would make the value look callable.
- **One method or two.** Two methods (classes, calls) would walk alba's files twice. One method with an optional block walks once, and a classes-only caller (typelizer) pays for no call event because the block selects a collector class that does not override `on_call`.
- **Owner.** The walk's `Context#prefix` is lexical (a `Class.new` block or `class << self` keeps the class around it), where alba's own rules handle anonymous-class blocks. The facade passes it through as `String?`, `nil` where empty, rather than reinterpreting it.
- **`singleton_cref`.** Typelizer read it, but a declaration body has it only with an empty prefix, so its guard was dead and is not exposed.

## Decision

`Rigor::Reflection.class_declarations_in(root) { |declared_call| ... } -> Array[ClassDeclaration]`, with `ClassDeclaration = Data.define(:name, :nesting, :node)` (`nesting` frozen) and `DeclaredCall = Data.define(:node, :owner)`, classes only (no modules). The block sees the calls the declaration walk visits, which excludes a class header's own expressions, a constant write's factory call and its tail; the exclusions are pinned in the spec. It follows #2688's criterion: a plugin need met by a facade on a public namespace rather than by promoting an engine module.

## To undo

Moving it to another namespace is a rename plus the drift pin and `public-api.md`. Modules would come as a new method (for example `module_declarations_in`), and call-site context or `singleton_cref` as a new `DeclaredCall` or `ClassDeclaration` field or a new method; narrowing the shape needs a `changed` fragment (ADR-128 WD6). The two plugins' `*_collector.rb` files are the only callers.
