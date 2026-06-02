# Plugin reference

User-facing documentation for each bundled Rigor plugin — what
it checks, its configuration keys, what it infers, and its
limitations. For *activating* plugins in general, see
[Using plugins](../07-plugins.md); to *write* one, see the
[examples/](../../../examples/README.md) walkthroughs and the
[`rigor-plugin-author` skill](../08-skills.md).

All plugins ship bundled in `rigortype` — no separate install.
The full catalogue, with a one-line scope for every plugin, is
[plugins/README.md](../../../plugins/README.md).

## Available pages

- [rigor-activerecord](rigor-activerecord.md) — ActiveRecord
  finder / relation typing and schema-checked columns.
- [rigor-rails-routes](rigor-rails-routes.md) — `*_path` / `*_url`
  helper validation against a parsed `config/routes.rb`.
- [rigor-rails-i18n](rigor-rails-i18n.md) — `t(...)` / `I18n.t(...)`
  key, per-locale coverage, and interpolation validation.
- [rigor-actionpack](rigor-actionpack.md) — controller route
  helpers, filter chains, render targets, strong-params keys.
- [rigor-activestorage](rigor-activestorage.md) — `has_*_attached`
  attachment-accessor typing on AR models.
- [rigor-rspec](rigor-rspec.md) — RSpec `let` / `subject`
  duplicate and self-reference checks.
- [rigor-sorbet](rigor-sorbet.md) — read an existing Sorbet
  codebase (`sig` blocks, RBI, `T.*` assertions) as a type
  source (full guide: [handbook ch. 10](../../handbook/10-sorbet.md)).

_Per-plugin pages are being migrated here from each plugin's
in-tree `README.md`. Until a plugin has a page above, its
user-facing docs live in its
[`plugins/<name>/README.md`](../../../plugins/README.md)._
