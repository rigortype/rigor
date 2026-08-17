# rigor-activerecord

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

> **Using this plugin?** The user guide — what it checks, its
> configuration keys, what it infers, and its limitations — lives
> in the manual at
> [docs/manual/plugins/rigor-activerecord.md](../../docs/manual/plugins/rigor-activerecord.md).
> This README covers the plugin's internals and the contract
> surfaces it exercises.

## Layout

```
rigor-activerecord/
├── README.md
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
cd plugins/rigor-activerecord/demo
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

The end-user view of what these surfaces produce — diagnostics,
config, inferred types — is in the
[user guide](../../docs/manual/plugins/rigor-activerecord.md).

## License

MPL-2.0, matching the parent Rigor project.

## Effects ([ADR-103](../../docs/adr/103-effect-labels.md) WD10)

Inert unless the project has an `effects:` block. What this plugin
colours, and through which of the two channels:

| Channel | Rows |
| --- | --- |
| **Shipped RBS** — `sig/active_record/relation.rbs`, tier 1, discharging | every `ActiveRecord::Relation` method the file declares. The builder / materializer line is drawn there: `%a{pure}` on `where` / `joins` / `order` / `select` / `limit`, `%a{rigor:v1:effect io.db.read}` on `find` / `first` / `count` / `pluck` / `each` / `to_a`, `io.db.write` on `update_all` / `insert_all` / `create`. |
| **`effect_attributions:`** — the manifest, first-party discharging | `ActiveRecord::Base`'s own surface (finders → `io.db.read`, persistence → `io.db.write`, `transaction` / `with_lock` → `io.db.transaction`); the `Enumerable` delegations on a Relation, which materialise by calling `each`; `connection.execute` / `exec_query` / `select_all`, narrowed by the statement's leading SQL verb; the migration DSL → `io.db.write` + `rails.schema.write`. |

An `ActiveRecord::Base` row reaches `User.find` through the project's
own `User < ApplicationRecord < ActiveRecord::Base` lines, so one row
covers every model in the app.

### Builders are pure, materializers read

`where` composes an Arel tree and issues nothing; the query fires at
`first`, `each`, `count`. Two readings were possible — colour builders
`io.db.read` because that is how Rails developers *talk*, or colour
them ∅ because that is what the code *does* — and the truthful one
wins: a presenter that builds and returns a scope has pure code, and
the caller that materialises it gets the read.

### Framework edges

`save` runs the class body's callbacks and validators, and none of that
is visible at the call site. The `:activerecord_callbacks` strategy
reads `before_save :sym` / `validate :sym` / `after_commit :sym` off
each model and synthesises the persistence selectors as effect units
edged to those methods; `validates … uniqueness: true` additionally
contributes an `io.db.read`, because the uniqueness check IS a query.

### Not covered

`map` / `filter_map` and the rest of `Enumerable` are attributions
rather than RBS annotations, because declaring them in the bundled
signature would change how they **type**. Association readers created
by `has_many` are not rowed at all: they return a Relation, so they are
already ∅ by the builder rule, and the read appears where the caller
materialises.
