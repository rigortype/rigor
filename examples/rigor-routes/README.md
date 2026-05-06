# rigor-routes — example Rigor plugin

Reference example for the v0.1.0 plugin **trust + cache**
surfaces. Where `rigor-lisp-eval` and `rigor-units` only
exercise slice 5 (diagnostic emission) over the in-memory
AST, `rigor-routes` shows the two slices the earlier
examples did not touch:

| Slice | Surface | Used in this plugin |
| --- | --- | --- |
| 2 | `Plugin::IoBoundary#read_file` under `TrustPolicy` | `route_table` reads `config/routes.yml` once, scoped to the project root |
| 6 | `Plugin::Base.producer` + `#cache_for` | parsed `RouteTable` is cached; cache key auto-includes the file digest |

The plugin validates Rails-style route helper calls
(`users_path`, `edit_user_path(@user.id)`, …) against the
project's YAML route table.

## What the plugin recognises

```text
demo.rb:17:6: info: users_path → GET /users [plugin.routes.path-helper]
demo.rb:24:6: info: post_comment_path → GET /posts/:post_id/comments/:id [plugin.routes.path-helper]

errors_demo.rb:9:1:  error: no route helper `unknown_widget_path` [plugin.routes.unknown-route]
errors_demo.rb:10:1: error: no route helper `useres_path` (did you mean `users_path`?) [plugin.routes.unknown-route]
errors_demo.rb:13:1: error: `user_path` expects 1 argument (:id), got 0 [plugin.routes.wrong-arity]
errors_demo.rb:16:1: error: `post_comment_path` expects 2 arguments (:post_id, :id), got 1 [plugin.routes.wrong-arity]
```

| Diagnostic | Severity | Rule |
| --- | --- | --- |
| `<helper> → METHOD /path` | `:info` | `path-helper` |
| `no route helper <name> (did you mean …?)` | `:error` | `unknown-route` |
| `<helper> expects N arguments (…), got M` | `:error` | `wrong-arity` |
| `routes file <path> not found, helper checks skipped` | `:warning` | `load-error` |

Did-you-mean suggestions use Levenshtein distance ≤ 3 against
known route names.

## Layout

```
rigor-routes/
├── README.md
├── rigor-routes.gemspec
├── lib/
│   ├── rigor-routes.rb
│   └── rigor/plugin/
│       ├── routes.rb               ← manifest, init, hook, cache producer
│       └── routes/
│           ├── route_table.rb      ← parsed YAML → frozen lookup struct
│           └── walker.rb           ← AST walk: every implicit-receiver *_path / *_url call
└── demo/
    ├── .rigor.yml                  ← `paths:` lists demo.rb + errors_demo.rb
    ├── config/routes.yml           ← read once via IoBoundary
    ├── lib/route_helpers.rb        ← runtime helpers (just enough for demo.rb to run)
    ├── demo.rb                     ← all valid calls
    └── errors_demo.rb              ← intentionally ill-typed (do NOT `ruby` this file)
```

## Running the demo

```sh
cd examples/rigor-routes/demo
RUBYLIB=$PWD/../lib bundle exec rigor check --cache-stats
```

The first run reports `plugin.routes.route_table: 0 hits, 1 miss, 1 write`.
A second run reports `1 hit, 0 misses, 0 writes` —
`config/routes.yml`'s SHA-256 digest is part of the cache key
(via the `IoBoundary`'s accumulated `FileEntry`), so the cache
auto-invalidates whenever the file changes.

## Plugin authoring surface this exercises

| Surface | Where in this plugin |
| --- | --- |
| Manifest declaration | top of `lib/rigor/plugin/routes.rb` |
| `config_schema` (`routes_file: :string`) | manifest |
| `Plugin::Base.producer :route_table do ... end` | class body of `Routes` |
| `Plugin::Base#io_boundary` (slice 2) | `Routes#route_table` private helper |
| `Plugin::IoBoundary#read_file` under `TrustPolicy` | reads `config/routes.yml`; raises `AccessDeniedError` if outside the trusted scope |
| `Plugin::Base#cache_for(producer_id)` (slice 6) | runs the producer through the cache |
| Auto-built `Cache::Descriptor` | descriptor includes (a) `PluginEntry` (id + version + config_hash) (b) `FileEntry` digests from the IoBoundary |
| `Levenshtein`-based did-you-mean | `Routes#closest_route` private helper |

## Where the file-read happens (and why the order matters)

```ruby
def route_table
  return @table if @table

  io_boundary.read_file(@routes_file)         # 1. populates IoBoundary's digest list
  @table = cache_for(:route_table, params: {}).call  # 2. captures the descriptor
  ...
end
```

`cache_for` snapshots the cache descriptor at call time. If
the read came AFTER `cache_for`, the descriptor would have no
`FileEntry`, and the cache would not invalidate when
`config/routes.yml` changes. The pattern is documented in
[`spec/rigor/plugin/cache_producer_spec.rb`](../../spec/rigor/plugin/cache_producer_spec.rb)
under "invalidates when files read via io_boundary BEFORE
cache_for change between calls".

## Compared with the other examples

| | `rigor-lisp-eval` | `rigor-units` | **`rigor-routes`** |
| --- | --- | --- | --- |
| AST walking | ✅ | ✅ | ✅ |
| Local-variable flow | — | ✅ | — |
| `IoBoundary` (slice 2) | — | — | ✅ |
| `cache_for` / producer (slice 6) | — | — | ✅ |
| `did-you-mean` style UX | — | — | ✅ |

## Future direction — lightweight HKT

Once Rigor grows the type-level computation surface
([`docs/type-specification/rigor-extensions.md`](../../docs/type-specification/rigor-extensions.md) rows 22 / 51),
the route-helper return type can be expressed directly:

```rbs
class Object
  # The return-type signature could project the literal
  # method-name suffix onto the route table at compile time.
  def users_path: () -> String
  def user_path: (Integer | String) -> String
  def post_comment_path: (Integer | String, Integer | String) -> String
end
```

The plugin then moves from emitting diagnostics to producing
those signatures via a `FlowContribution` bundle.

## License

MPL-2.0, matching the parent Rigor project.
