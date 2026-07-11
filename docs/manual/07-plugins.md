# Using plugins

A plugin teaches Rigor about a framework, a gem, or an
application DSL that plain inference cannot see — Rails route
helpers, RSpec `let` bindings, dry-rb struct attributes, and
so on. This page is about *activating* plugins. Writing one is
covered by [`examples/`](../../examples/README.md) and the
[`rigor-plugin-author` skill](08-skills.md).

## Activating a plugin

List plugins under the `plugins:` key in your config file:

```yaml
plugins:
  - rigor-activerecord
  - rigor-rspec
  - rigor-rails-routes
```

Each name is a plugin that ships bundled inside the `rigortype`
gem — no separate installation is needed. Listing a plugin under
`plugins:` is enough to activate it. A plugin that needs
configuration takes the object form:

```yaml
plugins:
  - gem: rigor-activerecord
    config:
      schema_file: db/schema.rb
```

## Available plugins

Rigor ships a catalogue of production plugins under
[`plugins/`](../../plugins/README.md). The set grows between
releases — consult that directory for the current list and
each plugin's options — but the families today are:

- **Rails** — `rigor-activerecord`, `rigor-actionpack`,
  `rigor-rails-routes`, `rigor-rails-i18n`,
  `rigor-actionmailer`, `rigor-activejob`,
  `rigor-activestorage`, `rigor-actioncable`. The
  `rigor-rails` meta-gem bundles the Rails set for Gemfile
  convenience; you still enumerate the individual plugins you
  want under `plugins:`.
- **Testing** — `rigor-rspec`, `rigor-rspec-rails`,
  `rigor-minitest`, `rigor-shoulda-matchers`,
  `rigor-factorybot`.
- **dry-rb** — `rigor-dry-types`, `rigor-dry-schema`,
  `rigor-dry-struct`, `rigor-dry-validation`.
- **Other ecosystems** — `rigor-sinatra`, `rigor-hanami`,
  `rigor-devise`, `rigor-pundit`, `rigor-sidekiq`,
  `rigor-graphql`, `rigor-statesman`, `rigor-sorbet`,
  `rigor-typescript-utility-types`,
  `rigor-activesupport-core-ext`.

## `plugins/` versus `examples/`

[`plugins/`](../../plugins/README.md) holds production plugins
for real gems and frameworks — the ones you activate. The
[`examples/`](../../examples/README.md) tree holds *tutorial*
plugins over deliberately simplified DSLs; they are reading
material for plugin authors, not for activation in a real
project.

## Sandboxing

A plugin may want to read a file (a schema dump) or reach the
network. Those are gated by the `plugins_io:` config keys —
the network is `disabled` by default, and a plugin can read
only the paths you list. See
[Configuration](03-configuration.md).

### Isolation strategy

A few plugins call into their target library directly (for
example to ask ActiveSupport's real inflector how to pluralise a
class name). That call runs under an **isolation strategy**, set
with the `RIGOR_PLUGIN_ISOLATION` environment variable:

| Value | Behaviour |
| --- | --- |
| `process` (default) | Run the call in a forked, crash-contained worker, so the target library's monkey-patches and any crash never contaminate Rigor. Falls back to `none` where `fork` is unavailable (Windows / JRuby). |
| `none` | Load the library into Rigor's own process and call it directly. |
| `ruby_box` | Run inside an experimental `Ruby::Box` sandbox. This needs the `RUBY_BOX=1` start flag, so the `rigor` launcher re-execs itself with it set when you select this strategy. |

The legacy `RIGOR_BOX` environment variable is a back-compat
alias for `RIGOR_PLUGIN_ISOLATION=ruby_box`. The default
(`process`) is the right choice for almost everyone; the variable
exists for the rare platform where forking is unavailable or
where you want stronger containment.
