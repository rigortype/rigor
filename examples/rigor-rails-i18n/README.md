# rigor-rails-i18n

Tier 1B of Rigor's Rails ecosystem family
([roadmap](../../docs/design/20260508-rails-plugins-roadmap.md)).
Validates `t('key.path')` / `I18n.t(...)` /
`I18n.translate(...)` calls against
`config/locales/*.yml`. Reports missing keys (with
did-you-mean suggestions), per-locale coverage gaps, and
interpolation-variable mismatches. No Rails runtime
dependency — the plugin reads YAML through Prism and
`YAML.safe_load` only.

## What the plugin recognises

Given locale files:

```yaml
# config/locales/en.yml
en:
  users:
    welcome: "Welcome, %{name}"
    bye: "Goodbye"

# config/locales/ja.yml
ja:
  users:
    welcome: "ようこそ、%{name}さん"
    bye: "さようなら"
```

…the plugin validates every literal-string call site
against the catalogue:

```text
demo.rb:14:1:    info:    `t('users.welcome')` resolves in en, ja
demo.rb:18:1:    info:    `t('users.bye')` resolves in en, ja

errors_demo.rb:12:1: error:   missing translation key `users.welcom` in any locale (did you mean `users.welcome`?)
errors_demo.rb:16:1: error:   `t('users.welcome')` expects interpolation `name`, got (none)
errors_demo.rb:20:1: warning: `t('users.welcome')` does not use interpolation `extra` (known placeholders: `name`)
errors_demo.rb:25:1: warning: `t('errors.messages.blank')` is missing from locale(s) ja
```

## Recognised call shapes

| Shape | Example |
| --- | --- |
| Implicit-self `t(...)` | `t('users.welcome', name: 'Alice')` |
| `I18n.t(...)` | `I18n.t('users.bye')` |
| `I18n.translate(...)` | `I18n.translate('users.welcome', name: 'Alice')` |

Calls with a non-literal first argument
(`t(some_variable)`) are silently passed through — the
plugin only validates what it can prove statically.

## What it checks

1. **Key existence** — `t('users.welcome')` is flagged
   when `users.welcome` does not appear in any locale.
   Suggests near-matches via `DidYouMean::SpellChecker`.
2. **Per-locale coverage** — when the key resolves in
   some `configured_locales` but not others, the plugin
   emits a `missing-locale` warning. Suppressed when the
   call passes `default:` (the user has explicitly
   acknowledged the partial coverage).
3. **Interpolation variables** — the leaf string's
   `%{var}` placeholders must match the call's keyword
   arguments. Missing required placeholders are errors;
   extra arguments are warnings. Reserved I18n option
   keys (`default:`, `scope:`, `locale:`, `count:`, `raise:`,
   `throw:`, `fallback:`, …) are excluded from the
   interpolation check.

## Configuration

```yaml
plugins:
  - gem: rigor-rails-i18n
    config:
      locale_search_paths: ["config/locales"]   # default; optional
      configured_locales: ["en"]                # default; optional
```

`configured_locales` controls the set of locales the
project ships. Setting it to `["en", "ja"]` triggers
`missing-locale` warnings whenever a key resolves in `en`
but not in `ja` (and vice versa).

## Limitations (v0.1.0)

- **Literal-string keys only.** `t(key)` with a variable
  receiver is silently passed through.
- **No lazy lookup.** `t('.title')` resolved against the
  rendered controller / view path is out of scope —
  needs `rigor-actionpack` to participate.
- **Pluralization is recognised but not validated.** The
  `count:` key is treated as a reserved option; whether
  the locale actually defines `:zero` / `:one` / `:other`
  branches is not checked.
- **Per-locale interpolation differences** are merged
  into a single placeholder set. If `en` writes
  `"%{name}"` but `ja` writes `"%{user_name}"`, the
  plugin currently treats both names as required —
  flag the discrepancy with the locale-coverage tooling
  for now.
- **YAML aliases / merges** are accepted (Psych's
  `aliases: true`); custom Ruby classes inside the YAML
  are NOT permitted (`safe_load`).

## Layout

```text
examples/rigor-rails-i18n/
├── README.md
├── rigor-rails-i18n.gemspec
├── lib/
│   ├── rigor-rails-i18n.rb
│   └── rigor/plugin/
│       ├── rails_i18n.rb
│       └── rails_i18n/
│           ├── locale_index.rb     ← frozen `dotted_key => Entry` value object
│           ├── locale_loader.rb    ← walks config/locales, parses YAML, builds the index
│           └── analyzer.rb         ← per-call validation
└── demo/
    ├── .rigor.yml
    ├── .gitignore
    ├── config/locales/
    │   ├── en.yml
    │   └── ja.yml
    ├── demo.rb
    └── errors_demo.rb
```

## Running the demo

```sh
cd examples/rigor-rails-i18n/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... config_schema:)` | Optional `locale_search_paths` / `configured_locales` knobs. |
| `Plugin::Base.producer :locale_index` | Caches the discovered locale index across runs. |
| `Plugin::Base#io_boundary` (`read_file`) | Reads each `.yml` / `.yaml` file under `locale_search_paths` through the trusted scope; the digest list feeds the cache descriptor. |
| `Plugin::Base#diagnostics_for_file` | Per-file walker validates every literal-string `t(...)` call. |

## Future direction

- **Lazy lookup**: when `rigor-actionpack` lands and
  publishes the controller / view path as an ADR-9 fact,
  this plugin can consume it to resolve `t('.title')`
  against the active rendering context.
- **Per-locale interpolation enforcement**: split the
  required-placeholder set per locale so the analyzer
  can flag a call that's complete for `en` but missing a
  variable for `ja`.
- **Pluralization branches**: enrich the index with
  `:zero` / `:one` / `:other` keys and validate
  `t(..., count: …)` against them.

## License

MPL-2.0, matching the parent Rigor project.
