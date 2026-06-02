# rigor-actionmailer

Validates `Mailer.action(args).deliver_*` call sites for action
existence and argument arity, and flags mailer actions whose view
template is missing under `app/views/`. Actions inherited from
included concern modules are merged into the mailer's action set,
so a mailer that derives its actions from `include`d `Emails::*`
concerns still type-checks. No Rails runtime dependency.

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-actionmailer
```

## What it checks

```text
demo.rb:7:1:  info:  `UserMailer.welcome` matches mailer action (arity 1..2)
errors_demo.rb:7:1:  error: `UserMailer.welcome` expects 1..2 argument(s), got 0
errors_demo.rb:15:1: error: `UserMailer.does_not_exist` is not a defined mailer action (known actions: digest, reset_password, welcome)
app/mailers/user_mailer.rb:14:7: warning: `UserMailer#digest` has no view template under `app/views/user_mailer/`
```

1. **Action existence** — `Mailer.unknown_action(...)` →
   `unknown-action` (an unresolved `include` silences this rather
   than guessing).
2. **Argument arity** — too few / too many positional args →
   `wrong-arity`.
3. **View template existence** — each action needs at least one
   `app/views/<mailer_underscore>/<action>.{html,text}.{erb,haml,slim}`;
   a missing one → `missing-view`, anchored on the action's `def`.

Recognised call shapes: a direct action call
(`UserMailer.welcome(user)`), a `.with(...)` chain
(`UserMailer.with(user: u).welcome(user)`), and a trailing
`.deliver_now` / `.deliver_later` (accepted, not interpreted).

## Configuration

```yaml
plugins:
  - gem: rigor-actionmailer
    config:
      mailer_search_paths: ["app/mailers"]                            # default
      mailer_base_classes: ["ApplicationMailer", "ActionMailer::Base"] # default
      views_root: "app/views"                                         # default
```

## Limitations

- **Direct-superclass match only.** `class CustomerMailer <
  BaseMailer` where `BaseMailer < ApplicationMailer` is not
  discovered unless `BaseMailer` is in `mailer_base_classes`.
  (Actions from `include`d concern *modules* are merged; this is
  about the superclass chain.)
- **Syntactic action list.** Actions are read from instance-side
  `def`s; `define_method`, `initialize`, and `_`-prefixed names are
  excluded.
- **Standard view filename pattern only**
  (`<action>.{html,text}.{erb,haml,slim}`); custom engines / view
  paths are out of scope.
- A brand-new view file does not invalidate the cached index until
  something the mailer file touches changes (the read-tracking
  trade-off).

## Plugin internals

The mailer/concern discoverer, the cached `:mailer_index` producer,
the demo, and the contract surfaces this plugin exercises are in
the [plugin's README](../../../plugins/rigor-actionmailer/README.md).
To write a plugin, see [`examples/`](../../../examples/README.md)
and the [`rigor-plugin-author`](../08-skills.md) skill.
