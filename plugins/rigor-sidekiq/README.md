# rigor-sidekiq

Tier 3C of Rigor's Rails ecosystem family
([roadmap](../../docs/design/20260508-rails-plugins-roadmap.md)).
Validates `Worker.perform_async(...)` / `.perform_in(...)` /
`.perform_at(...)` / `.perform_inline(...)` argument counts against the
discovered `#perform` definitions. No `sidekiq` runtime dependency —
the plugin reads project source via Prism only.

> **Using this plugin?** The user guide — recognised call shapes, the
> diagnostic catalogue, configuration, and limitations — lives in the
> manual at
> [docs/manual/plugins/rigor-sidekiq.md](../../docs/manual/plugins/rigor-sidekiq.md).
> This README covers the plugin's internals.

## Layout

```text
plugins/rigor-sidekiq/
├── README.md
├── lib/
│   ├── rigor-sidekiq.rb
│   └── rigor/plugin/
│       ├── sidekiq.rb
│       └── sidekiq/
│           ├── worker_index.rb         ← frozen `{class_name => Entry}` value object
│           ├── worker_discoverer.rb    ← walks app/workers, builds the index
│           └── analyzer.rb             ← per-call validation
└── demo/
    ├── .rigor.yml
    ├── .gitignore
    ├── app/workers/welcome_email_worker.rb
    ├── demo.rb
    └── errors_demo.rb
```

## Running the demo

```sh
cd plugins/rigor-sidekiq/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... config_schema:)` | `worker_search_paths` / `worker_marker_modules` knobs (ADR-40 declared defaults). |
| `Plugin::Base.producer :worker_index` | Caches the discovered worker index across runs (keyed via `glob_descriptor`). |
| `Plugin::Base#io_boundary` (`read_file`) | Reads each `.rb` file under `worker_search_paths` through the trusted scope; the digest list feeds the cache descriptor. |
| `Plugin::Base#diagnostics_for_file` | Emits the once-per-file `load-error` when worker discovery fails (file-level only). |
| `node_rule(Prism::CallNode)` (ADR-37) | Per-call arity validation of every `Worker.perform_*` over the engine-owned walk. |
| Two-pass walk (collect → validate) | Discoverer + analyzer; mirrors `rigor-activejob` / `rigor-actionmailer`. |

## Comparison with `rigor-activejob`

The two plugins target a similar problem (background-job arity
validation) but differ in three places:

| Aspect | `rigor-activejob` | `rigor-sidekiq` |
| --- | --- | --- |
| Discovery | Direct-superclass match (`< ApplicationJob`) | `include Sidekiq::Job` (module mixin) |
| Default search paths | `app/jobs` | `app/workers`, `app/sidekiq` |
| Entry methods | `perform_later` / `perform_now` / `perform` | `perform_async` / `perform_inline` / `perform_in` / `perform_at` |
| Schedule semantics | `set(wait: ...)` deferred to a future slice | `perform_in(t, ...)` / `perform_at(t, ...)` consume first arg as schedule |

A user running both ActiveJob and Sidekiq in the same project can
enable both plugins; their indexes are independent.

## Future direction

- **Indirect inclusion**: walk `include` chains so custom concerns that
  re-include `Sidekiq::Job` get discovered automatically.
- **`set(...)` chain**: the `Worker.set(queue: "low").perform_async(...)`
  chained form is already recognised by the analyzer (the receiver is
  the worker constant), but `set`'s own positional arguments aren't
  validated. A future slice can model `set` as a pass-through.
- **Keyword-argument validation**: the discoverer can start tracking
  required keyword arguments once a use case surfaces.
- **Sidekiq Pro / Enterprise**: bulk-enqueue (`push_bulk`,
  `perform_bulk`) is out of scope; queue-at-scale is rare enough in user
  code that we surface only the standard entry methods first.

## License

MPL-2.0, matching the parent Rigor project.
