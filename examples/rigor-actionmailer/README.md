# rigor-actionmailer

Tier 1C of Rigor's Rails ecosystem family
([roadmap](../../docs/design/20260508-rails-plugins-roadmap.md)).
Validates `Mailer.action(args).deliver_*` call sites for
method existence and argument arity, and detects mailer
actions whose view template is missing under `app/views/`.
No Rails runtime dependency — the plugin reads project
source via Prism only.

## What the plugin recognises

Given a mailer class:

```ruby
# app/mailers/user_mailer.rb
class UserMailer < ApplicationMailer
  def welcome(user, locale = "en")
    # ...
  end

  def reset_password(user)
    # ...
  end

  def digest(*entries)
    # ...
  end
end
```

…the plugin validates every call site against the
discovered actions and arity envelopes:

```text
demo.rb:7:1:  info:  `UserMailer.welcome` matches mailer action (arity 1..2)
demo.rb:8:1:  info:  `UserMailer.welcome` matches mailer action (arity 1..2)
demo.rb:9:1:  info:  `UserMailer.welcome` matches mailer action (arity 1..2)

errors_demo.rb:7:1:  error: `UserMailer.welcome` expects 1..2 argument(s), got 0
errors_demo.rb:11:1: error: `UserMailer.welcome` expects 1..2 argument(s), got 3
errors_demo.rb:15:1: error: `UserMailer.does_not_exist` is not a defined mailer action (known actions: digest, reset_password, welcome)
```

For each discovered action, the plugin also checks that at
least one matching view template exists under
`app/views/<mailer_underscore>/`:

```text
app/mailers/user_mailer.rb:14:7: warning: `UserMailer#digest` has no view template under `app/views/user_mailer/`
```

## Recognised call shapes

| Shape | Example |
| --- | --- |
| Direct action call | `UserMailer.welcome(user)` |
| `.with(...)` chain | `UserMailer.with(user: u).welcome(user)` |
| Trailing delivery | `UserMailer.welcome(user).deliver_later` |

The plugin matches any of the above against the receiver's
discovered action list and validates the `(args)` shape on
the action method. The trailing `.deliver_now` / `.deliver_later`
is accepted but not interpreted — ActionMailer's framework
methods are not validated as actions.

## What it checks

1. **Method existence** — the action method must be defined
   on the mailer (`UserMailer.unknown_action(...)` →
   `unknown-action`).
2. **Argument arity** — too few / too many positional args
   →  `wrong-arity`.
3. **View template existence** — for every action, at least
   one of `app/views/<mailer_underscore>/<action>.{html,text}.{erb,haml,slim}`
   must exist. Missing actions →  `missing-view`,
   anchored on the action's `def` line in the mailer file.

## Configuration

```yaml
plugins:
  - gem: rigor-actionmailer
    config:
      mailer_search_paths: ["app/mailers"]                              # default; optional
      mailer_base_classes: ["ApplicationMailer", "ActionMailer::Base"]  # default; optional
      views_root: "app/views"                                           # default; optional
```

## Limitations (v0.1.0)

- **Direct-superclass match only.** `class CustomerMailer
  < BaseMailer` where `BaseMailer < ApplicationMailer` is
  NOT discovered. List `BaseMailer` in `mailer_base_classes`
  if needed.
- Action methods are read from the syntactic instance-side
  `def` list. Methods built via `define_method`, plus
  obvious non-actions (`initialize`, names prefixed with
  `_`), are excluded.
- View existence is checked against the standard
  `<action>.{html,text}.{erb,haml,slim}` filename pattern.
  Custom template engines or non-standard view paths are
  out of scope.
- Adding a brand-new view file does not invalidate the
  cached index until something the mailer file touches
  changes — the standard read-tracking trade-off.

## Layout

```text
examples/rigor-actionmailer/
├── README.md
├── rigor-actionmailer.gemspec
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
cd examples/rigor-actionmailer/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... config_schema:)` | Optional `mailer_search_paths` / `mailer_base_classes` / `views_root` knobs. |
| `Plugin::Base.producer :mailer_index` | Caches the discovered mailer index across runs. |
| `Plugin::Base#io_boundary` (`read_file`) | Reads each `.rb` file under `mailer_search_paths` AND every existing view template through the trusted scope; the digest list feeds the cache descriptor. |
| `Plugin::Base#diagnostics_for_file` | Per-file walker that emits both call-site diagnostics and (when the file under analysis IS the mailer's source) any pending `missing-view` diagnostics. |

## Future direction

- **Cross-plugin handoff**: a future slice could publish
  the mailer index as an ADR-9 fact for downstream
  consumers (e.g. a `rigor-rails-routes`-aware plugin that
  validates references to mailer actions inside routes).
- **Keyword-argument validation**: the discoverer reads
  the syntactic parameter list; the analyzer can start
  enforcing required keyword arguments once a use case
  surfaces.
- **Indirect inheritance**: deeper `< BaseMailer <
  ApplicationMailer` chains are out of scope for v0.1.0;
  list intermediate classes in `mailer_base_classes` until
  the chain is followed automatically.

## License

MPL-2.0, matching the parent Rigor project.
