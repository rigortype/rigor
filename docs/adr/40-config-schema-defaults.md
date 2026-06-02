# ADR-40 — `config_schema` declared defaults (`{kind:, default:}`)

Status: **Accepted, 2026-06-02.** The `{kind:, default:}` extended
`config_schema` value form + the `Manifest#config_defaults` accessor +
the `Plugin::Base#config` default-merge are implemented, with
`rigor-statesman` / `rigor-pundit` / `rigor-actioncable` (and further
plugins, incrementally) migrated off the `DEFAULT_*`-constant idiom.
Back-compatible: the bare-kind value form (`"key" => :string`) is
unchanged.

Records the decision to let a plugin's `config_schema` declare a
**default value** alongside the value kind, so the engine merges
declared defaults under the user config and the `DEFAULT_*`-constant +
`config.fetch("key", DEFAULT_KEY)` idiom — repeated in ~17 bundled
plugins — retires.

Grounding plan:
[`docs/design/20260602-plugin-boilerplate-reduction-plan.md`](../design/20260602-plugin-boilerplate-reduction-plan.md)
§ Phase 0d (the `config.fetch` + `DEFAULT_*` duplication, count 17).

## Context

A plugin's `Manifest` already carries a `config_schema:` that maps each
accepted config key to a value kind (`:string` / `:boolean` / `:integer`
/ `:array` / `:hash` / `:any`). `Manifest#validate_config` uses it to
reject unknown keys and kind-mismatched values when the loader reads
the user's `.rigor.yml` plugin config.

But the schema declares only the *kind*, never the *default*. So every
configurable plugin re-rolls the same two-part idiom — a `DEFAULT_*`
constant per key plus a `fetch`-with-default at read time:

```ruby
class Statesman < Rigor::Plugin::Base
  manifest(
    id: "statesman", version: "0.1.0",
    config_schema: {
      "dsl_method" => :string,
      "state_method" => :string,
      "transition_method" => :string
    }
  )

  DEFAULT_DSL_METHOD = "state_machine"
  DEFAULT_STATE_METHOD = "state"
  DEFAULT_TRANSITION_METHOD = "transition_to"

  def init(_services)
    @dsl_method = config.fetch("dsl_method", DEFAULT_DSL_METHOD).to_sym
    @state_method = config.fetch("state_method", DEFAULT_STATE_METHOD).to_sym
    @transition_method = config.fetch("transition_method", DEFAULT_TRANSITION_METHOD).to_sym
  end
end
```

The default lives **twice** — once conceptually in the schema (which
already names the key) and once as a free-standing constant the read
site must remember to thread through `fetch`. The schema is the natural
home for the default, the same way it is the home for the kind. This is
the Phase 0d duplication the boilerplate-reduction plan flagged.

## Working Decision

Extend the `config_schema` value form: a value MAY be either the
existing bare kind (`Symbol`/`String`) **or** a `Hash` carrying `kind:`
(required) and an optional `default:`.

```ruby
config_schema: {
  "dsl_method"        => { kind: :string, default: "state_machine" },
  "state_method"      => { kind: :string, default: "state" },
  "transition_method" => { kind: :string, default: "transition_to" }
}
```

- `Manifest` parses each value into two frozen maps: the existing
  `config_schema` kind map (`{ "key" => :kind }`, **unchanged shape** so
  `validate_config` / `to_h` / `==` keep working) and a new
  `config_defaults` map (`{ "key" => default }`, only for keys that
  declared a default).
- `Manifest#config_defaults` is a public reader (pinned in the
  public-API drift spec + RBS sig).
- A declared `default:` is validated against the declared `kind:` at
  manifest-construction time (reusing `value_matches?`), so a typo'd
  default (`default: 5` under `kind: :string`) fails loudly at load,
  not silently at use.
- `Plugin::Base#initialize` stores `manifest.config_defaults.merge(config)`
  (user config wins) as the frozen `#config`. A plugin therefore reads
  `config.fetch("dsl_method")` (or `config["dsl_method"]`) and gets the
  declared default with no `DEFAULT_*` constant and no second default
  argument. Coercions the plugin still wants (`.to_sym`, `Array(...)`)
  stay at the read site.

