# rigor-activestorage

Walks ActiveRecord model files for `has_one_attached` /
`has_many_attached` macros and types the attachment accessors they
generate, so navigating an attachment resolves through
ActiveStorage's own RBS surface instead of falling to the untyped
envelope. It reads source only — no Rails runtime dependency.

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-activestorage
```

## What it infers

```ruby
class User < ApplicationRecord
  has_one_attached :avatar
  has_many_attached :photos
end

user = User.find(1)
user.avatar           # Nominal[ActiveStorage::Attached::One]
user.avatar.attached? # resolves through ActiveStorage's RBS
user.photos           # Nominal[ActiveStorage::Attached::Many]
```

| Macro | Accessor | Contributed type |
| --- | --- | --- |
| `has_one_attached :avatar` | `user.avatar` | `Nominal[ActiveStorage::Attached::One]` |
| `has_many_attached :photos` | `user.photos` | `Nominal[ActiveStorage::Attached::Many]` |

Setters (`user.avatar = …`) and attachment-name calls with
arguments decline — those are covered by ActiveStorage's own RBS.

## Diagnostics

| Rule | Severity | When |
| --- | --- | --- |
| `plugin.activestorage.attachment-call` | info | a recognised `model.attachment_name` call surfaces; confirms the model → attachment mapping |
| `plugin.activestorage.load-error` | warning | discovery failed (e.g. the model directory is inaccessible under the IoBoundary trust policy) |

No `:error` diagnostics in this slice — the value is the
return-type contribution; an "unknown attachment name" rule is a
future slice.

## Configuration

```yaml
plugins:
  - gem: rigor-activestorage
    config:
      model_search_paths: ["app/models"]   # default
```

## With or without rigor-activerecord

The plugin discovers model files independently, so it works
stand-alone. When [`rigor-activerecord`](rigor-activerecord.md) is
also active the two coexist (each contributes its own per-call
return type and the contribution merger reconciles); the
`:model_index` dependency is declared `optional`, reserved for a
future slice that would restrict attachment recognition to
discovered AR classes.

## Plugin internals

The discovery pass, the `AttachmentIndex`, and the contract
surfaces this plugin exercises are in the
[plugin's README](../../../plugins/rigor-activestorage/README.md).
To write a plugin, see [`examples/`](../../../examples/README.md)
and the [`rigor-plugin-author`](../08-skills.md) skill.
