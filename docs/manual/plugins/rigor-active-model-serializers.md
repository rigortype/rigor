# rigor-active-model-serializers

Teaches Rigor what `object` is inside an ActiveModel::Serializer
subclass, so the reads below it — `object.username`,
`object.account.display_name` — resolve against your model instead of
dispatching on an unknown receiver. It reads source only; no
ActiveModelSerializers runtime dependency.

It ships bundled in `rigortype`. Activate it under `plugins:`, alongside
`rigor-activerecord`, which is what tells this plugin which models exist:

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
errors_demo.rb:8:17: error: undefined method `nickname' for String [call.undefined-method]
```

and `rigor coverage` reporting a larger share of `app/serializers` as
precise. On Mastodon that share went from 51.1 % to 58.2 % with no change
at all to the diagnostic set
([the measurement](../../notes/20260917-ams-object-recognizer.md)).

## When `object` is typed, and when it is not

Nothing in a serializer's source states which class it serializes — AMS
binds the resource when the serializer is constructed. So the type is
always DERIVED, and the plugin derives it only where something outside
the serializer agrees:

| your code | `object` types as |
| --- | --- |
| `REST::AccountSerializer`, and an `Account` model exists | `Account` |
| `AccountSerializer` under `Admin::`, and an `Admin::Account` model exists | `Admin::Account` |
| `ContextSerializer`, and no `Context` **model** exists | unchanged (`Dynamic`) |
| a serializer you listed in `model_overrides` | the model you named |
| `object` written outside a serializer | unchanged (`Dynamic`) |

A serializer is a class under `serializer_search_paths` whose superclass
chain reaches `ActiveModel::Serializer` — including through your own base
serializer (`class ApplicationSerializer < ActiveModel::Serializer`, then
`class AccountSerializer < ApplicationSerializer`). A class named
`*Serializer` outside those paths is admitted too.

**The plugin never guesses.** Where the model cannot be corroborated it
contributes nothing and `object` keeps the answer it had, because a wrong
class here would turn every read on it into a false
`call.undefined-method` on working code.

It also does nothing at all without `rigor-activerecord`, or on a project
with no `db/schema.rb` / `db/structure.sql`: the model set it checks
against comes from that plugin, and is withheld when the schema is
missing.

## Configuration

```yaml
plugins:
  - gem: rigor-active-model-serializers
    config:
      serializer_search_paths: ["app/serializers"]
      serializer_base_classes: ["ActiveModel::Serializer"]
      model_overrides:
        REST::ProfileSerializer: Account
```

| Key | Default | Meaning |
| --- | --- | --- |
| `serializer_search_paths` | `["app/serializers"]` | Where to look for serializer classes. Add a directory if a base serializer lives elsewhere (Mastodon keeps `ActivityPub::Serializer` under `app/lib`). |
| `serializer_base_classes` | `["ActiveModel::Serializer"]` | The roots the ancestry walk starts from. |
| `model_overrides` | `{}` | Serializer class name → model class name, for a serializer the naming convention cannot resolve. Your assertion; it is not re-checked against the model index. |

## Not covered

- **SimpleForm inputs.** `SimpleForm::Inputs::Base#object` shares the name
  and nothing else — its resource comes from the `simple_form_for` call
  site, not from the input class.
- **`serializer:` / `each_serializer:` options.** They name the
  serializer for an association, never the model for a serializer.
- **`attributes` names.** AMS resolves an attribute against a method on
  the serializer OR on the object, so a name in neither is still not
  provably wrong.
- **Serializers for plain objects** — `ActiveModelSerializers::Model`
  subclasses, Structs, presenters. Use `model_overrides` if the class you
  want is a real constant you are happy to have checked.
