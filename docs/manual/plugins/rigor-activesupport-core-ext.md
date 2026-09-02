# rigor-activesupport-core-ext

An opt-in **RBS bundle** for the ActiveSupport `core_ext` extensions
that real Rails code uses most — `Time.current`, `3.days`, `Array.wrap`,
`"x".squish`, `obj.blank?`, and the rest. It ships no analyzer and no
diagnostics: its whole job is to hand Rigor signatures for these
methods so they stop showing up as `call.undefined-method` false
positives. A four-project Rails survey found **64–90% of every
project's diagnostics** came from ActiveSupport extensions missing from
stdlib RBS — making this the single largest false-positive suppressor
for Rails apps, and the one to reach for first when Rigor floods a Rails
codebase with undefined-method noise.

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-activesupport-core-ext
```

That is the whole setup — Rigor resolves the bundled `sig/`
automatically ([ADR-25](../../adr/25-plugin-contributed-rbs.md)); no
path, no vendoring, no `signature_paths:` wiring.

> **You may not need this plugin.** As of
> [ADR-72](../../adr/72-gemfile-lock-gated-rbs-overlays.md), Rigor
> auto-loads a bundled core-ext RBS overlay whenever `activesupport` is
> in your `Gemfile.lock` but ships no RBS — so the most common
> ActiveSupport false positives are already suppressed with zero config.
> This plugin is the **opt-in, fuller twin** of that overlay (and the
> authoring home for the signatures); load it when you want the complete
> surface. When it is loaded, the auto overlay stands down so the two
> never double-declare.

## What it covers

Roughly the top ~40 selectors plus their close neighbours, across:

- **Object (universal)** — `#blank?`, `#present?`, `#presence`, `#try`,
  `#try!`, `#acts_like?` (+ `NilClass` / `TrueClass` / `FalseClass`).
- **Integer / Float** — Duration multipliers (`#days`, `#hours`,
  `#minutes`, …) and Bytes multipliers (`#megabytes`, `#gigabytes`, …).
- **String** — inflections (`#underscore`, `#camelize`, `#classify`,
  `#constantize`, `#pluralize`, …), filters (`#squish`, `#truncate`),
  `#html_safe`, `#starts_with?` / `#ends_with?`, conversions.
- **Time / Date / DateTime** — `.current`, `.zone`, `#yesterday`,
  `#tomorrow`, `#beginning_of_*` / `#end_of_*`, `#ago`, `#since`. `Time`
  additionally carries its **whole** Rails instance surface (see below);
  `Date` and `DateTime` carry the same subset they always did.
- **Array** — `.wrap`, `#to_sentence`, `#in_groups_of`, `#second` …
  `#fifth`, `#compact_blank`, `#exclude?`.
- **Hash** — `#symbolize_keys` / `#stringify_keys` (+ deep / bang),
  `#deep_merge`, `#with_indifferent_access`, `#except!`.
- **Enumerable** — `#index_by`, `#index_with`, `#pluck`, `#exclude?`.

```ruby
3.days           # without the bundle: call.undefined-method Integer#days
"  x  ".squish   # without the bundle: call.undefined-method String#squish
Time.current     # without the bundle: call.undefined-method Time.current
```

## Durations are typed

`1.day`, `5.minutes`, `2.5.hours` and every other multiplier type as
`ActiveSupport::Duration`, and the arithmetic around them keeps its
meaning:

```ruby
1.day                     # ActiveSupport::Duration
Time.current - 30.minutes # Time
2 * 1.day                 # ActiveSupport::Duration
1.day + 1.hour            # ActiveSupport::Duration
Date.today - 1.week       # Date | Time
```

`Date ± duration` is a union because that is what Rails does: a
date-part duration gives you back a `Date`, a sub-day one gives you a
`Time`.

Rigor ships a **partial** signature for `ActiveSupport::Duration`: the
reader surface — `#to_i` / `#in_seconds`, `#to_f`, `#in_minutes` /
`#in_hours` / `#in_days` / `#in_weeks` / `#in_months` / `#in_years`,
`#iso8601`, `#parts` — is typed, so `3.hours.in_minutes` is `Float` and
`1.day.to_i * 2` is `Integer`. `#ago` / `#until` / `#before` / `#since`
/ `#from_now` / `#after` are NOT part of that surface — they default
to `Time.current`, and typing them was blocked on Rails' `Time`
instance extensions being declared first, which the section below now
does; the multipliers themselves are tracked separately. Every
other member — the arithmetic operators above aside, `==`, and
anything else Duration forwards through `method_missing` — resolves
without a diagnostic too, while the site still counts as a concrete
receiver for `rigor coverage --protection`. Naming
`ActiveSupport::Duration` at all would normally be the wrong move — a
partial signature on a class whose real surface forwards to
`method_missing` turns every omitted member into a false
`call.undefined-method` — so the plugin lists it under
`open_receivers:`, the same exemption `rigor-activerecord` gives
`ActiveRecord::Relation`.

