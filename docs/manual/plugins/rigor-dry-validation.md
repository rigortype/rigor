# rigor-dry-validation

Recognises `class T < Dry::Validation::Contract` subclasses,
publishes the set of contract class names as a cross-plugin fact
(`:dry_validation_contracts`), and ships an RBS overlay typing the
contract result API (`Contract#call → Result`, then `Result#success?`
/ `#failure?` / `#to_h` / `#errors` / `#[]`).

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-dry-validation
```

## What it recognises

```ruby
class NewUserContract < Dry::Validation::Contract
  params do
    required(:email).filled(:string)
    required(:age).value(:integer)
  end
end
```

The plugin recognises both the full-path
`Dry::Validation::Contract` and the lexical-`Dry` form
`Validation::Contract`, and publishes a sorted list of the
discovered contract names.

With the RBS overlay loaded (see below):

```ruby
result = NewUserContract.new.call(input)  # Dry::Validation::Result
result.success?                            # bool
result.to_h                                # Hash[Symbol, untyped]
```

## RBS overlay

The plugin bundles an RBS overlay (`sig/dry_validation.rbs`) that
types the result API above, and **contributes it automatically** —
the plugin's manifest declares `signature_paths: ["sig"]`
([ADR-25](https://github.com/rigortype/rigor/blob/master/docs/adr/25-plugin-contributed-rbs.md)), so activating
`rigor-dry-validation` is enough; no project-side `signature_paths:`
wiring is required.

## No diagnostics, no config

The plugin publishes the contract list and the overlay; it emits no
diagnostics and takes no config keys. (Future slices add
`result.to_h` typing from a paired `rigor-dry-schema` `params` block
and per-contract `rule`-key diagnostics.)

## Plugin internals

The `prepare(services)` scan, the `:dry_validation_contracts` fact,
the RBS overlay, and the slice floor/ceiling are documented in the
[plugin's README](https://github.com/rigortype/rigor/blob/master/plugins/rigor-dry-validation/README.md).
To write a plugin, see [`examples/`](https://github.com/rigortype/rigor/blob/master/examples/README.md)
and the [`rigor-plugin-author`](../08-skills.md) skill.
