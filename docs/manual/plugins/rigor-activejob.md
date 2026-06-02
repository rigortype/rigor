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
demo.rb:6:1:  info:  `WelcomeEmailJob.perform_later` matches `#perform` (arity 1..2)
demo.rb:9:1:  error: `WelcomeEmailJob.perform_later` expects 1..2 argument(s), got 0
demo.rb:12:1: error: `WelcomeEmailJob.perform_later` expects 1..2 argument(s), got 3
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
```

## Limitations

- **Direct-superclass match only.** `class WelcomeJob < BaseJob`
  where `BaseJob < ApplicationJob` is not discovered unless you
  add `BaseJob` to `job_base_classes`.
- **Syntactic arity.** `#perform` arity is read from the parameter
  list; a `#perform` built with `define_method` is out of scope.
- **Positional arity only.** Required keyword arguments are
  recorded by the discoverer but not yet validated at the call
  site.

## Plugin internals

The job discoverer / index, the cached `:job_index` producer, the
demo, and the contract surfaces this plugin exercises are in the
[plugin's README](../../../plugins/rigor-activejob/README.md). To
write a plugin, see [`examples/`](../../../examples/README.md) and
the [`rigor-plugin-author`](../08-skills.md) skill.
