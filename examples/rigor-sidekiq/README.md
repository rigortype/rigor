# rigor-sidekiq

Tier 3C of Rigor's Rails ecosystem family
([roadmap](../../docs/design/20260508-rails-plugins-roadmap.md)).
Validates `Worker.perform_async(...)` /
`.perform_in(...)` / `.perform_at(...)` /
`.perform_inline(...)` argument counts against the
discovered `#perform` definitions. No `sidekiq` runtime
dependency — the plugin reads project source via Prism
only.

## What the plugin recognises

Given a worker class:

```ruby
# app/workers/welcome_email_worker.rb
class WelcomeEmailWorker
  include Sidekiq::Job

  def perform(user_id, locale = "en")
    # ...
  end
end
```

…the plugin validates every call site against the
discovered arity envelope (`1..2` for the example above):

```text
demo.rb:11:1: info:  `WelcomeEmailWorker.perform_async` matches `#perform` (arity 1..2)
demo.rb:18:1: info:  `WelcomeEmailWorker.perform_in`    matches `#perform` (arity 1..2)

errors_demo.rb:12:1: error: `WelcomeEmailWorker.perform_async` expects 1..2 argument(s), got 0
errors_demo.rb:21:1: error: `WelcomeEmailWorker.perform_in` requires a schedule (time / interval) as its first argument, got 0 arguments
```

## Recognised entry points

| Method | Schedule arg? | Args forwarded to `#perform` |
| --- | --- | --- |
| `Worker.perform_async(...)` | — | all args |
| `Worker.perform_inline(...)` | — | all args |
| `Worker.perform_in(t, ...)` | first arg (interval / Time) | remaining args |
| `Worker.perform_at(t, ...)` | first arg (Time) | remaining args |

## What it checks

1. **Argument count** — the forwarded args must match
   `#perform`'s arity envelope. `wrong-arity` fires
   otherwise. The diagnostic message names the schedule
   carve-out for `perform_in` / `perform_at` ("expects
   1..2 argument(s) (after the schedule)").
2. **Missing schedule** — `perform_in()` / `perform_at()`
   with zero arguments emit `missing-schedule`. The
   schedule is required even when `#perform` has no
   required positional args.

## Configuration

```yaml
plugins:
  - gem: rigor-sidekiq
    config:
      worker_search_paths: ["app/workers", "app/sidekiq"]   # default; optional
      worker_marker_modules: ["Sidekiq::Job", "Sidekiq::Worker"]  # default; optional
```

The default `worker_marker_modules` covers both modern
Sidekiq (`Sidekiq::Job`, since 6.3) and the legacy
`Sidekiq::Worker` (still common in older codebases).

## Limitations (v0.1.0)

- **Direct `include` matches only.** `class MyWorker;
  include Concerns::Sidekiqable; end` where
  `Concerns::Sidekiqable` re-includes `Sidekiq::Job`
  is NOT discovered. Add the intermediate module to
  `worker_marker_modules` if needed.
- **`#perform` arity is read from the syntactic
  parameter list.** Methods built via `define_method`
  are out of scope.
- **No keyword-argument validation.** Sidekiq serialises
  arguments to JSON, so positional args are the standard
  shape; keyword args are uncommon and not validated for
  v0.1.0.
- **Schedule type is not validated.** `perform_in("not
  a duration", 1)` would still validate the forwarded
  args. We just consume the first slot as the schedule.

## Layout

```text
examples/rigor-sidekiq/
├── README.md
├── rigor-sidekiq.gemspec
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
cd examples/rigor-sidekiq/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... config_schema:)` | Optional `worker_search_paths` / `worker_marker_modules` knobs. |
| `Plugin::Base.producer :worker_index` | Caches the discovered worker index across runs. |
| `Plugin::Base#io_boundary` (`read_file`) | Reads each `.rb` file under `worker_search_paths` through the trusted scope; the digest list feeds the cache descriptor. |
| `Plugin::Base#diagnostics_for_file` | Per-file walker validates every `Worker.perform_*` call. |
| Two-pass walk (collect → validate) | Discoverer + analyzer; mirrors `rigor-activejob` / `rigor-actionmailer`. |

## Comparison with `rigor-activejob`

The two plugins target a similar problem (background-job
arity validation) but differ in three places:

| Aspect | `rigor-activejob` | `rigor-sidekiq` |
| --- | --- | --- |
| Discovery | Direct-superclass match (`< ApplicationJob`) | `include Sidekiq::Job` (module mixin) |
| Default search paths | `app/jobs` | `app/workers`, `app/sidekiq` |
| Entry methods | `perform_later` / `perform_now` / `perform` | `perform_async` / `perform_inline` / `perform_in` / `perform_at` |
| Schedule semantics | `set(wait: ...)` deferred to a future slice | `perform_in(t, ...)` / `perform_at(t, ...)` consume first arg as schedule |

A user running both ActiveJob and Sidekiq in the same
project can enable both plugins; their indexes are
independent.

## Future direction

- **Indirect inclusion**: walk `include` chains so
  custom concerns that re-include `Sidekiq::Job` get
  discovered automatically.
- **`set(...)` chain**: the `Worker.set(queue:
  "low").perform_async(...)` chained form is already
  recognised by the analyzer (the receiver is the
  worker constant), but `set`'s positional arguments
  aren't validated. A future slice can model `set` as a
  pass-through.
- **Keyword-argument validation**: the discoverer can
  start tracking required keyword arguments once a use
  case surfaces.
- **Sidekiq Pro / Enterprise**: bulk-enqueue (`push_bulk`,
  `perform_bulk`) is out of scope for v0.1.0; queue at
  scale is rare enough in user code that we surface only
  the standard entry methods first.

## License

MPL-2.0, matching the parent Rigor project.
