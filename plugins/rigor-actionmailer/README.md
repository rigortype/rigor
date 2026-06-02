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
| `Plugin::Base.producer :mailer_index` | Caches the discovered mailer index across runs (keyed via `glob_descriptor` over the mailer + view globs). |
| `Plugin::Base#io_boundary` (`read_file`) | Reads each mailer `.rb` AND every existing view template through the trusted scope. |
| `node_rule` + `NodeContext` (ADR-37) | Per-call validation over the engine-owned walk; `missing-view` diagnostics surface when the file under analysis is the mailer's source. |
| `Plugin::Inflector` (ADR-39) | Mailer-name → view-directory `underscore` via the real `ActiveSupport::Inflector`. |

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
