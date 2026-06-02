# rigor-activesupport-core-ext

Community-maintained RBS bundle for the ActiveSupport `core_ext`
extensions that real-world Rails projects use most often.

> **Using this plugin?** The user guide — why it matters, activation,
> coverage at a glance, and limitations — lives in the manual at
> [docs/manual/plugins/rigor-activesupport-core-ext.md](../../docs/manual/plugins/rigor-activesupport-core-ext.md).
> This README is the coverage reference + design rationale.

## What it is

A `sig/` directory full of RBS declarations for ActiveSupport's
in-place extensions to Ruby's built-in classes:

- `Integer` / `Float` — Duration multipliers (`#days`, `#hours`,
  `#minutes`, …) and Bytes multipliers (`#megabytes`, `#gigabytes`, …)
- `Time` / `Date` — `current`, `yesterday`, `tomorrow`,
  `beginning_of_*`, `end_of_*`, `ago`, `since`, `in`, `change`
- `String` — `underscore`, `camelize`, `classify`, `constantize`,
  `demodulize`, `pluralize`, `singularize`, `humanize`, `tableize`,
  `parameterize`, `squish`, `truncate`, `truncate_words`,
  `html_safe`, `starts_with?`, `ends_with?`, `indent`, `mb_chars`,
  `to_time` / `to_date` / `to_datetime` / `to_hours`, `from`, `to`,
  `first`, `last`
- `Array` — `Array.wrap`, `#to_sentence`, `#in_groups_of`,
  `#in_groups`, `#split`, `#second` / `#third` / `#fourth`, `#from`,
  `#to`, `#extract!`, `#to_query`, `#to_param`, `#to_xml`, `#inquiry`,
  `#compact_blank`, `#exclude?`
- `Hash` — `#deep_dup`, `#deep_merge`, `#deep_merge!`,
  `#symbolize_keys` / `#stringify_keys` (+ deep / bang variants),
  `#assert_valid_keys`, `#except!`, `#to_query`, `#to_param`,
  `#to_xml`, `#with_indifferent_access`, `#deep_transform_keys`
- `Enumerable` — `#index_by`, `#index_with`, `#pluck`, `#pick`,
  `#exclude?`, `#including`, `#excluding`, `#without`, `#sole`
- `Object` (universal) — `#blank?`, `#present?`, `#presence`,
  `#try`, `#try!`, `#acts_like?` plus the `NilClass` / `TrueClass`
  / `FalseClass` specialisations

## Why it exists

A four-project Rails survey (Redmine, Discourse, Mastodon, GitLab
FOSS — see `docs/notes/20260515-real-world-rails-survey.md` in the
Rigor repo) measured the long tail of `call.undefined-method`
diagnostics that Rigor emits on Rails codebases. **64-90% of every
project's diagnostics came from ActiveSupport extensions absent
from stdlib RBS.** The top selectors across the four projects:

| Rank | Method | Rough count (cross-project) |
| ---: | --- | ---: |
| 1 | `Time.current` | 338 |
| 2 | `Time.zone` | 318 |
| 3 | `Array.wrap` | 281 |
| 4-7 | `Integer#minute(s)` / `#day` / `#hour` / `#minutes` | 253-211-164-106 |
| 8 | `String#squish` | 66 |
| 9 | `String#html_safe` | 61 |
| 10 | `Integer#hours` | 56 |

This bundle covers those selectors plus the close-neighbour family.

## How it works

`rigor-activesupport-core-ext` is a **pure RBS-bundle plugin** (see
[ADR-25](../../docs/adr/25-plugin-contributed-rbs.md)): it ships a `sig/`
directory and a trivial `Rigor::Plugin::Base` subclass whose manifest
declares `signature_paths: ["sig"]`. It contributes **no diagnostics
and no analyzer code** — its whole job is to hand Rigor the bundled RBS.
When the gem is listed under `.rigor.yml`'s `plugins:`, Rigor's plugin
loader resolves the `sig/` directory against the gem root and merges it
into the RBS environment.

## Bundled, opt-in

The plugin's `sig/` ships **bundled in `rigortype`** (the gemspec packs
every `plugins/*/sig/**/*.rbs`), so there is no separate gem to install
— it is simply inert until you list it under `plugins:`:

```yaml
plugins:
  - rigor-activesupport-core-ext
```

Keeping ActiveSupport coverage opt-in (rather than always-on) mirrors
how the Tier 2-3 Rails plugins are packaged: Rigor stays Rails-agnostic
at its core and the Rails-specific surface lives in plugins you enable
per project — this one contributing signatures rather than diagnostics.

## Scope and limits

- **Returns conservative types.** ActiveSupport's `Integer#days` returns
  an `ActiveSupport::Duration`; this bundle uses `untyped` because
  Rigor's analysis environment usually doesn't know the Duration
  class. The goal is to silence the `call.undefined-method` rule, not
  to give precise return types.
- **`html_safe` returns `String`.** Truly it returns
  `ActiveSupport::SafeBuffer` (a String subclass), but loss of the
  `html_safe?` predicate value is the only practical precision gap.
- **`try` / `try!` return `untyped`.** Sending a symbol to a method
  Rigor would otherwise resolve through dispatch is a known precision
  gap; this bundle deliberately accepts it to keep the surface RBS-only.
- **Project-private monkey-patches are NOT covered.** The `pre_eval:`
  mechanism (ADR-17) is the path for explicit pre-evaluation of
  project-side monkey-patches; see the survey notes.
- **Coverage is "top ~40 selectors", not exhaustive.** ActiveSupport
  has hundreds of extension methods. PRs welcome.
