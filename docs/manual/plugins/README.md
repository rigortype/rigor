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
- [rigor-activejob](rigor-activejob.md) — `Job.perform_*` argument
  arity against the discovered `#perform`.
- [rigor-actionmailer](rigor-actionmailer.md) — mailer action
  existence / arity and missing-view-template detection.
- [rigor-factorybot](rigor-factorybot.md) — factory + attribute
  (+ AR column) validation for `FactoryBot.create` / `build` / ….
- [rigor-rails](rigor-rails.md) — convenience grouping of the seven
  Tier 1+2 Rails plugins (not a checker itself).
- [rigor-dry-types](rigor-dry-types.md) — `Types::*` alias
  resolution; the dry-rb foundation (no diagnostics of its own).
- [rigor-dry-struct](rigor-dry-struct.md) — synthesises
  `Dry::Struct` `attribute` readers (precise with dry-types).
- [rigor-dry-schema](rigor-dry-schema.md) — recognises dry-schema
  declarations; publishes the typed-key table (fact-only).
- [rigor-dry-validation](rigor-dry-validation.md) — recognises
  `Dry::Validation::Contract` subclasses; result-API RBS overlay.
- [rigor-sinatra](rigor-sinatra.md) — narrows the route-block
  `self` so `params` / `redirect` / `halt` / … resolve.
- [rigor-rspec](rigor-rspec.md) — RSpec `let` / `subject`
  duplicate and self-reference checks.
- [rigor-sorbet](rigor-sorbet.md) — read an existing Sorbet
  codebase (`sig` blocks, RBI, `T.*` assertions) as a type
  source (full guide: [handbook ch. 10](../../handbook/10-sorbet.md)).
- [rigor-devise](rigor-devise.md) — synthesises the methods a
  `devise :strategy` declaration mixes into a model (no diagnostics).
- [rigor-statesman](rigor-statesman.md) — validates `transition_to(:state)`
  against the states declared in a `state_machine` block.
- [rigor-mangrove](rigor-mangrove.md) — sharpens Mangrove
  `Result` / `Option` unwrap types and synthesises `Enum` variants.
- [rigor-pundit](rigor-pundit.md) — policy-class existence and
  `authorize(record, :action)` predicate validation.

_Per-plugin pages are being migrated here from each plugin's
in-tree `README.md`. Until a plugin has a page above, its
user-facing docs live in its
[`plugins/<name>/README.md`](../../../plugins/README.md)._
