# rigor-rails-i18n

Validates `t('key.path')` / `I18n.t(...)` / `I18n.translate(...)`
calls against `config/locales/*.yml`: missing keys (with
did-you-mean suggestions), per-locale coverage gaps, and
interpolation-variable mismatches. No Rails runtime dependency —
locale files are read through Prism and `YAML.safe_load` only.

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-rails-i18n
```

## What it checks

Against a locale catalogue, every statically-resolvable call site
is validated:

```text
demo.rb:14:1: info:    `t('users.welcome')` resolves in en, ja
errors_demo.rb:12:1: error:   missing translation key `users.welcom` in any locale (did you mean `users.welcome`?)
errors_demo.rb:16:1: error:   `t('users.welcome')` expects interpolation `name`, got (none)
errors_demo.rb:20:1: warning: `t('users.welcome')` does not use interpolation `extra` (known placeholders: `name`)
errors_demo.rb:25:1: warning: `t('errors.messages.blank')` is missing from locale(s) ja
```

1. **Key existence** — a key absent from every locale is flagged,
   with `DidYouMean` near-matches.
2. **Per-locale coverage** — a key present in some
   `configured_locales` but not others emits a `missing-locale`
   warning (suppressed when the call passes `default:`).
3. **Interpolation variables** — the leaf string's `%{var}`
   placeholders must match the call's keyword arguments. Missing
   required placeholders are errors; extras are warnings. Reserved
   I18n option keys (`default:` / `scope:` / `locale:` / `count:`
   / `raise:` / …) are excluded.

### Recognised call shapes

`t(...)` (implicit self), `I18n.t(...)`, and `I18n.translate(...)`
with a literal first argument. **Lazy keys** — `t('.title')` in a
controller — are expanded to `<controller_scope>.<action>.<key>`
from the file path and the innermost enclosing `def`, matching
Rails' convention; lazy keys in non-controller Ruby files (models,
helpers, mailers) are skipped (the scope can't be determined
statically at that point). **View template lazy keys** —
`t('.title')` inside `app/views/setting/index.html.erb` expands
to `setting.index.title` and is validated for key existence and
per-locale coverage; ERB, Haml, and Slim templates under
`view_search_paths` (default `app/views`) are scanned. Calls with
a non-literal key (`t(some_variable)`) pass through unchecked.

Keys under the prefixes Rails and the `rails-i18n` gem ship
themselves (`date.` / `time.` / `datetime.` / `number.` /
`errors.messages.` / `errors.format` / `support.array.` /
`helpers.{select,submit,label}.` / `i18n.transliterate.` /
`activerecord.errors.{messages,models}.`) are not flagged as
unknown, since the framework provides them.

## Configuration

```yaml
plugins:
  - gem: rigor-rails-i18n
    config:
      locale_search_paths: ["config/locales"]   # default
      configured_locales: ["en"]                # default
      view_search_paths: ["app/views"]          # default
```

`configured_locales` is the set of locales the project ships;
setting it to `["en", "ja"]` turns on `missing-locale` warnings
whenever a key resolves in one but not the other.
`view_search_paths` controls which directories are scanned for
view templates containing lazy `t('.key')` calls.

## Limitations

- **Literal-string keys only** — a variable key passes through.
- **Lazy keys outside controllers are skipped** — the
  controller/action scope `t('.x')` depends on isn't derivable in
  a model / helper / mailer.
- **View template lazy keys** (`t('.key')` inside ERB / Haml /
  Slim) are validated for key existence and per-locale coverage.
  Interpolation validation is skipped for templates — the hash
  may come from controller instance variables not visible in the
  template source. Configure `view_search_paths:` to override the
  default `["app/views"]`.
- **View diagnostics duplicate under `--workers`** — the view
  scan is a project-wide pass surfaced through the per-file
  diagnostic hook, so each fork-pool worker re-emits the full set
  (the same once-per-run limitation the `load-error` diagnostics
  carry). Default `rigor check` (sequential) is unaffected.
- **Pluralization is recognised but not validated** — `count:` is
  treated as a reserved option; whether the locale defines
  `:zero` / `:one` / `:other` is not checked.
- **Per-locale interpolation differences are merged** into one
  placeholder set (if `en` uses `%{name}` and `ja` uses
  `%{user_name}`, both are treated as required).
- **`safe_load` only** — YAML aliases / merges are accepted;
  custom Ruby classes in the YAML are not.

## Plugin internals

The locale loader / index, the cached `:locale_index` producer,
the demo, and the contract surfaces this plugin exercises are in
the [plugin's README](../../../plugins/rigor-rails-i18n/README.md).
To write a plugin, see [`examples/`](../../../examples/README.md)
and the [`rigor-plugin-author`](../08-skills.md) skill.
