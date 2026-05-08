# rigor-activejob

Tier 1D of Rigor's Rails ecosystem family
([roadmap](../../docs/design/20260508-rails-plugins-roadmap.md)).
Validates `Job.perform_later(...)` / `.perform_now(...)` /
`.perform(...)` argument arity against the discovered
`#perform` definition. No Rails runtime dependency — the
plugin reads project source via Prism only.

## What the plugin recognises

Given a job class:

```ruby
# app/jobs/welcome_email_job.rb
class WelcomeEmailJob < ApplicationJob
  def perform(user_id, locale = "en")
    # ...
  end
end
```

…the plugin validates every call site against the
discovered arity envelope (`1..2` for the example above):

```text
demo.rb:6:1: info:  `WelcomeEmailJob.perform_later` matches `#perform` (arity 1..2)
demo.rb:9:1: error: `WelcomeEmailJob.perform_later` expects 1..2 argument(s), got 0
demo.rb:12:1: error: `WelcomeEmailJob.perform_later` expects 1..2 argument(s), got 3
```

`*rest` parameters yield an unbounded upper bound:

```ruby
class ReportJob < ApplicationJob
  def perform(*report_ids); end
end
```

```text
ReportJob.perform_later                  # info: arity 0+
ReportJob.perform_later(1, 2, 3, 4, 5)   # info: arity 0+ — fine
```

## Recognised entry points

| Method | Purpose |
| --- | --- |
| `Job.perform_later(...)` | Queues the job for asynchronous execution (most common). |
| `Job.perform_now(...)` | Runs the job synchronously. |
| `Job.perform(...)` | Bare execution path — same arity rules. |

All three are validated against the same `#perform`
envelope.

## Configuration

```yaml
plugins:
  - gem: rigor-activejob
    config:
      job_search_paths: ["app/jobs"]                  # default; optional
      job_base_classes: ["ApplicationJob", "ActiveJob::Base"]  # default; optional
```

## Limitations (v0.1.0)

- **Direct-superclass match only.** `class WelcomeJob <
  BaseJob` where `BaseJob < ApplicationJob` is NOT
  discovered. List `BaseJob` in `job_base_classes` if
  needed.
- The `#perform` arity is read from the syntactic
  parameter list. Methods built via `define_method` are
  out of scope.
- Required keyword arguments are recognised by the
  discoverer but not validated at the call site (positional
  arity only for v0.1.0).

## Layout

```text
examples/rigor-activejob/
├── README.md
├── rigor-activejob.gemspec
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
cd examples/rigor-activejob/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... config_schema:)` | Optional `job_search_paths` / `job_base_classes` knobs. |
| `Plugin::Base.producer :job_index` | Caches the discovered job index across runs. |
| `Plugin::Base#io_boundary` (`read_file`) | Reads each `.rb` file under `job_search_paths` through the trusted scope; the digest list feeds the cache descriptor. |
| `Plugin::Base#diagnostics_for_file` | Per-file walker validates every `Job.perform_*` call. |

## Future direction

- **Cross-plugin handoff**: a future slice could publish
  the job index as an ADR-9 fact for downstream consumers
  (e.g. a hypothetical `rigor-sidekiq` plugin that needs
  to know the project's job class names for its own
  validations).
- **Keyword-argument validation**: the discoverer already
  records required keyword parameters; the analyzer can
  start enforcing them once a use case surfaces.
- **Indirect inheritance**: deeper `< BaseJob < ApplicationJob`
  chains are out of scope for v0.1.0; the plugin
  currently relies on the user listing all relevant base
  classes in `job_base_classes`.

## License

MPL-2.0, matching the parent Rigor project.
