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
- [rigor-sidekiq](rigor-sidekiq.md) — Sidekiq `Worker.perform_*`
  argument arity against the discovered `#perform`.
- [rigor-actioncable](rigor-actioncable.md) — `broadcast_to` channel
  existence and `ActionCable.server.broadcast` stream-name validation.
- [rigor-minitest](rigor-minitest.md) — local-variable narrowing
  through Minitest / Test::Unit assertions and spec matchers.
- [rigor-graphql](rigor-graphql.md) — GraphQL-Ruby type / enum / input
  / mutation table publication (cross-plugin facts, no diagnostics).
- [rigor-rspec-rails](rigor-rspec-rails.md) — `have_http_status`
  argument validation (out-of-range codes, unknown status symbols).
- [rigor-shoulda-matchers](rigor-shoulda-matchers.md) — shoulda matcher
  column / association validation against the AR model index.
- [rigor-hanami](rigor-hanami.md) — Hanami::Action `#handle` protocol
  enforcement + request/response parameter typing (ADR-28).
- [rigor-typescript-utility-types](rigor-typescript-utility-types.md) —
  `Pick` / `Omit` / `Partial` / … mapped onto Rigor shape projections.
- [rigor-rbs-inline](rigor-rbs-inline.md) — ingests `# @rbs` inline
  comments as enforced RBS contracts (ADR-32).
- [rigor-activesupport-core-ext](rigor-activesupport-core-ext.md) —
  opt-in RBS bundle for ActiveSupport core_ext (the biggest Rails FP source).

The browser **playground** (`rigor playground`) is infrastructure, not
a checker plugin — it has no page here; see the
[CLI reference](../02-cli-reference.md) and
[ADR-29](../../adr/29-browser-playground.md).

_Every bundled checker plugin has a page above; each plugin's in-tree
[`README.md`](../../../plugins/README.md) now covers its internals
(layout, architecture, the contract surfaces it exercises) and links
back up to its page here._
