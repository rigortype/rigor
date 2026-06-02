# rigor-rails

A convenience grouping of the seven Tier 1+2 Rails ecosystem
plugins. It is **not itself a checker** — it runs no analysis of
its own — and there is nothing to install: every plugin ships
bundled in `rigortype`.

You enable the Rails plugins by listing the ones you want under
`plugins:`. `rigor-rails` does **not** one-line-activate the set
(that keeps each plugin's opt-in under your control — a
route-helper-light app skips `rigor-rails-routes`, a
fixture-light app skips `rigor-factorybot`, and so on):

```yaml
plugins:
  - rigor-rails-routes
  - rigor-rails-i18n
  - rigor-actionmailer
  - rigor-activejob
  - rigor-activerecord
  - rigor-actionpack
  - rigor-factorybot
```

| Plugin | Scope |
| --- | --- |
| [rigor-rails-routes](rigor-rails-routes.md) | `*_path` / `*_url` helper validation |
| [rigor-rails-i18n](rigor-rails-i18n.md) | `t('key')` translation-key validation |
| [rigor-actionmailer](rigor-actionmailer.md) | mailer action existence / arity / view templates |
| [rigor-activejob](rigor-activejob.md) | `Job.perform_*` argument arity |
| [rigor-activerecord](rigor-activerecord.md) | finder / relation typing, schema-checked columns |
| [rigor-actionpack](rigor-actionpack.md) | controller helpers / filters / renders / strong-params |
| [rigor-factorybot](rigor-factorybot.md) | factory + attribute (+ AR column) validation |

Historically `rigor-rails` was a Gemfile meta-gem whose
`require "rigor-rails"` pulled in all seven entry points at once.
Under Rigor's single-bundled-gem distribution model that `require`
is redundant — the plugins are already loadable by id from
`rigortype` — so the `plugins:` list above is the canonical setup.

**Tier 3 plugins** (`rigor-pundit`, `rigor-sidekiq`, `rigor-rspec`,
`rigor-actioncable`, `rigor-activestorage`, `rigor-graphql`) are not
part of this grouping; enable them individually as your project
needs them.
