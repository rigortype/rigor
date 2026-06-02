# rigor-activerecord

Types ActiveRecord finder and relation calls against your
project's `db/schema.rb` and discovered model classes — so
`User.find(1)` is `User`, `User.where(emial: …)` is flagged as
an unknown column, and `user.posts` carries its element type
through the chain. The plugin reads source only; it never loads
`active_record`, so Rigor stays decoupled from Rails.

It ships bundled in `rigortype` — no separate install. Activate
it under `plugins:` in your config file:

```yaml
plugins:
  - rigor-activerecord
```

## What it checks

```text
demo.rb:20:1: info: `User.find` returns User (table: `users`) [plugin.activerecord.model-call]
demo.rb:23:1: info: `User.where` (:admin) on table `users` [plugin.activerecord.model-call]

errors_demo.rb:13:1: error: `User.where(emial: ...)` references unknown column `emial` on table `users` (did you mean `:email`?) [plugin.activerecord.unknown-column]
errors_demo.rb:25:1: error: `User.find` expects at least 1 argument, got 0 [plugin.activerecord.wrong-arity]
```

| Diagnostic | Severity | Rule |
| --- | --- | --- |
| Recognised `Model.find` / `Model.find_by` / `Model.where` call | `:info` | `plugin.activerecord.model-call` |
| `Model.find_by(unknown: ...)` / `Model.where(unknown: ...)` | `:error` | `plugin.activerecord.unknown-column` |
| `Model.find` with 0 args | `:error` | `plugin.activerecord.wrong-arity` |
| `db/schema.rb` not readable | `:warning` | `plugin.activerecord.load-error` |

Did-you-mean suggestions use Levenshtein distance ≤ 3 against
the resolved table's column names.

## Configuration

```yaml
plugins:
  - gem: rigor-activerecord
    config:
      schema_file: "db/schema.rb"                                  # default
      model_search_paths: ["app/models"]                           # default
      model_base_classes: ["ApplicationRecord", "ActiveRecord::Base"]  # default
```

All three keys are optional. Tweak them when:

- the schema lives elsewhere (`schema_file: "shared/db/schema.rb"`);
- models are in a non-standard directory
  (`model_search_paths: ["domain/models", "engines/billing/app/models"]`);
- the base class is custom
  (`model_base_classes: ["DbRecord", "ApplicationRecord"]`).

## What it infers

The plugin contributes call-site types as well as diagnostics.
Class-side: `User.find(1)` → `User`, `User.find_by(...)` →
`User | nil`, `User.find_by!(...)` → non-nullable `User`.
Instance-side: a column read (`user.name`) narrows to the
column's value type, `user.admin?` to `bool`, and a singular
association (`post.user`) to the target model.

Relation-returning call sites — `User.where(...)`, `User.all`,
`User.order(...)`, a `has_many` / `has_and_belongs_to_many`
accessor (`user.posts`), and user-declared `scope`s
(`Post.published`) — narrow to `ActiveRecord::Relation[Model]`.
Chained query methods keep the element type, and iteration
(`user.posts.each { |p| ... }`) yields the model. A user-defined
scope invoked on a typed relation (`User.where(...).published`)
never surfaces a false `call.undefined-method`.

## Limitations

- **Direct-superclass match only.** `class Admin < User` where
  `User < ApplicationRecord` is not discovered. Either add `User`
  to `model_base_classes`, or list every concrete model
  explicitly.
- **`db/schema.rb` only.** `db/structure.sql` (raw SQL dumps) is
  not supported in this iteration.
- **Column reads, not setters.** The plugin types instance-side
  column *reads* (`user.name`, `user.admin?`) and singular
  associations, but not the `name=` setter or the dirty-tracking
  family (`name_changed?`, `name_was`, …).
- **Regular plurals only.** `Person → people`, `Mouse → mice`,
  etc. require `self.table_name = "..."`.

## Plugin internals

Architecture (the cached schema-parser → model-index → analyzer
chain), the source layout, how to run the demo, and the plugin
contract surfaces this plugin exercises are documented in the
[plugin's README](../../../plugins/rigor-activerecord/README.md).
To write a plugin of your own, see the
[`examples/`](../../../examples/README.md) walkthroughs and the
[`rigor-plugin-author`](../08-skills.md) skill.
