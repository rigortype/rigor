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
- `ActiveSupport::Duration` — the reader surface: `#to_i` / `#in_seconds`,
  `#to_f`, `#in_minutes` / `#in_hours` / `#in_days` / `#in_weeks` /
  `#in_months` / `#in_years`, `#iso8601`, `#parts`. NOT `#ago` /
  `#until` / `#before` / `#since` / `#from_now` / `#after` — see
  _Scope and limits_ below
- `Time` — the Rails instance surface (#658) down to the callable tail, audited against
  activesupport-8.1.3.1's `core_ext/date_and_time/calculations.rb`,
  `time/calculations.rb`, `time/conversions.rb`,
  `date_and_time/zones.rb` and `date_and_time/compatibility.rb`: the
  predicates (`past?`, `future?`, `today?`, `on_weekend?`, …), the
  `days_ago` / `months_since` / `next_occurring` families, the quarter
  and `at_`-prefixed spellings, `all_week` / `all_month` /
  `all_quarter` / `all_year`, `to_fs` / `to_formatted_s` /
  `formatted_offset` / `rfc3339`, `in_time_zone`, plus the singletons
  `days_in_month`, `days_in_year`, `rfc3339`, `use_zone`, `find_zone` /
  `find_zone!` and `zone_default`. `Time` is a CORE class and therefore
  CLOSED, so an omission on it is a false positive exactly as much as a
  wrong return type is — hence an exhaustive audit and not a "top
  selectors" sample. Measured residual against a real
  `require "active_support/all"`: twelve names, ten instance and two
  singleton, every one an `alias_method` artefact of ActiveSupport's own
  operator overrides — the `plus_with{,out}_duration`,
  `minus_with{,out}_duration`, `minus_with{,out}_coercion`,
  `compare_with{,out}_coercion`, `eql_with{,out}_coercion` and
  `Time.at_with{,out}_coercion` pairs. All are `:nodoc:` in the source
  and called by nothing outside ActiveSupport, so they stay undeclared
  on purpose
- `Date` / `DateTime` — `current`, `yesterday`, `tomorrow`,
  `beginning_of_*`, `end_of_*`, `ago`, `since`, `in`, `change`. The same
  shared modules extend them, so they carry the same closed-class gap
  `Time` just closed (`Date.current.past?` still reports) — a follow-up,
  because `DateTime` inherits `Date`'s declarations and would need its
  own overrides for returns that are wrong for it
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

- **Returns conservative types**, with `ActiveSupport::Duration` as the
  documented exception. `Integer#days` is declared `untyped` in the
  bundle and then typed `ActiveSupport::Duration` by the plugin's
  `DURATION_MULTIPLIERS` rule, together with the `+` / `-` / `*`
  arithmetic around it (`Time - 30.minutes` → `Time`, `2 * 1.day` →
  Duration, `Date - 1.week` → `Date | Time`) — see the comment on
  `DURATION_MULTIPLIERS` (#534). `ActiveSupport::Duration` itself IS now
  named in the bundle (#632), with a partial reader surface (`#to_i` /
  `#in_seconds`, `#to_f`, the `#in_minutes` family, `#iso8601`,
  `#parts`): naming a class whose real surface `method_missing`-forwards
  the rest to the wrapped numeric would normally turn every omitted
  member into a false `undefined-method`, so the manifest lists it under
  `open_receivers:` (ADR-26) — the exemption `rigor-activerecord` uses
  for `ActiveRecord::Relation` — and the rule never fires against a
  Duration receiver regardless of what the class does or doesn't
  declare. `#ago` / `#until` / `#before` / `#since` / `#from_now` /
  `#after` are deliberately NOT part of that surface: they default to
  `Time.current`, and typing them was blocked on the Rails `Time`
  instance extensions being declared first, which #658 has now done —
  see #659 for the remaining half.
- **`html_safe` returns `String`.** Truly it returns
  `ActiveSupport::SafeBuffer` (a String subclass), but loss of the
  `html_safe?` predicate value is the only practical precision gap.
- **`try` / `try!` return `untyped`.** Sending a symbol to a method
  Rigor would otherwise resolve through dispatch is a known precision
  gap; this bundle deliberately accepts it to keep the surface RBS-only.
- **Project-private monkey-patches are NOT covered.** The `pre_eval:`
  mechanism (ADR-17) is the path for explicit pre-evaluation of
  project-side monkey-patches; see the survey notes.
- **Coverage is "top ~40 selectors", not exhaustive** — except on
  `Time`, where the closed-core-class argument above makes a sample
  unsound and the audit is exhaustive but for the twelve `:nodoc:`
  alias-chain artefacts listed there. ActiveSupport has hundreds of
  extension methods elsewhere. PRs welcome.

## Effects ([ADR-103](../../docs/adr/103-effect-labels.md) WD10)

Inert unless the project has an `effects:` block. This plugin carries
the **impure** half of ActiveSupport — the clock, the notification bus
and `CurrentAttributes`.

| Call | Labels |
| --- | --- |
| `Time.current`, `Date.current`, `Date.yesterday` / `tomorrow`, `DateTime.current` | `nondet.time` + `global.read` |
| `Time.zone.now` / `today`, `ActiveSupport::TimeZone#now` | `nondet.time` |
| `n.days.ago`, `n.hours.from_now`, `.until`, `.since` | `nondet.time` + `global.read` |
| `Time.zone` | `global.read`; `Time.zone=` / `use_zone` | `global.write` |
| `Time.zone_default` | `global.read`; `Time.zone_default=` | `global.write` |
| `Time.days_in_month` / `days_in_year` (the `year` default reads the clock) | `nondet.time` + `global.read` |
| `Time#in_time_zone` / `DateTime#in_time_zone` (the `zone` default reads `Time.zone`) | `global.read` |
| `Current.set` / `reset` / `attributes` (`ActiveSupport::CurrentAttributes`) | `global.read` / `global.write` + `rails.current.read` / `.write` |
| `ActiveSupport::Notifications.instrument` / `publish` | `io` + `telemetry`, plus an `opaque-callable` taint |
| `ActiveSupport::Notifications.subscribe` | `mutate.static` |

The `global.read` beside `nondet.time` is the **zone**: `Time.zone` is
process state that `Time.use_zone` and a per-request `around_action`
both rewrite. The `nondet.time` half is what stops a duration
comparison folding to a constant, and what the purity policy
([ADR-103](../../docs/adr/103-effect-labels.md) WD9) reads to decide a
result may never be remembered.

`instrument` keeps its taint because the **subscribers** are registered
at run time and the analyzer cannot see them: the summary reads "this
much, and possibly more", which is the truth.

### Purity: `%a{pure}` on the pure half (#388)

`sig/active_support/core_ext.rbs` also carries `%a{pure}` on the
predicates and transforms genuinely free of side effects — `blank?` /
`present?` / `presence`, `deep_dup` / `deep_merge`, the inflections
(`camelize`, `underscore`, `pluralize`, `titleize`, …), `squish` /
`truncate` / `remove`, `with_indifferent_access`, the Duration and
Bytes multipliers, and more — audited one by one against the vendored
ActiveSupport source rather than assumed from the method name. Each
skipped candidate carries a one-line reason in the RBS file itself:
`try` / `try!` / `as_json` dispatch to a method named at the call site
and cannot be judged in isolation; `constantize` may autoload;
`parameterize` reads `I18n.locale`; every bang method mutates in
place; and `Date#ago` / `#beginning_of_day` / friends turn out to read
`Time.zone` where the same-named `Time` methods do not — verified
against ActiveSupport's source, not inferred from the name. The file's
own header comment is the audit record; read it before assuming a
method not listed there is safe to treat as pure elsewhere.
