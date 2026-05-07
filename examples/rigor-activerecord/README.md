# rigor-activerecord — example Rigor plugin

Types ActiveRecord finder + relation calls against the project's
`db/schema.rb` and discovered AR model classes. The seventh
worked example for the v0.1.0 plugin contract — and the most
architecturally complete:

- **slice 2** (`Plugin::IoBoundary` / `Plugin::TrustPolicy`) for
  reading `db/schema.rb` and every file under `app/models/` under
  the trust policy;
- **slice 6** (`Plugin::Base.producer` / `#cache_for`) — twice —
  caching both the parsed schema and the resolved model index;
- **DSL interpretation** (the schema parser walks the
  `create_table "users" do |t| ... end` AST through Prism, no
  `eval`);
- **Two-pass discover-then-validate** (`ModelDiscoverer` finds
  AR class declarations, then per-file `Analyzer` validates
  query calls against the index).

Runtime-wise, the plugin does NOT require `active_record`. It
only reads source — Rigor stays decoupled from Rails.

## What the plugin recognises

```text
demo.rb:20:1: info: `User.find` returns User (table: `users`) [plugin.activerecord.model-call]
demo.rb:21:1: info: `User.find_by` (:email) on table `users` [plugin.activerecord.model-call]
demo.rb:23:1: info: `User.where` (:admin) on table `users` [plugin.activerecord.model-call]
demo.rb:27:1: info: `Post.where` (:user_id, :published) on table `posts` [plugin.activerecord.model-call]

errors_demo.rb:13:1: error: `User.where(emial: ...)` references unknown column `emial` on table `users` (did you mean `:email`?) [plugin.activerecord.unknown-column]
errors_demo.rb:25:1: error: `User.find` expects at least 1 argument, got 0 [plugin.activerecord.wrong-arity]
```

| Diagnostic | Severity | Rule |
| --- | --- | --- |
| Recognised `Model.find` / `Model.find_by` / `Model.where` call | `:info` | `model-call` |
| `Model.find_by(unknown: ...)` / `Model.where(unknown: ...)` | `:error` | `unknown-column` |
| `Model.find` with 0 args | `:error` | `wrong-arity` |
| `db/schema.rb` not readable | `:warning` | `load-error` |

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

## Layout

```
rigor-activerecord/
├── README.md
├── rigor-activerecord.gemspec
├── lib/
│   ├── rigor-activerecord.rb
│   └── rigor/plugin/
│       ├── activerecord.rb                ← manifest, init, hook, cache producers
│       └── activerecord/
│           ├── inflector.rb               ← `User → users` / `BlogPost → blog_posts`
│           ├── schema_table.rb            ← parsed schema + Column value object
│           ├── schema_parser.rb           ← Prism interpreter for create_table DSL
│           ├── model_discoverer.rb        ← walks model_search_paths via IoBoundary
│           ├── model_index.rb             ← model name → table + columns
│           └── analyzer.rb                ← per-file walker, validates AR queries
└── demo/
    ├── .rigor.yml
    ├── db/schema.rb                       ← sample schema (3 tables)
    ├── app/models/{user,post,comment}.rb  ← sample AR models
    ├── lib/runtime.rb                     ← stand-in stubs so demo.rb runs without Rails
    ├── demo.rb                            ← all valid AR calls
    └── errors_demo.rb                     ← intentionally ill-typed
```

## Running the demo

```sh
cd examples/rigor-activerecord/demo
RUBYLIB=$PWD/../lib bundle exec rigor check --cache-stats
```

First run: `plugin.activerecord.schema_table: 1 miss / 1 write` and
`plugin.activerecord.model_index: 1 miss / 1 write`. Second run:
`1 hit / 0 writes` for both producers — the cache descriptors
include the digests of every file the `IoBoundary` read, so
editing `db/schema.rb` or any model file invalidates exactly the
right entry.

## Architecture

The plugin chains two cached producers:

