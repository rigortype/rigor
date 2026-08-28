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
  `#tomorrow`, `#beginning_of_*` / `#end_of_*`, `#ago`, `#since`.
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

## No diagnostics, no config

The plugin is RBS-only — it emits no diagnostics and has no
configuration knobs. It contributes its signatures unconditionally when
listed under `plugins:`.

## Limitations

- **Conservative return types.** `Integer#days` really returns
  `ActiveSupport::Duration`, but the bundle types it `untyped` because
  the analysis environment usually lacks the Duration class — the goal
  is to silence undefined-method, not to give precise returns. Likewise
  `#html_safe` is typed `String` (not `SafeBuffer`) and `#try` / `#try!`
  return `untyped`.
- **Project-private monkey-patches are not covered** — only real
  ActiveSupport extensions. For your own core-class patches see the
  `pre_eval:` mechanism ([ADR-17](../../adr/17-monkey-patch-pre-evaluation.md)).
- **Top ~40 selectors, not exhaustive.** ActiveSupport ships hundreds of
  extensions; this covers the head of the real-world distribution.

## Plugin internals

The RBS layout, the per-class coverage, and the survey that picked the
selectors are in the
[plugin's README](../../../plugins/rigor-activesupport-core-ext/README.md).
To write a plugin, see [`examples/`](../../../examples/README.md) and the
[`rigor-plugin-author`](../08-skills.md) skill.
