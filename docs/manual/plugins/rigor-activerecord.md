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
demo.rb:18:1: info: `User.find` returns User (table: `users`) [plugin.activerecord.model-call]
demo.rb:21:1: info: `User.where` (:admin) on table `users` [plugin.activerecord.model-call]

errors_demo.rb:12:1: error: `User.where(emial: ...)` references unknown column `emial` on table `users` (did you mean `:email`?) [plugin.activerecord.unknown-column]
errors_demo.rb:24:1: error: `User.find` expects at least 1 argument, got 0 [plugin.activerecord.wrong-arity]
```

| Diagnostic | Severity | Rule |
| --- | --- | --- |
| Recognised `Model.find` / `Model.find_by` / `Model.where` call | `:info` | `plugin.activerecord.model-call` |
| `Model.find_by(unknown: ...)` / `Model.where(unknown: ...)` | `:error` | `plugin.activerecord.unknown-column` |
| `Model.find` with 0 args | `:error` | `plugin.activerecord.wrong-arity` |
| No schema source (`db/schema.rb` or `db/structure.sql`) present — reduced mode | `:info` | `plugin.activerecord.load-error` |
| A schema source that exists but cannot be read or parsed | `:warning` | `plugin.activerecord.load-error` |

Did-you-mean suggestions use `DidYouMean` fuzzy matching against
the resolved table's column names.

## Configuration

```yaml
plugins:
  - gem: rigor-activerecord
    config:
      schema_file: "db/schema.rb"                                  # default
      structure_sql_file: "db/structure.sql"                       # default (fallback when schema_file is absent)
      model_search_paths: ["app/models"]                           # default
      model_base_classes: ["ApplicationRecord", "ActiveRecord::Base"]  # default
```

All keys are optional. Tweak them when:

- the schema lives elsewhere (`schema_file: "shared/db/schema.rb"`);
- the project uses `schema_format = :sql` and its dump is not at the
  default path (`structure_sql_file: "db/structure.sql"`);
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

`User.table_name` types as `String`, and as the exact string
where the plugin knows it exactly — a `self.table_name = "people"`
in your source (inherited down an STI chain), or an inflected name
the schema confirms with a table of that name. An inflected name
nothing confirms stays plain `String`: `table_name_prefix`, a
`def self.table_name` override and a custom inflection rule all
produce a name the plugin cannot see, and guessing the value
there would be worse than not knowing it.
`User.quoted_table_name` is always `String` — the quoting is up
to the database adapter.

## Limitations

- **Direct-superclass match only.** `class Admin < User` where
  `User < ApplicationRecord` is not discovered. Either add `User`
  to `model_base_classes`, or list every concrete model
  explicitly.
- **PostgreSQL `db/structure.sql` fallback.** When `db/schema.rb` is
  absent, the plugin parses `db/structure.sql` (the `schema_format =
  :sql` dump) for the same column/type table. It reads PostgreSQL DDL
  only; a column whose SQL type has no Ruby mapping (a custom enum,
  `tsvector`, `ltree`) degrades to `Object` (never dropped), and
  non-`public`-schema partition tables are skipped.
- **No committed schema — reduced mode.** A project that ships raw
  migrations and gitignores `db/schema.rb` (the DB-agnostic Rails
  pattern) still gets table names, finders, scopes and associations:
  those are read from your model source, not from the schema. Only
  the column-dependent half stands down — column readers stay
  untyped and `where(col:)` keys are not validated, exactly as they
  are for a table the schema does not describe. The plugin says so
  once per run at `:info`. Committing a schema dump (or pointing
  `schema_file` / `structure_sql_file` at one) turns the column half
  back on; nothing else changes.
- **Column reads, not setters.** The plugin types instance-side
  column *reads* (`user.name`, `user.admin?`) and singular
  associations, but not the `name=` setter or the dirty-tracking
  family (`name_changed?`, `name_was`, …).
- **Project-custom inflections aren't read yet.** Model↔table
  pluralization goes through the real ActiveSupport inflector
  (so `Person → people`, `Mouse → mice` resolve), but rules you
  declare in `config/initializers/inflections.rb` are not yet
  ingested — a model relying on one needs `self.table_name`
  (ADR-39 slice 3).

## Plugin internals

Architecture (the cached schema-parser → model-index → analyzer
chain), the source layout, how to run the demo, and the plugin
contract surfaces this plugin exercises are documented in the
[plugin's README](../../../plugins/rigor-activerecord/README.md).
To write a plugin of your own, see the
[`examples/`](../../../examples/README.md) walkthroughs and the
[`rigor-plugin-author`](../08-skills.md) skill.
