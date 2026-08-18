# rigor-activejob

Tier 1D of Rigor's Rails ecosystem family
([roadmap](../../docs/design/20260508-rails-plugins-roadmap.md)).
Validates `Job.perform_later(...)` / `.perform_now(...)` /
`.perform(...)` argument arity against the discovered
`#perform` definition. No Rails runtime dependency — the
plugin reads project source via Prism only.

> **Using this plugin?** The user guide — recognised entry points,
> configuration, and limitations — lives in the manual at
> [docs/manual/plugins/rigor-activejob.md](../../docs/manual/plugins/rigor-activejob.md).
> This README covers the plugin's internals.

## Layout

```text
plugins/rigor-activejob/
├── README.md
├── lib/
│   ├── rigor-activejob.rb
│   └── rigor/plugin/
│       ├── activejob.rb
│       └── activejob/
│           ├── job_index.rb         ← frozen `{class_name => Entry}` value object
│           ├── job_discoverer.rb    ← walks app/jobs, builds the index
│           └── analyzer.rb          ← per-call validation
└── demo/
    ├── .rigor.yml
    ├── .gitignore
    ├── app/jobs/welcome_email_job.rb
    ├── demo.rb
    └── errors_demo.rb
```

## Running the demo

```sh
cd plugins/rigor-activejob/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... config_schema:, produces:)` | `job_search_paths` / `job_base_classes` / `recurring_paths` knobs (ADR-40 declared defaults) + the `:reachability_roots` fact. |
| `Plugin::Base.producer :job_index` | Caches the discovered job index across runs (cache invalidates via `producer watch:`). |
| `Plugin::Base#io_boundary` (`read_file`) | Reads each `.rb` file under `job_search_paths` through the trusted scope. |
| `node_rule` (ADR-37) | Per-call validation of every `Job.perform_*` call over the engine-owned walk. |

## Why this plugin supplies no `rigor unused` roots

It was considered for the reachability report ([ADR-102](../../docs/adr/102-unused-code-reachability-report.md) WD3) and **deliberately contributes nothing**.

`MyJob.perform_later(...)` / `MyJob.perform_now(...)` name the job class as an ordinary constant, which `rigor unused`'s constant scan already records. There is no name a job is reached by that the scan cannot see, so a root here would either be redundant or would be the discovered job set — and rooting "every class under `app/jobs`" claims reachability for orphaned jobs on no evidence, hiding real dead code with no downstream signal (ADR-102 § Consequences).

## Future direction

- **Cross-plugin handoff**: a future slice could publish
  the job index as an ADR-9 fact for downstream consumers.
- **Keyword-argument validation**: the discoverer already
  records required keyword parameters; the analyzer can
  start enforcing them once a use case surfaces.
- **Indirect inheritance**: deeper `< BaseJob < ApplicationJob`
  chains rely on the user listing all relevant base
  classes in `job_base_classes`.

## License

MPL-2.0, matching the parent Rigor project.

## Effects ([ADR-103](../../docs/adr/103-effect-labels.md) WD4 / WD10)

Inert unless the project has an `effects:` block.

| Call | Labels |
| --- | --- |
| `Job.perform_later`, `perform_all_later`, `enqueue`, `enqueue_at` | *transport* (below) + `rails.activejob.enqueue` + `job.enqueue` |
| `Job.set(wait: 1.hour).perform_later` | the same — `set` is a builder and returns a lazy `ConfiguredJob`; the enqueue is the effect |
| `Job.perform_now` | an **edge** to `Job#perform`, no labels of its own |
| `Job.perform_later` | **never** an edge to `perform` |

### The transport is read from your configuration

Argument-blind, an enqueue is bare `io` — true and useless for policy.
But the adapter is declared once, and this plugin reads
`config.active_job.queue_adapter` out of `config/application.rb` and
`config/environments/*.rb`:

| `queue_adapter` | Transport | Why |
| --- | --- | --- |
| `:solid_queue`, `:delayed_job`, `:good_job`, `:que`, `:queue_classic` | `io.db.write` | an `INSERT` into the queue table — a "no database on this path" envelope is right to object |
| `:sidekiq`, `:resque`, `:sneakers`, `:shoryuken`, `:backburner` | `io.net` | a Redis / broker round trip |
| `:async`, `:inline`, `:test`, `:sucker_punch` | — | in-process; the enqueue crosses no transport |
| unread, unknown, or different per environment | `io` | the honest upper bound |

`:inline` is the one setting that licenses an edge from
`perform_later` to `perform`: Rails genuinely runs the job on the
caller's stack there. The edge comes from your declaration, never from
the plugin's opinion.

### Why no edge into a deferred body

`perform` runs in another process on another stack, so the caller's
code does not contain it. "Attribution follows the code, not the
clock" ([ADR-103](../../docs/adr/103-effect-labels.md) WD4) — the
enqueue is the caller's effect, and the job body belongs to the job's
own entry point (`reach: [rails-jobs]`).

### Entry-point preset

`rails-jobs` → `app/jobs/**/*.rb`.
