# rigor-railties — the Rails framework core as an effect vocabulary

Unlike every other plugin in this tree, `rigor-railties` emits no
diagnostic, types no receiver and declares no producer. It exists for
one job: to carry the part of Rails' effect vocabulary that belongs to
no single component gem — the cache, the logger, the environment, the
configuration, the credentials — and to name the entry-point preset
`effects.snapshot.reach:` adopts.

It is inert unless the project has an `effects:` block in `.rigor.yml`.
See [ADR-103](../../docs/adr/103-effect-labels.md) for what effect
labels are and [`docs/internal-spec/plugin.md`](../../docs/internal-spec/plugin.md)
§ Effect contributions for the manifest surface it uses.

```yaml
plugins:
  - rigor-railties
  - rigor-activerecord
  - rigor-activejob
  - rigor-actionmailer
  - rigor-actionpack

effects: {}
```

## Effects

Every row below is a **receiver path** — the receiver expression as the
programmer wrote it — because that is the only stable handle there is:
`Rails.cache` returns whatever `config.cache_store` names and
`Rails.logger` whatever the app assigned, so neither has a class a row
could key on.

| Call | Transport | Meaning |
| --- | --- | --- |
| `Rails.cache.read` / `fetch` / `exist?` / `read_multi` | `io` | `cache.read` |
| `Rails.cache.write` / `delete` / `increment` / `clear` / … | `io` | `cache.write` |
| `Rails.logger.*`, a receiver-less `logger` inside a Rails class | `io` | `telemetry` |
| `Rails.error.report` / `handle` / `record` | `io` | `telemetry` |
| `Rails.env`, `Rails.root`, `Rails.configuration.*`, `Rails.application.config.*` | `global.read` | `rails.config.read` |
| `Rails.application.credentials.*`, `secrets` | `io.fs.read` + `global.read` | `rails.credentials.read` |
| `Rails.application.reload_routes!`, `Rails.autoloaders.main.reload`, `establish_connection` | `global.write` + `mutate.static` | — |

### Why `Rails.env` is `global.read`

Because `Rails.env = "test"` is a real thing people do, and a value
memoised from `Rails.env` in a class loaded before boot finishes is a
real bug. The label is honest; `tolerated: [rails.config.read]` is how
a project makes it quiet. That split — a true record and a quiet
judgment — is the mechanism working as designed, and it is why the
*meaning* label matters more here than the transport.

### `Rails.cache.fetch`'s block

Nothing special. A block literal always joins the enclosing method's
summary by containment ([ADR-103](../../docs/adr/103-effect-labels.md)
WD4), so whatever the cache-miss path does shows up in the caller
whether the block runs or not.

## The `rails` entry-point preset

`reach:` names the methods whose *transitive* footprint the snapshot
records. In a Rails app the honest answer is "everything the outside
world can enter through", and the layout is the ancestry:

```yaml
effects:
  snapshot:
    reach: [rails]
```

expands to `app/controllers/**/*.rb`, `app/jobs/**/*.rb`,
`app/mailers/**/*.rb` and `app/channels/**/*.rb`. Each component plugin
also ships its own slice — `rails-controllers`, `rails-jobs`,
`rails-mailers`, `rails-channels` — for a project that wants one
layer's footprint rather than all four.

A preset name may be registered once, with one glob set; `rails` spans
four directories owned by four different plugins, so exactly one plugin
has to declare the union, and this is that plugin.

## Illustrative layer conventions — documentation, never enforced

[ADR-103](../../docs/adr/103-effect-labels.md) WD10 is explicit that
the stanza below ships as an **example** and is never applied by
default. Whether a project adopts any of it is the project's call, and
adopting it wholesale on day one is the wrong move: run
`rigor effects` first, read what the app actually does, and then write
the bounds you mean.

```yaml
effects:
  envelopes:
    # A presenter builds strings. It may read configuration and
    # translate; it may not query, enqueue or send.
    - match: "app/presenters/**/*.rb"
      effect: [mutate.local, rails.config.read, rails.i18n.translate]
    - match: "app/serializers/**/*.rb"
      effect: [mutate.local, rails.config.read, rails.i18n.translate]
    - match: "app/decorators/**/*.rb"
      effect: [mutate.local, rails.config.read, rails.i18n.translate]

    # A policy answers a question. Reading to answer it is fine;
    # writing is not.
    - match: "app/policies/**/*.rb"
      effect: [io.db.read, rails.config.read]

    # A model may do most things — so that the day one starts calling
    # `Net::HTTP` directly, the report says so.
    - match: "app/models/**/*.rb"
      effect: [io.db, mutate, nondet, telemetry, rails.activejob.enqueue, email.send]

    # A job is the thing that is allowed to talk to the world.
    - match: "app/jobs/**/*.rb"
      effect: [io]

    - match: "db/migrate/**/*.rb"
      effect: [io.db]

  # Without this, a stanza like the above is honest and unactionable:
  # every controller action logs, and every one of them reads
  # `Rails.env` somewhere down the stack.
  tolerated: [telemetry, rails.config.read]

  snapshot:
    reach: [rails]
```

`app/controllers/**` is deliberately absent: an action is where
everything is permitted to happen, and bounding it says nothing.

## What this plugin does not do

- **No diagnostics.** `effect.envelope-exceeded` comes from the engine,
  from bounds the *project* wrote, and only when `effects.check` is on.
- **No ActiveSupport purity.** The `%a{pure}` sweep over `blank?` /
  `present?` / `try` and the rest of the core_ext predicate surface
  belongs to
  [`rigor-activesupport-core-ext`](../rigor-activesupport-core-ext/),
  which also carries the clock, the notification bus and
  `ActiveSupport::CurrentAttributes`.
- **No views.** `render` keeps a `template-not-analysed` taint until
  templates become effect units.
