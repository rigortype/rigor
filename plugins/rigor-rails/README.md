# rigor-rails — meta-gem (Tier 1+2 Rails ecosystem plugins)

Per [ADR-12](../../docs/adr/12-dry-rb-packaging.md) WD1 ("Per-gem
plugins + meta umbrella") and the Rails plugins roadmap at
[`docs/design/20260508-rails-plugins-roadmap.md`](../../docs/design/20260508-rails-plugins-roadmap.md),
`rigor-rails` is the **Gemfile-convenience** umbrella that pulls
in every Tier 1+2 Rails ecosystem plugin via gem dependencies.
One line in a project's `Gemfile`:

```ruby
gem "rigor-rails"
```

installs **seven plugins** in one shot:

| Tier | Plugin | Scope |
|---|---|---|
| 1A | [`rigor-rails-routes`](../rigor-rails-routes/) | `config/routes.rb` → `*_path` / `*_url` validation |
| 1B | [`rigor-rails-i18n`](../rigor-rails-i18n/) | `config/locales/*.yml` → `t('key.path')` validation |
| 1C | [`rigor-actionmailer`](../rigor-actionmailer/) | Mailer methods + view template existence |
| 1D | [`rigor-activejob`](../rigor-activejob/) | Job `perform` arity |
| 2A | [`rigor-activerecord`](../rigor-activerecord/) | Associations, enums, scopes, validations, callbacks |
| 2B | [`rigor-actionpack`](../rigor-actionpack/) | Routes / filters / renders / strong-params |
| 2C | [`rigor-factorybot`](../rigor-factorybot/) | Factory attribute → AR column validation |

## Activation in `.rigor.yml`

The umbrella does NOT auto-activate every sub-plugin. The Rigor
plugin loader walks `.rigor.yml`'s `plugins:` list and
instantiates only the plugins enumerated there — this is the
per-ADR-12-WD1 contract so users can mix-and-match the subset
their project needs. Typical Rails project:

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

A project that uses ActiveJob but skips ActionMailer simply
omits the latter row.

## What the `require` does

`require "rigor-rails"` requires every sub-plugin's entry point
in one go. Each sub-plugin's entry point side-effects a
`Rigor::Plugin.register` call, so the classes are KNOWN to the
plugin loader once requires complete. The loader's lookup phase
finds them by id when `.rigor.yml` enumerates them.

Adding the gem WITHOUT listing any plugin in `.rigor.yml` is
harmless — the sub-plugins are registered (via require side-
effects on `Bundler.require`) but never instantiated, so their
`init` / `prepare` / `diagnostics_for_file` hooks never fire.

## Why "Gemfile-convenience only"

Per [ADR-12](../../docs/adr/12-dry-rb-packaging.md) WD1, the
umbrella deliberately stops short of "list one plugin entry in
`.rigor.yml`, get all seven activated" for two reasons:

1. **User control.** Real Rails apps almost always disable at
   least one of the seven (a route-helper-light app might skip
   `rigor-rails-routes`; a fixture-driven app might skip
   `rigor-factorybot`). One-line activation removes the
   per-plugin opt-in axis.
2. **Plugin loader simplicity.** Expanding an umbrella entry
   into N sub-plugin entries would require changes to
   `Plugin::Loader` (or an "umbrella plugin" concept in the
   plugin contract). Neither is worth implementing for a small
   convenience win — listing seven `plugins:` rows is a
   one-time setup cost.

## Tier 3 plugins — not in the umbrella

Tier 3 plugins are specialised and shipped as separate gems:
[`rigor-pundit`](../rigor-pundit/),
[`rigor-sidekiq`](../rigor-sidekiq/),
[`rigor-rspec`](../rigor-rspec/),
[`rigor-actioncable`](../rigor-actioncable/),
[`rigor-activestorage`](../rigor-activestorage/),
[`rigor-graphql`](../rigor-graphql/). Add them per `Gemfile`
line as the project needs them.

## Publication status

This example directory is the **template** for what `rigor-rails`
becomes after the Tier 1+2 sub-plugins are extracted via
`git subtree split` and published to RubyGems. Until then the
gemspec's `add_dependency` declarations name gems that don't
yet exist on RubyGems — installation requires `path:` overrides
in the `Gemfile`. The extraction workflow is documented in the
[`rigor-plugin-author`](../../.codex/skills/rigor-plugin-author/SKILL.md)
SKILL.

## Related

- [ADR-12](../../docs/adr/12-dry-rb-packaging.md) WD1 — the
  per-gem + meta-umbrella packaging decision (frames both
  `rigor-rails` and the eventual `rigor-dry-rb` umbrella).
- [Rails plugins roadmap](../../docs/design/20260508-rails-plugins-roadmap.md)
  § "After Tier 1+2 lands" — the umbrella's positioning in
  the larger Rails ecosystem track.
- [`rigor-dry-types`](../rigor-dry-types/) — the dry-rb side's
  Tier A foundation (companion to dry-schema + dry-struct).
