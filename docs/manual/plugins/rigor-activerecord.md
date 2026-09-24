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
| `Model.find` with 0 args and no block (unless the model defines `self.find`) | `:error` | `plugin.activerecord.wrong-arity` |
| No schema source (`db/schema.rb` or `db/structure.sql`) present — reduced mode | `:info` | `plugin.activerecord.load-error` |
| A schema source that exists but cannot be read or parsed | `:warning` | `plugin.activerecord.load-error` |

Did-you-mean suggestions use `DidYouMean` fuzzy matching against
the resolved table's column names.

A model that defines its own `self.find` owns that method's arity.
The plugin reports no `wrong-arity` for it, and no note for the
several-id or block form, where the call types as the model's
method rather than Rails' `find`. A single id is still noted as the
model, which is how it types. In an editor, a `self.find` in the
same file is not yet seen here, so the note and the error still
appear there ([#1329](https://github.com/rigortype/rigor/issues/1329)).

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
Class-side: `User.find(1)` → `User`, `User.find(1, 2)` →
`Array[User]`, `User.find_by(...)` → `User | nil`,
`User.find_by!(...)` → non-nullable `User`. A single argument
stays `User` even when it is an Array (`User.find([1, 2])`), so
that an untyped one, such as `params[:id]`, keeps the model type.
A relation or association (`user.posts.find(1, 2)`) answers the
same way. With a block, `find` is `Enumerable#find` over the
records, on the class and on a relation alike:
`User.find { |u| u.admin? }` → `User | nil`, and it takes no id.
The block's parameter is the model on a relation; on the class
side it stays untyped.
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

A `scope` declared inside a concern's `included do ... end` block
counts as the including model's own. `Account.without_suspended`
types as `ActiveRecord::Relation[Account]` when `Account` includes
the concern that declares the scope — directly, or through another
concern that concern includes. A concern included once in your
base class (`ApplicationRecord`) reaches every model under it.
Attribution follows the `include` you wrote, not the name: a
model that includes nothing gets nothing, whatever some other
concern in the project declares.

The gate is the `included do ... end` block itself. A scope
declared some other way — in a `class_methods do` block, a
hand-written `def self.included(base)` with `base.class_eval`, or
directly in the body of your base class rather than in a concern —
is not folded, and the call stays as untyped as it was.

`belongs_to` / `has_one` / `has_many` /
`has_and_belongs_to_many` declared in that same `included do ...
end` block count as the including model's own too, with the same
`include`-edge attribution: `account.user` narrows to
`User | nil` when `Account` includes the concern that declares
`has_one :user`, and `where(user: ...)` stops reporting a false
`unknown-column`. A model that declares the association itself
keeps its own version.

### The names a macro defines

Three macro families define ordinary instance methods that are
neither columns nor associations, and the model's recorded
surface now carries their names:

- `delegate :followers_count, to: :account_stat` — every
  delegated name, including the `prefix:` spellings
  (`delegate :can?, to: :user, prefix: true` defines
  `user_can?`). `delegate` is read from the model body, from a
  concern's `included do ... end`, and from a concern's own
  top level, where it defines an instance method the including
  model inherits.
- Attachment macros — Paperclip's `has_attached_file :avatar`
  (`avatar`, `avatar=`, `avatar?`) and Active Storage's
  `has_one_attached` / `has_many_attached` (`banner`,
  `banner_attachment`, `banner_blob`; `docs`,
  `docs_attachments`, `docs_blobs`). Paperclip's
  `avatar_file_name` / `avatar_content_type` / `avatar_file_size`
  / `avatar_updated_at` are real columns, so they come from your
  schema rather than from the macro.
- `enum` value predicates — `enum :visibility, { limited: 4 },
  suffix: :visibility` defines `limited_visibility?`, and
  `prefix:` / `_prefix:` / `_suffix:` are read the same way. An
  `enum` declared `instance_methods: false` defines none of
  them, and none are recorded.

These are recorded as NAMES. Nothing here says what a delegated
method returns, and the plugin contributes no type for one — the
value is that a consumer asking "does this model answer
`followers_count`?" gets the right answer. The consumer this was
built for is
[`rigor-active-model-serializers`](rigor-active-model-serializers.md),
which types a serializer's `object` only when the candidate model
answers every name the serializer reads.

A declaration this plugin cannot read off the source contributes
nothing rather than a guess: a `prefix: true` whose `to:` is a
method call, a non-literal `prefix:`, a computed enum value list.

If the project also installs `activerecord` through
`rbs collection install`, the collection declares
`ActiveRecord::Relation` without a type parameter while the
plugin declares `ActiveRecord::Relation[Elem]`, and RBS cannot
hold both. The plugin's declaration stands down: relation call
sites still type as `ActiveRecord::Relation[Model]`, but calls
into a relation resolve against the collection's declaration,
so the plugin's element typing (`.first` as `Model?`, for
example) is unavailable, and the run reports one
`rbs.coverage.plugin-signature-stood-down` info row naming both
files. Nothing is broken; the plugin's typing returns only when
the collection stops declaring the class.

`User.table_name` types as `String`, and as the exact string
only when your source says the name: a literal
`self.table_name = "people"` on the class or on an STI ancestor,
with nothing in that chain computing the name at runtime (a
`def self.table_name`, a `class << self` version of it, or an
interpolated assignment all count as computing it). Every other
name — anything the plugin derived by pluralizing the class name —
stays plain `String`.

That includes names that look confirmed. A `users` table in your
schema is not evidence that it is `User`'s table: with a
`self.table_name_prefix` on the base class, `User` really reads
`app_users`, and a `users` table belonging to some other model
would "confirm" the wrong guess. A wrong exact string is worse
than an honest `String` — code comparing `User.table_name` would
quietly take the wrong branch — so the plugin pins only what you
wrote down. `User.quoted_table_name` is always `String`; the
quoting is up to the database adapter.

A model declared inside a Ruby module or class (`Blog::Post`)
resolves its table the way Rails does for the cases below: the
namespace is dropped, not flattened into the name, so `Blog::Post`
reads `posts`, not `blog_posts`. A `table_name_prefix` /
`table_name_suffix` the enclosing namespace declares as a literal
(`def self.table_name_prefix = "blog_"`, `class << self` with the
same, or `mattr_accessor :table_name_prefix, default: "blog_"`) is
applied on top, so the same model reads `blog_posts` once `Blog`
sets that. `mattr_writer` does not count — it defines no reader, so
Rails never actually reads the value back, and neither does the
plugin.

`Blog::Post.table_name` still reads as the plain demodulized name
(`posts`) when `Blog`'s prefix/suffix is declared in a shape the
plugin cannot read as a literal (a computed value, two disagreeing
declarations) — but that string is informational only in this case.
The plugin does not trust it enough to look up columns against it:
guessing a bare name is the guess most likely to hit an unrelated
REAL table in a namespaced app, and a wrong corroboration is worse
than none, so `Blog::Post`'s column, alias and association checks
stand down entirely rather than run against a table that might not
be the real one.

## Framework constants resolve

The bundled signatures also name Active Record's exception hierarchy
(`ActiveRecordError` and the classes apps rescue: `RecordNotFound`,
`RecordInvalid`, `RecordNotSaved`, `StatementInvalid`,
`RecordNotUnique`, `StaleObjectError`, …), the `ActiveModel`
namespace, and `Arel`. `rescue ActiveRecord::RecordNotFound => e` types
`e` instead of leaving it opaque.

None of them declares a method surface — the declaration buys constant
resolution and asserts nothing else, so `e.record` and every other
member left out stays lenient rather than reported.
`ActiveRecord::Base` is deliberately **not** declared: closing it would
close every model in the project.

## Limitations

- **Direct-superclass match only.** `class Admin < User` where
  `User < ApplicationRecord` is not discovered. Either add `User`
  to `model_base_classes`, or list every concrete model
  explicitly.
- **A model nested inside ANOTHER non-abstract model class stands down rather
  than guesses.** `Post::Comment` where `Post < ApplicationRecord` and `Post`
  is not abstract hits a different Rails naming rule entirely — the parent's own
  table name is spliced into the middle of the child's, not a
  prefix/suffix — so the plugin recognises the shape and stands
  `Comment`'s column / alias / association checks down instead of
  computing (or guessing at) the real name. (A model nested inside
  an *abstract* parent class, such as `Base::Comment` where `Base` declares
  `self.abstract_class = true` or `primary_abstract_class`, correctly resolves
  its plain demodulized table name with full column checks.)
- **External `table_name_prefix` / `table_name_suffix` declarations and
  engines.** Declarations outside `model_search_paths` (e.g. in `lib/` or an
  engine's `isolate_namespace`) are detected across the project and cause
  affected models to safely stand down with an empty column set, rather than
  guessing an incorrect table name. Within `model_search_paths`, model-level
  and base-class `table_name_prefix` declarations (literal or computed) are
  resolved directly.
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
  once per run at `:info`, positioned on `.rigor.yml` — it is a
  fact about your configuration, not about any one source file,
  and you get the same single row with `--workers` as without. If
  you baselined this row at its old position (a controller or a
  model), that baseline entry no longer matches it — run `rigor
  baseline regenerate`. Committing a schema dump (or pointing
  `schema_file` / `structure_sql_file` at one) turns the column half
  back on from the next cold run — a warm cache keeps serving the
  reduced index until it is invalidated, so use `rigor check
  --no-cache` (or `make cache-clean`) if you want to see the change
  immediately.
- **Every kind of relation shares one signature.**
  `user.posts`, `user.posts.where(...)` and `Post.where(...)` all
  type as `ActiveRecord::Relation[Post]`, although only the first
  is an association's `CollectionProxy`, so the signature they share
  accepts the widest argument list any of them takes.
  `user.posts.delete_all(:nullify)` is valid and not reported. The
  same call on the other two raises `ArgumentError` at run time, and
  is not reported either.
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

The plugin also answers `Plugin::Base#declared_members` (ADR-113
WD4): it enumerates each model's synthesized members — column
readers and `column?` predicates, association accessors, declared
scopes, enum attributes, and macro-defined names — off the prepared
model index, so `rigor lens` can list `User`'s members without a
grep-able declaration. A row carries the member-level type the
plugin commits to: `Dynamic[top]` for column readers on purpose
(the bare, receiver-less read's answer — a written `user.name`
still narrows to the column's type), and a type only where the
plugin already answers one at `check`.

Architecture (the cached schema-parser → model-index → analyzer
chain), the source layout, how to run the demo, and the plugin
contract surfaces this plugin exercises are documented in the
[plugin's README](../../../plugins/rigor-activerecord/README.md).
To write a plugin of your own, see the
[`examples/`](../../../examples/README.md) walkthroughs and the
[`rigor-plugin-author`](../08-skills.md) skill.
