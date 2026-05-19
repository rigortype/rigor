# rigor-dry-validation — example Rigor plugin

[ADR-12](../../docs/adr/12-dry-rb-packaging.md) Tier A plugin per
the slicing plan in
[`docs/design/20260517-dry-validation-slicing.md`](../../docs/design/20260517-dry-validation-slicing.md).

Recognises `class T < Dry::Validation::Contract` subclasses and
publishes the resulting set of contract class FQNs as the
`:dry_validation_contracts` [ADR-9](../../docs/adr/9-cross-plugin-api.md)
cross-plugin fact. Ships an RBS overlay typing
`Contract#call` / `Result#success?` / `Result#failure?` /
`Result#to_h` / `Result#errors` / `Result#[]`.

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
[`sig/dry_validation.rbs`](sig/dry_validation.rbs). Add it to
your `.rigor.yml`:

```yaml
plugins:
  - rigor-dry-validation

signature_paths:
  - vendor/bundle/ruby/4.0.0/gems/rigor-dry-validation-0.1.0/sig
```

(Adjust the path to wherever Bundler installs the gem; the
sig directory is under the gem root.)

With the overlay loaded:

```ruby
result = NewUserContract.new.call(input)  # Dry::Validation::Result
result.success?                            # bool
result.to_h                                # Hash[Symbol, untyped]
result.errors                              # untyped (refined in slice 2)
```

## Floor / ceiling

Slice 1 ships the **floor**:

- Contract subclass recognition (full-path
  `Dry::Validation::Contract` AND lexical-Dry path
  `Validation::Contract`).
- Fact publication: `:dry_validation_contracts` is the
  sorted, frozen Array<String> of contract FQNs.
- RBS overlay: generic `Contract#call` returns `Result`;
  `Result#to_h` returns `Hash[Symbol, untyped]`.
- No user-facing diagnostics yet.

The **ceiling** (deferred to demand):

- **Slice 2 — params block integration with dry-schema.**
  When `rigor-dry-schema` is loaded and a Contract's
  `params { ... }` block delegates to a schema, refine
  `result.to_h` to the typed `HashShape[{email: String,
  age: Integer}]` per the schema's published fact
  (`:dry_schema_table`). Today's RBS overlay's generic
  `Hash[Symbol, untyped]` becomes the schema-typed shape.
- **Slice 3 — `json { ... }` adapter parity.** Same shape as
  slice 2 but for the `json` block adapter.
- **Per-Contract diagnostics.** E.g. `rule(:nonexistent_key)`
  references a key not in the `params { ... }` schema → emit
  `dry-validation.rule-key-mismatch`.

## What the plugin does NOT do (yet)

- Synthesise typed `result.to_h` shapes per Contract
  (deferred to slice 2; needs dry-schema integration).
- Recognise `rule { ... }` blocks for key validation.
- Emit `dry-validation.*` diagnostics.
- Round-trip the contract list through the cache descriptor —
  `prepare(services)` re-scans on every run.

## Configuration

```yaml
plugins:
  - rigor-dry-validation

signature_paths:
  - <gem-root>/sig    # ship the bundled RBS overlay
```

No plugin-specific config keys. The plugin walks every `paths:`
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
  `:dry_schema_table`; future consumer for slice 2's per-Contract
  `result.to_h` typing.
- [`rigor-dry-struct`](../rigor-dry-struct/) — the first dry-rb
  consumer plugin (Tier C macro substrate).
