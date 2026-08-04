# rigor-dry-validation

[ADR-12](../../docs/adr/12-dry-rb-packaging.md) Tier A plugin per
the slicing plan in
[`docs/design/20260517-dry-validation-slicing.md`](../../docs/design/20260517-dry-validation-slicing.md).

Recognises `class T < Dry::Validation::Contract` subclasses and
publishes the resulting set of contract class FQNs as the
`:dry_validation_contracts` [ADR-9](../../docs/adr/9-cross-plugin-api.md)
cross-plugin fact. Ships an RBS overlay typing
`Contract#call` / `Result#success?` / `Result#failure?` /
`Result#to_h` / `Result#errors` / `Result#[]`.

With `rigor-dry-schema` also loaded, a Contract's `params { ... }` /
`json { ... }` block — the SAME dry-schema DSL a top-level
`Dry::Schema.X { ... }` body uses — refines `result.to_h` from the
RBS overlay's generic `Hash[Symbol, untyped]` to the schema-typed
`HashShape`, and a `rule(:key)` referencing a key absent from that
schema draws `dry-validation.rule-key-mismatch`. See §§ "params /
json integration" and "Diagnostics" below.

> **Using this plugin?** The user guide lives in the manual at
> [docs/manual/plugins/rigor-dry-validation.md](../../docs/manual/plugins/rigor-dry-validation.md).
> This README covers the plugin's internals.
>
> **RBS overlay auto-loads.** The manifest declares
> `signature_paths: ["sig"]` ([ADR-25](../../docs/adr/25-plugin-contributed-rbs.md)),
> so the bundled overlay is contributed automatically when the plugin
> is active — no project-side `signature_paths:` wiring needed.

## What the plugin does

For source like

```ruby
class NewUserContract < Dry::Validation::Contract
  params do
    required(:email).filled(:string)
    required(:age).value(:integer)
  end

  rule(:email) do
    key.failure('has invalid format') unless EMAIL_RE.match?(value)
  end
end

class EmailContract < Validation::Contract  # lexical-Dry path
  params { required(:email).filled(:string) }
end
```

the plugin's `prepare(services)` hook walks every `paths:` entry
for Contract subclasses and publishes a sorted, frozen FQN list:

```ruby
[
  "EmailContract",
  "NewUserContract"
]
```

via the `:dry_validation_contracts` fact.

## RBS overlay

A small RBS file ships under
[`sig/dry_validation.rbs`](sig/dry_validation.rbs). The manifest
declares `signature_paths: ["sig"]`, so it is contributed
automatically (ADR-25) whenever the plugin is active — just list
the plugin:

```yaml
plugins:
  - rigor-dry-validation
```

With the overlay loaded:

```ruby
result = NewUserContract.new.call(input)  # Dry::Validation::Result
result.success?                            # bool
result.to_h                                # Hash[Symbol, untyped] — refined below, with rigor-dry-schema
result.errors                              # untyped (still — no ceiling slice targets this)
```

## `params` / `json` integration (slices 2/3)

With `rigor-dry-schema` also loaded, `prepare(services)` walks
every recognised Contract's class body for a TOP-LEVEL, bare
`params do ... end` and/or `json do ... end` call — a direct
class-body statement, no receiver, no positional/keyword
arguments, exactly one block. The block is the SAME dry-schema
DSL a top-level `Dry::Schema.X { ... }` body uses (`required` /
`optional` / `filled` / `value` / `maybe` / `each`), so this
plugin delegates the actual walk to
`Rigor::Plugin::DrySchema::SchemaScanner.collect_schema_shape`
rather than duplicating it — the
[slicing plan](../../docs/design/20260517-dry-validation-slicing.md)'s
own "delegate to rigor-dry-schema's walker" option.

```ruby
class NewUserContract < Dry::Validation::Contract
  params do
    required(:email).filled(:string)
    required(:age).value(:integer)
  end
end
```

publishes the `:dry_validation_params` fact:

```ruby
{
  "NewUserContract" => {
    params: {
      required: { email: { type: "String", list: false },
                  age:   { type: "Integer", list: false } },
      optional: {},
      unmodelled: { required: [], optional: [] }
    }
  }
}
```

and refines `NewUserContract.new.call(input).to_h` from the RBS
overlay's generic `Hash[Symbol, untyped]` to
`{ email: String, age: Integer, ... }` — the identical
required/optional-preserving, open-shape HashShape build
rigor-dry-schema's own `ResultShape.build` uses (delegated to,
not duplicated). `json { ... }` works identically under a
`json:` key; a Contract with BOTH blocks (unusual) prefers
`params` for the `to_h` refinement.

The chain recognised is `<Const>.new.call(...).to_h` — the
Contract must be named by a constant as written at the call
site, matching rigor-dry-schema's own floor for `SomeSchema.call(x).to_h`.
Reached through a local, the chain contributes nothing and
`to_h` types per the RBS overlay as before.

