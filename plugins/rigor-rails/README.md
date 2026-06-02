# rigor-rails — Tier 1+2 Rails ecosystem grouping

`rigor-rails` is a convenience grouping of the seven Tier 1+2 Rails
ecosystem plugins (per [ADR-12](../../docs/adr/12-dry-rb-packaging.md)
WD1 and the
[Rails plugins roadmap](../../docs/design/20260508-rails-plugins-roadmap.md)).
It runs no analysis of its own.

> **Using this plugin?** The user guide — how to enable the Rails
> plugin set — lives in the manual at
> [docs/manual/plugins/rigor-rails.md](../../docs/manual/plugins/rigor-rails.md).
> This README covers what the grouping is under the bundled
> distribution model.

The seven plugins it groups:

| Tier | Plugin | Scope |
|---|---|---|
| 1A | [`rigor-rails-routes`](../rigor-rails-routes/) | `config/routes.rb` → `*_path` / `*_url` validation |
| 1B | [`rigor-rails-i18n`](../rigor-rails-i18n/) | `config/locales/*.yml` → `t('key.path')` validation |
| 1C | [`rigor-actionmailer`](../rigor-actionmailer/) | Mailer methods + view template existence |
| 1D | [`rigor-activejob`](../rigor-activejob/) | Job `perform` arity |
| 2A | [`rigor-activerecord`](../rigor-activerecord/) | Associations, enums, scopes, validations, callbacks |
| 2B | [`rigor-actionpack`](../rigor-actionpack/) | Routes / filters / renders / strong-params |
| 2C | [`rigor-factorybot`](../rigor-factorybot/) | Factory attribute → AR column validation |

## Distribution: bundled, not a separate gem

Under Rigor's settled distribution model ([ADR-31](../../docs/adr/31-contribution-and-supply-chain-policy.md))
every plugin ships **inside the single `rigortype` gem** —
per-plugin gemspecs were removed (commit `9769f5fa`) and the
earlier `git subtree split` + per-plugin-RubyGems-publish plan was
retired. So there is no `gem "rigor-rails"` to install and no
separate sub-plugin gems; the plugins are simply available by id.

`lib/rigor-rails.rb` remains as a `require` aggregator —
`require "rigor-rails"` requires all seven sub-plugins' entry
points in one statement (each side-effects a
`Rigor::Plugin.register`). Under bundling this is largely redundant
(the plugins are already registered/loadable), but it is harmless
and kept for `require`-based contexts.

## Activation stays per-plugin

The grouping does **not** auto-activate the set: the plugin loader
walks `.rigor.yml`'s `plugins:` list and instantiates only the
plugins enumerated there, so users mix-and-match the subset their
project needs. See the
[user guide](../../docs/manual/plugins/rigor-rails.md) for the
`plugins:` block.

## Tier 3 plugins — not in the grouping

Tier 3 plugins are specialised and grouped separately:
[`rigor-pundit`](../rigor-pundit/),
[`rigor-sidekiq`](../rigor-sidekiq/),
[`rigor-rspec`](../rigor-rspec/),
[`rigor-actioncable`](../rigor-actioncable/),
[`rigor-activestorage`](../rigor-activestorage/),
[`rigor-graphql`](../rigor-graphql/). Enable them per project need.
