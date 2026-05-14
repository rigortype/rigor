# rigor-activestorage

> Rigor plugin: types ActiveStorage attachment macros on AR models.

`rigor-activestorage` walks ActiveRecord model files for
`has_one_attached :avatar` / `has_many_attached :photos`
macros, records the generated attachment accessor surface,
and contributes return types when downstream code navigates
the attachment.

```ruby
# app/models/user.rb
class User < ApplicationRecord
  has_one_attached :avatar
  has_many_attached :photos
end

# Elsewhere
user = User.find(1)
user.avatar          # => Nominal[ActiveStorage::Attached::One]
user.avatar.attached? # routes through ActiveStorage's RBS surface
user.photos          # => Nominal[ActiveStorage::Attached::Many]
```

## Architecture

One discovery pass per run reads the configured AR model
search paths via the plugin's `IoBoundary`, walks each
`.rb` file with Prism, and collects `has_*_attached`
declarations into an `AttachmentIndex` keyed by class name.
The walker is stand-alone (mirrors `rigor-activerecord`'s
`ModelDiscoverer`) so the plugin works even when
`rigor-activerecord` is not loaded; when it IS loaded, the
two plugins agree on what counts as a model because they
read the same source files.

### Contributed return types

| Macro | Receiver | Method | Contributed type |
|---|---|---|---|
| `has_one_attached :avatar` | `Nominal[User]` | `:avatar` | `Nominal[ActiveStorage::Attached::One]` |
| `has_many_attached :photos` | `Nominal[User]` | `:photos` | `Nominal[ActiveStorage::Attached::Many]` |

Attachment setters (`user.avatar=`) decline — they take
side-effecting argument types that the RBS surface already
covers. Calls with arguments (rare for attachment readers)
also decline.

## Configuration

```yaml
plugins:
  - gem: rigor-activerecord    # producer of :model_index
  - gem: rigor-activestorage
    config:
      model_search_paths: ["app/models"]
```

`model_search_paths` defaults to `["app/models"]`.

## Diagnostic rules

| Rule | Severity | When |
|---|---|---|
| `attachment-call` | `:info` | A `Model.attachment_name` call on a known class surfaces; the message confirms the recognised attachment + kind. |
| `load-error` | `:warning` | Discovery failed (e.g., model directory inaccessible via the `IoBoundary`'s trust policy). |

The plugin intentionally does NOT emit `:error` diagnostics
in this slice — the `flow_contribution_for` return-type
narrowing carries the type-checking value, and a coupled
"unknown attachment name" rule belongs in a follow-up slice
that pairs with `rigor-activerecord`'s `:model_index`
consumer pattern.

## Stand-alone vs. with `rigor-activerecord`

The plugin runs without `rigor-activerecord` — its own
discoverer reads model files independently. When
`rigor-activerecord` IS loaded, the two plugins coexist:
each surfaces its own per-call return-type contribution
and the `FlowContribution::Merger` reconciles. There is
no current dependency on the AR plugin's `:model_index`
publication (the `consumes:` row is `optional: true`); a
future slice could use it to restrict attachment recognition
to discovered AR classes only.

## No Rails runtime

Rigor stays decoupled from Rails. This plugin only reads
project source the same way the other examples do.
