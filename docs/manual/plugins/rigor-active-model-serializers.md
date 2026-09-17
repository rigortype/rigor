# rigor-active-model-serializers

Teaches Rigor what `object` is inside an ActiveModel::Serializer
subclass, so the reads below it — `object.username`,
`object.account.display_name` — resolve against your model instead of
dispatching on an unknown receiver. It reads source only; no
ActiveModelSerializers runtime dependency.

It ships bundled in `rigortype`. Activate it under `plugins:`, alongside
`rigor-activerecord`, which is what tells this plugin which models exist
and what they answer:

```yaml
plugins:
  - rigor-activerecord
  - rigor-active-model-serializers
```

## What it does — no diagnostics

The plugin emits nothing of its own. It contributes one return type and
the gem's framework constants, so that

```ruby
class REST::AccountSerializer < ActiveModel::Serializer
  attributes :id, :username, :display_name

  def display_name
    object.display_name
  end
end
```

types `object` as `Account`, and `object.display_name` as the
`accounts.display_name` column's type. What you notice is the diagnostics
that now CAN fire — a typo below a serializer's `object` used to be
invisible:

```text
app/serializers/errors_serializer.rb:11:23: error: undefined method `nickname' for String [call.undefined-method]
```

and `rigor coverage` reporting a larger share of `app/serializers` as
precise. On Mastodon that share went from 51.1 % to 53.2 % with no change
at all to the diagnostic set
([the measurement](../../notes/20260917-ams-object-recognizer.md)).

## When `object` is typed, and when it is not

Nothing in a serializer's source states which class it serializes — AMS
binds the resource when the serializer is constructed. So the type is
always DERIVED, and two independent things have to agree before the
plugin contributes one:

1. **The name resolves.** `<Model>Serializer` names exactly one model
   your project has — `REST::AccountSerializer` → `Account`.
2. **The model answers the serializer.** Every name the serializer will
   read off its resource — the `attributes` / `attribute` / `has_many` /
   `has_one` / `belongs_to` declarations it does not define itself, plus
   every `object.<name>` in its body — is a column, per-column predicate,
   association, enum, alias or scope of that model, or a method your
   project defines on it or an ancestor.

One unanswered name declines the whole serializer, because the resource
is then something else — commonly a presenter or a decorator around the
model, which shares most of its surface and is given away by the one or
two names that differ. On Mastodon that check is what stops
`REST::ConversationSerializer` typing as `Conversation` when its resource
is an `AccountConversation`.

| your code | `object` types as |
| --- | --- |
| `REST::AccountSerializer`, `Account` exists and answers it | `Account` |
| `Admin::AccountSerializer`, where `Admin::Account` and `Account` both exist | unchanged — the reading is ambiguous and nothing here ranks one above the other |
| `ConversationSerializer` whose declarations `Conversation` cannot answer | unchanged (`Dynamic`) |
| a serializer that reads nothing off its resource | unchanged — there is nothing to check the name against |
| `ContextSerializer`, and no `Context` **model** exists | unchanged (`Dynamic`) |
| a serializer you listed in `model_overrides` | the model you named |
| `object` written outside a serializer, or over your own `def object` | unchanged (`Dynamic`) |

A serializer is a class under `serializer_search_paths` whose superclass
chain reaches `ActiveModel::Serializer` — including through your own base
serializer (`class ApplicationSerializer < ActiveModel::Serializer`, then
`class AccountSerializer < ApplicationSerializer`). A class the chain does
not reach is not a serializer here whatever it is called: `object` is an
ordinary method name, and a `Json::ConversationSerializer` of your own is
entitled to define it.

`class << self` and `def self.` bodies are left alone. An `object` read
there is a `NoMethodError` at run time — AMS's reader is an instance
method — so there is nothing to type and nothing the plugin should say
about it.

**The plugin never guesses.** Where the resource cannot be established it
contributes nothing and `object` keeps the answer it had, because a wrong
class here would turn every read on it into a false
`call.undefined-method` on working code.

It also does nothing at all without `rigor-activerecord`, or on a project
with no `db/schema.rb` / `db/structure.sql`: the model set it resolves and
checks against comes from that plugin, and is withheld when the schema is
missing.

## Configuration

```yaml
plugins:
  - gem: rigor-active-model-serializers
    config:
      serializer_search_paths: ["app/serializers", "app/lib"]
      serializer_base_classes: ["ActiveModel::Serializer"]
      model_overrides:
        REST::InstanceSerializer: InstancePresenter
```

| Key | Default | Meaning |
| --- | --- | --- |
| `serializer_search_paths` | `["app/serializers", "app/lib"]` | Where to look for serializer classes. `app/lib` is in the default set because a base serializer routinely lives outside `app/serializers` — Mastodon's `ActivityPub::Serializer`, the parent of 60 of its serializers, is one. A directory you do not have costs one probe. |
| `serializer_base_classes` | `["ActiveModel::Serializer"]` | The roots the ancestry walk starts from. |
| `model_overrides` | `{}` | Serializer class name → resource class name, for a serializer the derivation cannot reach — a presenter, a decorator, or a class named for a JSON shape. Your assertion; it is not re-checked. |

## Limitations

- **SimpleForm inputs.** `SimpleForm::Inputs::Base#object` shares the name
  and nothing else — its resource comes from the `simple_form_for` call
  site, not from the input class.
- **`serializer:` / `each_serializer:` options.** They name the
  serializer for an association, never the model for a serializer.
- **Model surface your schema and source do not state.** A `delegate`, an
  association declared inside a concern's `included do`, and an
  attachment macro are all things the model answers that the model index
  does not yet see, so a serializer that reads one of them is declined.
  On Mastodon that is 15 of the 52 serializers whose name resolves,
  including its two largest; the fold belongs in `rigor-activerecord` and
  is tracked as
  [#1049](https://github.com/rigortype/rigor/issues/1049).
- **Some ways of reading the resource.** `object[:key]`, `object.title =`,
  `object.try(:name)`, `object.present?` and an `attribute(:x) { ... }`
  block are not read as evidence, so a serializer using one may decline
  even where the model is right. Always the safe direction — a decline,
  never a wrong type.
- **Serializers for plain objects** — `ActiveModelSerializers::Model`
  subclasses, Structs, presenters. Use `model_overrides` where the class
  you want is a real constant you are happy to have checked.

## Plugin internals

The serializer discoverer / index, the ancestry closure and the contract
surfaces this plugin exercises are in the
[plugin's README](../../../plugins/rigor-active-model-serializers/README.md).
To write a plugin, see [`examples/`](../../../examples/README.md) and the
[`rigor-plugin-author`](../08-skills.md) skill.
