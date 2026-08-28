# rigor-activejob

Validates `Job.perform_later(...)` / `.perform_now(...)` /
`.perform(...)` argument arity against the discovered `#perform`
definition. No Rails runtime dependency — the plugin reads project
source via Prism only.

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-activejob
```

## What it checks

Given a job whose `#perform` takes one required and one optional
argument (arity `1..2`):

```text
demo.rb:8:1: info: `WelcomeEmailJob.perform_later` matches `#perform` (arity 1..2) [plugin.activejob.job-call]
errors_demo.rb:10:1: error: `WelcomeEmailJob.perform_later` expects 1..2 argument(s), got 0 [plugin.activejob.wrong-arity]
errors_demo.rb:14:1: error: `WelcomeEmailJob.perform_later` expects 1..2 argument(s), got 3 [plugin.activejob.wrong-arity]
```

A `*rest` parameter yields an unbounded upper bound (`arity 0+`).
All three entry points — `perform_later` (async), `perform_now`
(sync), and bare `perform` — are validated against the same
`#perform` envelope.

## Configuration

```yaml
plugins:
  - gem: rigor-activejob
    config:
      job_search_paths: ["app/jobs"]                            # default
      job_base_classes: ["ApplicationJob", "ActiveJob::Base"]   # default
      recurring_paths: ["config/recurring.yml"]                 # default
```

`recurring_paths` are the schedule *files* — not directories —
behind the reachability roots below. The default is where Solid
Queue's recurring schedule conventionally lives; list your own path
if you keep it elsewhere.

## Job roots for `rigor unused`

Solid Queue is the Active Job backend Rails ships by default from
8.0, and a **recurring task names its job by string**:

```yaml
# config/recurring.yml
production:
  send_reminder:
    class: "SendReminderJob"
    schedule: "*/3 * * * *"
```

That job runs every three minutes and there is no `perform_later`
for it anywhere, so the constant scan sees nothing and
[`rigor unused`](../02-cli-reference.md#rigor-unused) reports live
production code as possibly dead. This plugin supplies the jobs your
recurring schedule names, so they drop out of the candidate list.

**Every environment block is read**, not just `production:` — a job
scheduled in `staging:` is still live code. A flat, environment-less
document works too.

Only `class:` is read. A `command:` entry is inline Ruby
(`command: "SomeModel.cleanup"`), and parsing a constant out of an
arbitrary snippet would root a class on a guess, so it supplies
nothing. A `class:` naming a job the plugin never discovered is
dropped rather than published: a typo costs you a root instead of
quietly hiding a dead job.

The schedule is read with `YAML.safe_load`. Nothing boots Rails and
nothing loads Solid Queue.

## Limitations

- **Direct-superclass match only.** `class WelcomeJob < BaseJob`
  where `BaseJob < ApplicationJob` is not discovered unless you
  add `BaseJob` to `job_base_classes`.
- **Syntactic arity.** `#perform` arity is read from the parameter
  list; a `#perform` built with `define_method` is out of scope.
- **Positional arity only.** Required keyword arguments are
  recorded by the discoverer but not yet validated at the call
  site.
- **Roots only from a recurring schedule.** A job is rooted for
  `rigor unused` when `config/recurring.yml` names it, and never for
  existing under `app/jobs`: `MyJob.perform_later` names the job as
  an ordinary constant the report already records, and rooting every
  discovered job would mark an orphaned one reachable forever on no
  evidence. A schedule loaded from Ruby rather than from a file under
  `recurring_paths` supplies nothing, by the same "read only what is
  written" rule.

## Plugin internals

The job discoverer / index, the cached `:job_index` producer, the
demo, and the contract surfaces this plugin exercises are in the
[plugin's README](../../../plugins/rigor-activejob/README.md). To
write a plugin, see [`examples/`](../../../examples/README.md) and
the [`rigor-plugin-author`](../08-skills.md) skill.
