# rigor-sidekiq

Tier 3C of Rigor's Rails ecosystem family
([roadmap](../../docs/design/20260508-rails-plugins-roadmap.md)).
Validates `Worker.perform_async(...)` / `.perform_in(...)` /
`.perform_at(...)` / `.perform_inline(...)` argument counts against the
discovered `#perform` definitions, and types the jid the first three
return. No `sidekiq` runtime dependency — the plugin reads project
source via Prism only.

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
│           ├── schedule_scan.rb        ← reads `class:` out of schedule YAML
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
| `manifest(... config_schema:, produces:)` | `worker_search_paths` / `worker_marker_modules` / `schedule_paths` knobs (ADR-40 declared defaults) + the `:reachability_roots` fact. |
| `Plugin::Base.producer :worker_index` | Caches the discovered worker index across runs (cache invalidates via `producer watch:`). |
| `Plugin::Base.producer :scheduled_workers` | Caches the schedule-YAML scan; watched separately, because editing a schedule changes which workers are reached without touching `app/workers`. |
| `#prepare(services)` (ADR-9) | Publishes the reachability roots below. |
| `Plugin::Base#io_boundary` (`read_file`) | Reads each `.rb` file under `worker_search_paths`, and each `schedule_paths` document, through the trusted scope; the digest list feeds the cache descriptor. |
| `Plugin::Base#diagnostics_for_file` | Emits the once-per-file `load-error` when worker discovery fails (file-level only). |
| `node_rule(Prism::CallNode)` (ADR-37) | Per-call arity validation of every `Worker.perform_*` over the engine-owned walk. |
| `dynamic_return methods:` (ADR-52 WD2) | Types the jid `perform_async` / `perform_in` / `perform_at` return, gated on the *discovered* worker set rather than the method name (#534). |
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

## Schedule roots for `rigor unused`

The plugin publishes exactly one kind of reachability root ([ADR-102](../../docs/adr/102-unused-code-reachability-report.md) WD3): **a worker named under a `class:` key in schedule configuration.**

That worker is enqueued from YAML by name, so `MyWorker` may appear nowhere in the repository — the constant scan sees nothing, and a job that runs every night reads as dead code. Two layouts carry the same key, and `schedule_paths` (default `config/schedule.yml`, `config/sidekiq.yml`) says where to look:

```yaml
# config/schedule.yml — sidekiq-cron: the document IS the schedule map
nightly_report:
  cron: "0 3 * * *"
  class: "NightlyReportWorker"
```

```yaml
# config/sidekiq.yml — sidekiq-scheduler nests the same entries
:scheduler:
  :schedule:
    nightly_report:
      every: "1h"
      class: "NightlyReportWorker"
```

Parsing is `YAML.safe_load` (`aliases: true`, `Symbol` permitted, nothing else). No Rails environment, no sidekiq runtime.

**Everything else is still a decline, and the declines are what make the contribution worth having.**

- **`MyWorker.perform_async(...)` supplies nothing.** It writes the worker's name as an ordinary constant, which the report's scan already records; a root would add nothing.
- **The discovered worker set supplies nothing.** "A file exists under `app/workers`" is not evidence that anything enqueues it. Publishing that set would mark every orphaned worker reachable forever — the failure mode ADR-102 § Consequences names, where an over-supplying root source silently hides real dead code and nothing downstream can tell you it happened.
- **A queue name supplies nothing.** `:queues:` in `sidekiq.yml` holds queue names, and a queue name is not a class name. Inflecting `report_worker` into `ReportWorker` would manufacture a root out of a naming coincidence, which is the same over-supply in a smaller costume.
- **A `class:` value the plugin never discovered supplies nothing.** Every name read from YAML is intersected with the `WorkerIndex`, exactly as `rigor-pundit` intersects its derived policy names. A typo, a renamed class, or a job living outside `worker_search_paths` therefore costs coverage rather than manufacturing a root, and the report's `matched no declaration` counter stays meaningful.
- **A malformed or absent schedule supplies nothing, and costs nothing else.** A missing file, an unreadable one, a YAML syntax error, or a non-Hash document is skipped; the roots the other configured paths supply still arrive.

Known under-supply, both by the same "read only what is written" rule: `sidekiq-cron`'s alternative `klass:` spelling, and a schedule loaded from Ruby (`Sidekiq::Cron::Job.load_from_hash!`) rather than from a file under `schedule_paths`.

### Corpus measurement (2026-08-16)

| target | schedule names | discovered workers | roots published | effect |
| --- | ---: | ---: | ---: | --- |
| mastodon (`:scheduler: :schedule:`) | 17 | 97 | 17 | *reachable only from tests* 164 → 134; candidates unchanged at 45; `matched no declaration` stays 0 |
| gitlab (`config/schedule.yml`) | 111 | 0 | 0 | report byte-identical |

Mastodon is the case the slice exists for: its schedulers were reported as *reachable only from their own specs* — a wrong answer for a job that runs every five minutes — and rooting them moved the 17 schedulers plus 13 classes they transitively reach (`Vacuum::*`, `AccountStatusesCleanupService`, …) into production-reachable, without adding a single candidate.

GitLab is the under-supply direction working as designed, and worth reading as a configuration lesson rather than a bug: every GitLab worker mixes in the project's own `ApplicationWorker` concern instead of `Sidekiq::Job`, so `worker_marker_modules` discovers nothing and all 111 schedule names are dropped. Add `ApplicationWorker` to `worker_marker_modules` and the same schedule yields 100 roots (the remaining 11 live outside `worker_search_paths`, under `ee/`).

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