### Why this is back-compatible and FP-safe

- **Pure superset of the value grammar.** A bare-kind value
  (`"key" => :string`) parses exactly as before with no default
  recorded, so every existing manifest and every un-migrated plugin is
  untouched. `config_defaults` is `{}` for them and the merge is a
  no-op.
- **No new diagnostics, no inference change.** This is plugin-config
  ergonomics; it changes neither the type lattice nor any rule. It
  cannot introduce a false positive.
- **Cache-safe.** The persistent cache keys a plugin on
  `(id, version, user-config-hash)`
  ([`Cache::Descriptor::PluginEntry`](../../lib/rigor/cache/descriptor.rb)),
  not the manifest `to_h`. A default is part of the plugin's *code*
  (its version), so changing a default is a version bump like any other
  behaviour change — the existing keying already captures it. Adding
  `config_defaults` to `Manifest#to_h` affects only `Manifest#==` /
  `#hash`, never a cache key.

## Slices

1. **This ADR (mechanism + first consumers).** `Manifest` parsing +
   `config_defaults` reader + default-kind validation + `Base#config`
   merge + unit tests + drift/RBS pins. Migrate `rigor-statesman` /
   `rigor-pundit` / `rigor-actioncable` as the first consumers (the
   clean string / array-default cases).
2. **Remaining-plugin migration** — the other configurable bundled
   plugins (`activerecord` / `actionpack` / `actionmailer` / `sidekiq`
   / `rails-routes` / `rails-i18n` / `factorybot` / `sorbet` / …) move
   off `DEFAULT_*` incrementally, each behaviour-preserving against its
   golden-master integration spec. Pure cleanup, demand-driven.

## Relationship to other ADRs

- **ADR-2** — extends the `config_schema` field ADR-2 § "Registration,
  Configuration, and Caching" pins; the new value form is additive to
  that surface.
- **ADR-37 / ADR-38** — same "declarative manifest field the engine
  consumes at one well-defined site" model; here the site is
  `Base#config` rather than an inference gate.
- **Boilerplate-reduction plan Phase 0a–0e** — 0d, the sibling of the
  landed 0a (`Source::Literals`), 0b/0c (`Diagnostic.from_node` /
  `Base.suggest`), and 0e (`Plugin::Inflector`, ADR-39).

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| A separate `config_defaults:` manifest field (parallel to `config_schema:`) | Rejected | Splits one concept across two fields the author must keep in sync; the kind and the default belong to the same key, so the `{kind:, default:}` value keeps them together. |
| Keep the bare-kind form only; add defaults via a `defaults:` hash | Rejected | Same split-source problem; also leaves the schema able to name a key with no kind. |
| Deep-freeze default values (recursive) | Deferred | Defaults are scalars / shallow arrays the read sites copy (`Array(...).map`); a shallow freeze of the `config_defaults` map suffices. Revisit only if a mutable nested default is ever declared. |
| Coerce the merged value to the declared kind automatically (e.g. `:string` → `String()`) | Rejected | The read site already owns the coercion it wants (`.to_sym`, `Array()`); automatic coercion would surprise plugins that rely on the raw YAML value and is outside the "merge defaults" scope. |

## Consequences

Positive:

- Retires the `DEFAULT_*`-constant + `fetch`-with-default idiom across
  the configurable bundled plugins; the default is declared once, in
  the schema that already names the key.
- A declared default is validated against its kind at load, turning a
  silent wrong-typed default into a loud manifest error.
- Tiny additive surface: one extended value form, one reader, one merge
  line in `Base#initialize`. No new hook, no inference change.

Negative:

- Two accepted value forms in `config_schema` (bare kind / `{kind:,
  default:}`) is marginally more grammar to document — mitigated by the
  bare form staying the simplest case and the validation message
  naming the expected shape.
- A plugin that *wants* a key with no default but a non-nil
  "unset" sentinel still reads `config["key"]` → `nil`; the default
  mechanism does not model "required key" (that remains
  `validate_config`'s unknown-key / kind job). No plugin needs this
  today.