A `params { ... }` / `json { ... }` call that ISN'T a bare,
top-level class-body statement — wrapped in a conditional, built
via a method call, given positional arguments — is not
recognised; the Contract simply has no entry in
`:dry_validation_params` and `to_h` keeps the generic overlay
shape. Without `rigor-dry-schema` loaded at all, this whole
section is inert: the plugin ships no required/optional walker
of its own.

## Diagnostics

`dry-validation.rule-key-mismatch` (`:error`) fires when a
`rule(:key, ...) do ... end` call references a key the Contract's
own `params`/`json` schema never declares:

```ruby
class NewUserContract < Dry::Validation::Contract
  params do
    required(:email).filled(:string)
  end

  rule(:handle) do   # :handle isn't a params key — typo for :email?
    key.failure("nope")
  end
end
# → error: rule(:handle) references a key not declared by
#   `NewUserContract`'s params/json schema (did you mean `:email`?)
#   [dry-validation.rule-key-mismatch]
```

It requires TWO independent all-or-nothing checks to pass before
it fires at all, either of which silently declines the WHOLE
Contract (not just the ambiguous part) rather than risk a false
positive:

1. **The Contract's key universe must be cleanly resolved.** Every
   top-level statement in every `params`/`json` block must be a
   recognised `required`/`optional` row (typed or not — an
   unmodelled row is still a DECLARED key) or the inert
   `config.<x> = <literal>` idiom. A loop building keys
   dynamically, a splat, an `include`, or anything else the scanner
   doesn't recognise makes the Contract's ENTIRE key set
   untrustworthy, and no `rule()` call in it is checked.
2. **The `rule(...)` call's own arguments must all be literal
   Symbols.** A splat (`rule(*keys)`), a String, a local variable,
   or the nested-key Hash form (`rule(user: [:name])`) makes that
   WHOLE call unresolvable, and it is skipped rather than partially
   validated.

Without `rigor-dry-schema` loaded, this diagnostic never fires —
there is no key universe to check a `rule()` call against.

## Floor / ceiling

Slice 1 shipped the **floor**:

- Contract subclass recognition (full-path
  `Dry::Validation::Contract` AND lexical-Dry path
  `Validation::Contract`).
- Fact publication: `:dry_validation_contracts` is the
  sorted, frozen Array<String> of contract FQNs.
- RBS overlay: generic `Contract#call` returns `Result`;
  `Result#to_h` returns `Hash[Symbol, untyped]`.
- No user-facing diagnostics yet.

**Landed since** (issue #137):

- **Slices 2/3** — `params { ... }` / `json { ... }` integration
  with `rigor-dry-schema`, refining `result.to_h` per-Contract.
  See § "`params` / `json` integration" above.
- **`dry-validation.rule-key-mismatch`.** See § "Diagnostics"
  above.

This closes every checkbox issue #137 opened for this plugin; the
ceiling is empty pending fresh demand.

## What the plugin does NOT do

- Recognise `rule { ... }` blocks for anything beyond the
  flat-Symbol-arguments key-existence check above — no nested-key
  form, no cross-rule reasoning, no business-logic evaluation.
- Refine `result.errors` — it stays `untyped` regardless of
  whether `rigor-dry-schema` is loaded.
- Recognise a `params(SomeSchema)` / `json(SomeSchema)` form
  that delegates to an EXTERNALLY-declared schema by reference
  — only the inline block form is recognised.
- Round-trip either fact through the cache descriptor —
  `prepare(services)` re-scans on every run.

## Configuration

```yaml
plugins:
  - rigor-dry-schema       # optional; enables the params/json → to_h refinement
  - rigor-dry-validation
```

No plugin-specific config keys, and no `signature_paths:` wiring —
the manifest's `signature_paths: ["sig"]` auto-contributes the RBS
overlay (ADR-25). The plugin walks every `paths:`
entry's `.rb` files looking for the Contract subclass shape.

## Related

- [ADR-12](../../docs/adr/12-dry-rb-packaging.md) — dry-rb
  plugin packaging decision.
- [ADR-9](../../docs/adr/9-cross-plugin-api.md) — the
  `Plugin::FactStore` cross-plugin fact channel.
- [Slicing plan](../../docs/design/20260517-dry-validation-slicing.md)
  — full design + dependency ordering with rigor-dry-schema +
  rigor-dry-monads.
- [`rigor-dry-types`](../rigor-dry-types/) — Tier A foundation
  publishing `:dry_type_aliases`.
- [`rigor-dry-schema`](../rigor-dry-schema/) — Tier A publishing
  `:dry_schema_table`; slices 2/3 delegate to its
  `SchemaScanner.collect_schema_shape` / `ResultShape.build` for
  the per-Contract `result.to_h` typing above.
- [`rigor-dry-struct`](../rigor-dry-struct/) — the first dry-rb
  consumer plugin (Tier C macro substrate).