The multiplier only fires on a receiver Rigor has proven numeric, so
`created_at.day`, `Date.today.year` and your own object's `#days` keep
the answers they always had.

## The Rails `Time` instance surface is declared, not sampled

`Time` is a core Ruby class, so RBS knows it fully and it is **closed**:
a name the signatures do not declare is reported
`call.undefined-method`. That makes an omission on `Time` just as much
of a false positive as a wrong return type, with no gradual middle, so
this bundle declares the surface ActiveSupport adds by audit against the
gem's own sources rather than by a "top selectors" sample.

```ruby
Time.current.to_fs(:db)             # String
Time.current.formatted_offset       # String
Time.current.past?                  # bool
Time.current.at_beginning_of_hour   # Time
Time.current.days_ago(3).all_week   # Range[Time]
Time.current.in_time_zone("Hawaii") # untyped (ActiveSupport::TimeWithZone)
Time.current.definitely_not_here    # still call.undefined-method
```

That is the predicates (`#past?`, `#future?`, `#today?`, `#on_weekend?`,
…), the whole `#days_ago` / `#months_since` / `#next_occurring` family,
the quarter and `at_`-prefixed spellings, the `#all_week` / `#all_month`
/ `#all_quarter` / `#all_year` ranges, `#to_fs` / `#to_formatted_s` /
`#formatted_offset` / `#rfc3339`, `#in_time_zone`, and the `Time.`
singletons `.days_in_month`, `.days_in_year`, `.rfc3339`, `.use_zone`,
`.find_zone` / `.find_zone!` and `.zone_default`.

Where a return cannot honestly be named it is widened rather than
guessed: `#in_time_zone` answers an `ActiveSupport::TimeWithZone`, which
this bundle does not model, so it reads `untyped`.

What is left out is twelve names, measured against a real
`require "active_support/all"`: ten instance and two singleton, every one
an `alias_method` artefact of ActiveSupport's own `+` / `-` / `<=>` /
`eql?` / `Time.at` overrides — the `plus_with{,out}_duration`,
`minus_with{,out}_duration`, `minus_with{,out}_coercion`,
`compare_with{,out}_coercion`, `eql_with{,out}_coercion` and
`Time.at_with{,out}_coercion` pairs. They are public at runtime and
`:nodoc:` in the source, and nothing outside ActiveSupport calls them;
code that does will see them reported.

`Date` and `DateTime` are extended by the same ActiveSupport modules and
do **not** carry this yet — `Date.current.past?` still reports.

## No diagnostics, no config

The plugin emits no diagnostics and has no configuration knobs. It
contributes its signatures — and the Duration typing above —
unconditionally when listed under `plugins:`.

## Limitations

- **Conservative return types.** `#html_safe` is typed `String` (not
  `SafeBuffer`) and `#try` / `#try!` return `untyped` — the goal for
  those is to silence undefined-method, not to give precise returns.
  (The Duration multipliers are one exception: they are declared
  `untyped` in the bundle and then typed by the plugin instead — not
  because the bundle can't name `ActiveSupport::Duration` (it does,
  described above), but because moving the multiplier return itself
  into RBS to match hasn't happened yet. `ActiveSupport::Duration`'s
  own reader surface is the other exception, described above.)
- **`duration / x` is not typed.** `1.day / 2` is a Duration but
  `1.day / 1.hour` is a plain `24`; the answer depends on the operand,
  so Rigor declines rather than guessing.
- **`duration + Time` is not typed either.** `30.minutes + Time.now`
  raises at runtime — `Duration#+` cannot coerce a Time, and `-`, `*`,
  and a `Date` or `DateTime` on the right fail the same way — so Rigor
  claims nothing for it. `Time.now + 30.minutes` is the form that has a
  value, and it is typed `Time`.
- **Project-private monkey-patches are not covered** — only real
  ActiveSupport extensions. For your own core-class patches see the
  `pre_eval:` mechanism ([ADR-17](../../adr/17-monkey-patch-pre-evaluation.md)).
- **Top ~40 selectors, not exhaustive** — except on `Time`, where the
  closed-core-class argument above makes a sample unsound and the audit
  is exhaustive but for the twelve `:nodoc:` alias-chain artefacts named
  there. Elsewhere ActiveSupport ships hundreds of extensions and this
  covers the head of the real-world distribution.

## Plugin internals

The RBS layout, the per-class coverage, and the survey that picked the
selectors are in the
[plugin's README](../../../plugins/rigor-activesupport-core-ext/README.md).
To write a plugin, see [`examples/`](../../../examples/README.md) and the
[`rigor-plugin-author`](../08-skills.md) skill.