```
              ┌─────────────────────────────────────┐
              │ producer :schema_table              │
              │   io_boundary.read_file(schema_rb)  │
              │   SchemaParser.parse(contents)      │
              │   → SchemaTable                     │
              └────────────┬────────────────────────┘
                           │
              ┌────────────▼─────────────────────────┐
              │ producer :model_index                │
              │   ModelDiscoverer.discover           │
              │     io_boundary.read_file(each .rb)  │
              │   ModelIndex.build(rows, schema)     │
              │   → ModelIndex                       │
              └────────────┬─────────────────────────┘
                           │
              ┌────────────▼─────────────────────────┐
              │ Analyzer.new(path, model_index)      │
              │   .analyze(prism_root)               │
              │   → [Diagnostic, ...]                │
              └──────────────────────────────────────┘
```

Each producer follows the **read-first, `cache_for`-second**
pattern documented at the top of
`examples/rigor-routes/lib/rigor/plugin/routes.rb` — the
`IoBoundary` records a digest entry for every file it reads, and
`cache_for` snapshots the descriptor at call time. Reading
AFTER `cache_for` would leave the descriptor without a file
digest and the cache would never invalidate.

## Limitations (intentional for v0.1.0 of the plugin)

- **Direct-superclass match only.** `class Admin < User` where
  `User < ApplicationRecord` is NOT discovered. Either add `User`
  to `model_base_classes` config or list every concrete model
  explicitly.
- **`db/schema.rb` only.** `db/structure.sql` (PostgreSQL-style
  raw SQL dumps) is not supported in this iteration. `schema.rb`
  is the standard for most Rails apps.
- **No instance-method typing.** `user.name` (column accessor on
  an instance) does not get typed as `String`. The plugin only
  validates class-side finders. Instance accessor typing would
  need analyser integration that the v0.1.0 plugin contract does
  not yet expose. Queued for once plugin return-type contributions
  ship.
- **No associations / scopes / strong parameters.** Those belong
  in a future `rigor-rails` meta-gem that depends on this one
  plus future siblings (`rigor-actionpack`, etc.).
- **Inflector handles regular plurals only.** `Person → people`,
  `Mouse → mice` etc. require `self.table_name = "..."`.

## Plugin authoring surface this exercises

| Surface | Where in this plugin |
| --- | --- |
| Manifest declaration with `config_schema` (3 keys) | top of `lib/rigor/plugin/activerecord.rb` |
| `Plugin::IoBoundary#read_file` (slice 2) | `Routes#schema_table_or_nil`, `ModelDiscoverer#read_safely` — TWO file-read sites |
| `Plugin::Base.producer` × 2 (slice 6) | `:schema_table` and `:model_index` declarations |
| `Plugin::Base#cache_for` × 2 | `Routes#schema_table_or_nil` / `Routes#model_index` |
| Auto-built `Cache::Descriptor` chains digests | both producers feed off the same `IoBoundary` instance, so the model_index cache key naturally includes both schema digest and every model file digest |
| Prism DSL interpretation | `SchemaParser` recursive descent on `create_table` blocks |
| Two-pass cross-file analysis | discoverer walks the project, analyzer walks per file |
| `did_you_mean`-style UX | `Analyzer#closest_column` (Levenshtein ≤ 3) |

## Future direction (post-extraction)

This plugin will be extracted to its own repository
(`rigortype/rigor-activerecord`) once the v0.1.0 plugin API
shape stabilises against this real consumer — see
[`docs/MILESTONES.md`](../../docs/MILESTONES.md) and the
relevant CHANGELOG `[Unreleased]` entry. The extraction process
is recorded in
[`.codex/skills/rigor-plugin-author/SKILL.md`](../../.codex/skills/rigor-plugin-author/SKILL.md).

As of v0.1.2 the plugin emits `FlowContribution` bundles
through `#flow_contribution_for`: `User.find(1)` now narrows
to `Nominal[User]` at the call site, and `User.find_by(...)` to
`Nominal[User] | nil`. Chained calls (`User.find(1).name`)
resolve through Rigor's normal dispatch instead of the
RBS-level `untyped` envelope. `where` / `find_or_*` are
intentionally deferred — they return relations, and Rigor does
not yet carry an Enumerable-backed relation shape that would
be more precise than the existing RBS envelope.

## License

MPL-2.0, matching the parent Rigor project.
