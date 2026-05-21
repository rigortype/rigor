# rigor-activesupport-core-ext

Community-maintained RBS bundle for the ActiveSupport `core_ext`
extensions that real-world Rails projects use most often.

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
  `#to`, `#extract!`, `#to_query`, `#to_param`, `#to_xml`, `#inquiry`
- `Hash` — `#deep_dup`, `#deep_merge`, `#deep_merge!`,
  `#symbolize_keys` / `#stringify_keys` (+ deep / bang variants),
  `#assert_valid_keys`, `#except!`, `#to_query`, `#to_param`,
  `#to_xml`, `#with_indifferent_access`, `#deep_transform_keys`
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

## Why a `sig/` bundle and not a `Rigor::Plugin::Base` subclass

The plugin authoring surface today exposes hooks for diagnostic
emission and per-call return-type contributions (`#diagnostics_for_file`,
`#flow_contribution_for`). It does NOT yet expose a hook for
"extend the RBS environment my analyzer queries against", which is
what an ActiveSupport-style core-extension plugin needs. Until
Rigor grows a plugin manifest entry for "extend `signature_paths`
when loaded", the simplest packaging is a `sig/` directory the
user wires in by hand. The gem still installs cleanly via Bundler;
only the wiring step is manual.

## Usage

`signature_paths:` entries are plain directory paths. `.rigor.yml` is
parsed with `YAML.safe_load_file` (see `Rigor::Configuration.load` /
`load_with_includes` in `lib/rigor/configuration.rb`) — there is **no
ERB rendering**, so a path cannot contain `<%= … %>` or any other
embedded Ruby. Relative entries are resolved against the directory of
the `.rigor.yml` file itself. Wire the bundle in one of two ways.

### Option A — point at the installed gem's `sig/`

Add to your `Gemfile` (typically the `:development` group):

```ruby
group :development do
  gem "rigortype", require: false
  gem "rigor-activesupport-core-ext", require: false
end
```

Find the gem's installed location:

```sh
bundle show rigor-activesupport-core-ext
```

Then put that absolute path (with `/sig` appended) in `.rigor.yml`:

```yaml
signature_paths:
  - sig
  - /absolute/path/from/bundle-show/rigor-activesupport-core-ext-x.y.z/sig
```

The gem path embeds the version, so this entry must be refreshed when
the gem is upgraded. Option B avoids that.

### Option B — vendor the `sig/` directory (portable, recommended)

Copy this bundle's `sig/` directory into your project repository and
reference the vendored copy with a relative path:

```sh
cp -R "$(bundle show rigor-activesupport-core-ext)/sig" vendor/rigor-activesupport-core-ext-sig
```

```yaml
# .rigor.yml at your project root
signature_paths:
  - sig
  - vendor/rigor-activesupport-core-ext-sig
```

This keeps the wiring stable across gem upgrades and across machines
(no absolute paths), at the cost of having to re-copy when you want
newer coverage.

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
- **Project-private monkey-patches are NOT covered.** A Rigor config
  knob for explicit pre-evaluation of project-side monkey-patches is
  the planned remediation; see the survey notes.
- **Coverage is "top ~40 selectors", not exhaustive.** ActiveSupport
  has hundreds of extension methods. PRs welcome.

## Not part of the core gem

This bundle sits under `plugins/` in the Rigor repository. It is
NOT shipped as part of the `rigortype` gem itself. The decision to
keep ActiveSupport coverage off-the-shelf-but-opt-in mirrors how
`rigor-rails-routes` / `rigor-actionpack` / `rigor-factorybot` /
`rigor-activerecord` / `rigor-activestorage` and the other Tier 2-3
Rails plugins are packaged: Rigor stays Rails-agnostic at its core
and the Rails-specific surface lives in opt-in plugins (or, in this
case, an opt-in RBS bundle).
