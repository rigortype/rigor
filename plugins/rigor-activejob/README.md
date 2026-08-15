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
| `manifest(... config_schema:)` | `job_search_paths` / `job_base_classes` knobs (ADR-40 declared defaults). |
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
