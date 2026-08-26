# rigor-sidekiq

Validates Sidekiq enqueue calls — `Worker.perform_async(...)`,
`.perform_inline(...)`, `.perform_in(t, ...)`, `.perform_at(t, ...)` —
against the arity of the worker's discovered `#perform`. It discovers
workers by walking the configured search paths and matching classes
that `include Sidekiq::Job` (or the legacy `Sidekiq::Worker`); it reads
source only, with no `sidekiq` runtime dependency.

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-sidekiq
```

## What it checks

```ruby
# app/workers/welcome_email_worker.rb
class WelcomeEmailWorker
  include Sidekiq::Job
  def perform(user_id, locale = "en")   # arity 1..2
  end
end

WelcomeEmailWorker.perform_async(123)          # info:  matches #perform (arity 1..2)
WelcomeEmailWorker.perform_in(60, 123, "ja")   # info:  schedule carved out, 123/"ja" forwarded
WelcomeEmailWorker.perform_async              # error: expects 1..2 argument(s), got 0
WelcomeEmailWorker.perform_in                 # error: requires a schedule as its first argument
```

`perform_in` / `perform_at` consume their first argument as the
schedule (interval / Time); the remaining arguments are validated
against `#perform`. `perform_async` / `perform_inline` forward all
arguments.

| Rule | Severity | Fires when |
| --- | --- | --- |
| `plugin.sidekiq.worker-call` | info | a `Worker.perform_*` call matched a discovered worker's `#perform` arity |
| `plugin.sidekiq.wrong-arity` | error | the forwarded argument count falls outside `#perform`'s arity envelope (message names the schedule carve-out for `perform_in` / `perform_at`) |
| `plugin.sidekiq.missing-schedule` | error | `perform_in()` / `perform_at()` called with zero arguments (the schedule is required even when `#perform` takes none) |
| `plugin.sidekiq.load-error` | warning | worker discovery failed (parse/read error) — once per file |

## Configuration

```yaml
plugins:
  - gem: rigor-sidekiq
    config:
      worker_search_paths: ["app/workers", "app/sidekiq"]          # default
      worker_marker_modules: ["Sidekiq::Job", "Sidekiq::Worker"]   # default
      schedule_paths:                                              # default
        - "config/schedule.yml"
        - "config/sidekiq.yml"
```

The default `worker_marker_modules` covers both modern Sidekiq
(`Sidekiq::Job`, since 6.3) and the legacy `Sidekiq::Worker`.

`schedule_paths` are the schedule *files* — not directories — behind
the reachability roots below. The defaults are where the two schedule
layouts conventionally live; list your own path if you keep the
schedule elsewhere.

## Worker roots for `rigor unused`

A cron-scheduled worker is enqueued **by name from YAML**, so
`NightlyReportWorker` can appear nowhere in your code. Without help,
[`rigor unused`](../02-cli-reference.md#rigor-unused) reports a job
that runs every night as possibly dead. This plugin supplies the
workers your schedule names, so they drop out of the candidate list:

```yaml
# config/schedule.yml (sidekiq-cron)      config/sidekiq.yml (sidekiq-scheduler)
nightly_report:                           :scheduler:
  cron: "0 3 * * *"                         :schedule:
  class: "NightlyReportWorker"                nightly_report:
                                                every: "1h"
                                                class: "NightlyReportWorker"
```

It reads the `class:` key and nothing else. In particular a **queue
name is not a class name**: the `:queues:` list in `sidekiq.yml`
supplies no roots, because inflecting `report_worker` into
`ReportWorker` would root a worker on a naming coincidence. And a
`class:` naming a worker the plugin never discovered is dropped rather
than published, so a typo costs you a root instead of quietly hiding a
dead worker.

`MyWorker.perform_async` still supplies nothing — it is an ordinary
constant reference the report already sees. Neither does the mere
existence of a file under `app/workers`: a worker nothing enqueues
stays in the report, which is the answer you wanted.

The schedule is read with `YAML.safe_load`; nothing boots.
A missing, unreadable or malformed file is skipped without affecting
the rest of the run.

If your workers include a project concern (`include ApplicationWorker`)
rather than `Sidekiq::Job` directly, add that concern to
`worker_marker_modules` — otherwise the plugin discovers no workers,
every scheduled name is dropped, and you get no roots at all. GitLab's
`config/schedule.yml` names 111 workers, all of them concern-based:
with the default markers that is 0 roots, and with `ApplicationWorker`
added it is 100.

## Limitations

- **Direct `include` only.** A worker that mixes in a custom concern
  which re-includes `Sidekiq::Job` is not discovered — add the
  intermediate module to `worker_marker_modules`.
- **Syntactic arity only.** `#perform` arity is read from the parameter
  list; methods built with `define_method` are out of scope.
- **No keyword-argument validation.** Sidekiq serialises arguments to
  JSON, so positional args are the standard shape.
- **Schedule type is not validated.** The first slot of `perform_in` /
  `perform_at` is consumed as the schedule regardless of its type.
- **Chained `set(...)`** (`Worker.set(queue: "low").perform_async(...)`)
  is validated as a normal call; `set`'s own options are not checked.
- **Schedule roots are read from `class:` only.** `sidekiq-cron`'s
  alternative `klass:` spelling, and a schedule built in Ruby with
  `Sidekiq::Cron::Job.load_from_hash!`, supply no roots — the worker
  stays a `rigor unused` candidate rather than being guessed at.

## Plugin internals

The worker discoverer / index and the contract surfaces this plugin
exercises are in the
[plugin's README](https://github.com/rigortype/rigor/blob/master/plugins/rigor-sidekiq/README.md). To write a
plugin, see [`examples/`](https://github.com/rigortype/rigor/blob/master/examples/README.md) and the
[`rigor-plugin-author`](../08-skills.md) skill.
