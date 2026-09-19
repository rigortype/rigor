# rigor-grape

Recognises the [Grape](https://github.com/ruby-grape/grape)
endpoint-declaration DSL on `Grape::API` subclasses — `params`,
`requires`/`optional`, `namespace`/`resource`, the HTTP verb macros,
`desc`, `route_setting`, `helpers`, `mount`, `use` — and the
[grape-entity](https://github.com/ruby-grape/grape-entity) exposure DSL
on `Grape::Entity` subclasses (`expose`, `documentation`,
`format_with`, …). Without it, every one of those calls reads
`Dynamic[top]` — GitLab's `lib/api` alone accounted for ~10k opaque
implicit-self sends in the 2026-09-19 corpus survey (issue #1099).

> **Using this plugin?** The user guide lives in the manual at
> [docs/manual/plugins/rigor-grape.md](../../docs/manual/plugins/rigor-grape.md).
> This README covers the plugin's internals.

## Why Grape needs all three substrate pieces

Grape is more dynamic than the frameworks the substrate was built for:

1. **No static class methods.** `Grape::API` subclasses forward every
   declaration call to the base `Grape::API::Instance` class object at
   runtime (`delegate_missing_to` + `override_all_methods!`,
   `lib/grape/api.rb`). The bundled `sig/grape.rbs` declares the shared
   surface once in `Grape::DSL::ClassMethods` and `extend`s it onto both
   `Grape::API` and `Grape::API::Instance`; `rbs_complete_ancestors:`
   (ADR-43 WD4) bridges source subclasses to it.
2. **Per-macro `instance_eval` `self`.** `params do` bodies run on a
   `Grape::Validations::ParamsScope` instance, `namespace`/`version`/
   `route_param`/`given`/`mounted` bodies on the Instance *class object*,
   and verb bodies as `Grape::Endpoint` instance methods. The manifest's
   `block_as_methods:` entries carry the named `self_type` form —
   `"Grape::Validations::ParamsScope"` binds `Nominal[...]`,
   `"singleton(Grape::API::Instance)"` binds the class object — so each
   body resolves against the receiver Grape actually evaluates it on.
   Nested `requires ... do` bodies re-enter a child scope through the
   same mechanism on a `Nominal[ParamsScope]` receiver.
3. **Open receivers.** All five declared classes keep genuinely open
   runtime surfaces (generated methods, delegators, DSL module mixes), so
   they sit in `open_receivers:` and undeclared calls stay opaque rather
   than diagnosed.

`Grape::Entity#self.expose` bodies run via `block.call` — `self` stays
the Entity class object — so nested `expose` calls resolve through the
same `def self.` declarations with no block entry at all.

## Return carriers

Signatures follow the runtime returns (grape 2.4.0, grape-entity 1.0):
`params` → `Grape::Validations::ParamsScope`, `expose` → `Array`, and
`::Object?` for the setup-style declarations whose value is the stored
setting or bookkeeping collection. `void` would be dishonest *and* is
collapsed to `Dynamic[top]` by the engine's void-value recovery.

## Deferred (demand-driven)

- `helpers do ... end` bodies (`class_eval` on an anonymous module — no
  nameable self).
- `desc ... do ... end` nested documentation blocks (the `DescContainer`
  surface).
- `use :name`-style named parameter scopes and `contract` schema blocks.
- Typing `present`/`declared` results against the declared entity or
  params (runtime-shape work).
- `Grape::Middleware` / custom middleware DSL.

## Demo

`demo/` runs `rigor check` against a self-contained API + Entity
fixture — no local sig stub needed, since the plugin ships its own.

```sh
cd demo && RUBYLIB=$PWD/../lib bundle exec rigor check
```
