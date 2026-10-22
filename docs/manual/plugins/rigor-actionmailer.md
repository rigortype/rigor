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
demo.rb:7:1: info: `UserMailer.welcome` matches mailer action (arity 1..2) [plugin.actionmailer.mailer-call]
errors_demo.rb:10:1: error: `UserMailer.welcome` expects 1..2 argument(s), got 0 [plugin.actionmailer.wrong-arity]
errors_demo.rb:18:1: error: `UserMailer.does_not_exist` is not a defined mailer action (known actions: digest, reset_password, welcome) [plugin.actionmailer.unknown-action]
app/mailers/user_mailer.rb:26:7: warning: `UserMailer#digest` has no view template under `app/views/user_mailer/` [plugin.actionmailer.missing-view]
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
- **No roots for [`rigor unused`](../02-cli-reference.md#rigor-unused).**
  `MyMailer.welcome(...)` names the mailer as an ordinary constant,
  which the report already records. Rooting every class under
  `app/mailers` instead would mark a mailer nothing sends reachable
  forever on no evidence.
- **The "failed to discover mailers" warning is run-scoped.** It is
  a fact about your configuration, not about any one source file, so
  it is reported once per run on `.rigor.yml` rather than repeated on
  every analysed file. It is `:warning`, so if you baselined it at its
  old position that entry no longer matches and the row fails a
  `--fail-on=warning` run — regenerate with `rigor baseline
  regenerate`.

## Instance variable writes across actions

The plugin tells the engine that a mailer runs one action per instance
([ADR-125](../../adr/125-per-invocation-classes.md)). Its manifest lists
`ActionMailer::Base` in `per_invocation_classes:`, and the callback macros
(`before_action` and the rest) and `helper_method` in
`per_invocation_non_action_macros:`, so a method those name is not an action.

So [`def.ivar-write-mismatch`](../04-diagnostics.md#rule-def-ivar-write-mismatch)
stays silent when `welcome` assigns `@items = [1, 2]` and `digest` assigns
`@items = { a: 1 }`. It still reports two divergent writes in the same action,
and a divergence that involves a private or protected helper, `initialize`, or a
callback target or `helper_method` that a macro in the same file names.

A method after a bare `protected` is not an action, so it is no longer checked
for a view template, the same as one after a bare `private`.

## Plugin internals

The mailer/concern discoverer, the cached `:mailer_index` producer,
the demo, and the contract surfaces this plugin exercises are in
the [plugin's README](../../../plugins/rigor-actionmailer/README.md).
To write a plugin, see [`examples/`](../../../examples/README.md)
and the [`rigor-plugin-author`](../08-skills.md) skill.
