# rigor-actionmailer

Tier 1C of Rigor's Rails ecosystem family
([roadmap](../../docs/design/20260508-rails-plugins-roadmap.md)).
Validates `Mailer.action(args).deliver_*` call sites for
method existence and argument arity, and detects mailer
actions whose view template is missing under `app/views/`.
No Rails runtime dependency — the plugin reads project
source via Prism only.

> **Using this plugin?** The user guide — recognised call shapes,
> the three checks, configuration, and limitations — lives in the
> manual at
> [docs/manual/plugins/rigor-actionmailer.md](../../docs/manual/plugins/rigor-actionmailer.md).
> This README covers the plugin's internals.

## Discovery

A discovery pass walks `mailer_search_paths`, indexes each mailer's
instance-side `def` actions, and **merges actions contributed by
`include`d concern modules** (built via a two-pass module-action
table, then a per-mailer-class merge) — so a mailer like GitLab's
`Notify < ApplicationMailer` that derives 100+ actions from ~20
`Emails::*` concerns type-checks. An unresolved `include`
(gem-shipped concern) silences `unknown-action` rather than
guessing. The pass also scans the view tree so each action's
template existence can be checked.

## Layout

```text
plugins/rigor-actionmailer/
├── README.md
├── lib/
│   ├── rigor-actionmailer.rb
│   └── rigor/plugin/
│       ├── actionmailer.rb
│       └── actionmailer/
│           ├── mailer_index.rb         ← frozen catalogue of discovered mailers
│           ├── mailer_discoverer.rb    ← walks app/mailers, indexes actions, scans views
│           └── analyzer.rb             ← per-call validation
└── demo/
    ├── .rigor.yml
    ├── .gitignore
    ├── app/mailers/user_mailer.rb
    ├── app/views/user_mailer/
    │   ├── welcome.html.erb
    │   ├── welcome.text.erb
    │   └── reset_password.html.erb
    ├── demo.rb
    └── errors_demo.rb
```

## Running the demo

```sh
cd plugins/rigor-actionmailer/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... config_schema:)` | `mailer_search_paths` / `mailer_base_classes` / `views_root` knobs (ADR-40 declared defaults). |
| `Plugin::Base.producer :mailer_index` | Caches the discovered mailer index across runs (cache invalidates via `producer watch:`). |
| `Plugin::Base#io_boundary` (`read_file`) | Reads each mailer `.rb` AND every existing view template through the trusted scope. |
| `node_rule` + `NodeContext` (ADR-37) | Per-call validation over the engine-owned walk; `missing-view` diagnostics surface when the file under analysis is the mailer's source. |
| `Plugin::Inflector` (ADR-39) | Mailer-name → view-directory `underscore` via the real `ActiveSupport::Inflector`. |

## Why this plugin supplies no `rigor unused` roots

It was considered for the reachability report ([ADR-102](../../docs/adr/102-unused-code-reachability-report.md) WD3) and **deliberately contributes nothing**.

`MyMailer.welcome(user).deliver_later` names the mailer class as an ordinary constant, which `rigor unused`'s constant scan already records. The alternative — rooting every class under `app/mailers` — would claim reachability for a mailer nothing sends, on no evidence beyond the file's location, and an over-supplying root source hides real dead code silently (ADR-102 § Consequences).

## Future direction

- **Cross-plugin handoff**: a future slice could publish
  the mailer index as an ADR-9 fact for downstream consumers.
- **Keyword-argument validation**: the discoverer reads
  the syntactic parameter list; the analyzer can start
  enforcing required keyword arguments once a use case
  surfaces.
- **Indirect inheritance**: deeper `< BaseMailer <
  ApplicationMailer` superclass chains rely on listing
  intermediate classes in `mailer_base_classes`.

## License

MPL-2.0, matching the parent Rigor project.

## Effects ([ADR-103](../../docs/adr/103-effect-labels.md) WD10)

Inert unless the project has an `effects:` block. ActionMailer is the
clearest lazy-builder-then-transport shape in Rails, and the labels
read straight off the syntax:

```ruby
UserMailer.welcome(user).deliver_now
#   └──── an edge ────┘└─ the send ─┘
```

| Call | Labels |
| --- | --- |
| `UserMailer.welcome(u)` | an **edge** into `UserMailer#welcome`; no transport — nothing has been sent |
| `.deliver_now` / `deliver_now!` | `io` + `email.send` + `rails.actionmailer.deliver` |
| `.deliver_later` / `deliver_later!` | the same, plus `rails.activejob.enqueue` + `job.enqueue` |

`email.send` rides `deliver_later` too: the mail *will* go out, and a
policy forbidding mail from a presenter means both spellings.

The transport is bare `io` because the delivery method is configured
per environment — SMTP, an HTTP API, a test double — and no static
reading can settle it. `rails.actionmailer.deliver` is what a reviewer
actually names.

The `deliver_now` row matches on the **result** of a call to the mailer
class, because that is how the idiom is written and the
`MessageDelivery` in the middle has no type the project declares.

### Entry-point preset

`rails-mailers` → `app/mailers/**/*.rb`.
