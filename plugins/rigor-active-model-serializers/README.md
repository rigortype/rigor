# rigor-active-model-serializers

Types the implicit-self `object` reader inside an ActiveModel::Serializer
subclass as the model the serializer serializes, and declares the gem's
own framework constants.

> **Using this plugin?** The user guide — what `object` resolves to, when
> it declines, and the configuration — lives in the manual at
> [docs/manual/plugins/rigor-active-model-serializers.md](../../docs/manual/plugins/rigor-active-model-serializers.md).
> This README covers the plugin's internals.

The plugin emits **no diagnostic**. Its whole contribution is one
`dynamic_return` rule plus a bundled `sig/`, which puts it in the same
family as [`rigor-railties`](../rigor-railties/) and
`rigor-actionpack`'s Phase 5 request-context readers: a reader that a
real application calls constantly, typed from its lexical context so the
chain below it stops dispatching on `Dynamic`.

## What the plugin recognises

`object` types to a model where — and only where — something outside the
serializer corroborates the derivation:

1. a `model_overrides` entry names the model for that serializer, or
2. the `<Model>Serializer` naming convention resolves against a model
   `rigor-activerecord` published in its `:model_index` fact.

Everything else declines, and `object` keeps `Dynamic`. Running the demo:

```text
demo.rb:8:11: info: dump_type: Dynamic[top] [dump.type]
demo.rb:16:11: info: dump_type: Account [dump.type]
demo.rb:17:11: info: dump_type: String [dump.type]
errors_demo.rb:8:17: error: undefined method `nickname' for String [call.undefined-method]
```

The first line is `ProbeSerializer`, which has no `Probe` model.
The second and third are the derivation and what it buys: `object` is
`Account`, so `object.username` is the `accounts.username` column's
`String`. The fourth is why the derivation is worth having at all — with
a checked type under `object`, a bogus call below it is an error rather
than a shrug.

## Layout

```text
plugins/rigor-active-model-serializers/
├── README.md
├── lib/
│   ├── rigor-active-model-serializers.rb          # gem entry point
│   └── rigor/plugin/
│       ├── active_model_serializers.rb            # manifest + the dynamic_return rule
│       └── active_model_serializers/
│           ├── serializer_discoverer.rb           # app/serializers walk, ancestry closure
│           └── serializer_index.rb                # the discovered set
├── sig/
│   └── active_model_serializers.rbs               # the gem's framework constants
└── demo/
    ├── .rigor.yml
    ├── app/models/{account,status}.rb
    ├── app/serializers/rest/{account,context}_serializer.rb
    ├── db/schema.rb
    ├── demo.rb
    └── errors_demo.rb
```

## Running the demo

```sh
cd plugins/rigor-active-model-serializers/demo
RUBYLIB=$PWD/../lib bundle exec rigor check
```

The demo enables `rigor-activerecord` alongside, because the model index
is what the naming convention is checked against.

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(config_schema:)` | `serializer_search_paths`, `serializer_base_classes`, `model_overrides` |
| `manifest(consumes:)` | `rigor-activerecord`'s `:model_index`, optional (ADR-9) |
| `manifest(signature_paths:)` | the bundled `sig/active_model_serializers.rbs` (ADR-25) |
| `manifest(open_receivers:)` | keeps every declared class lenient (ADR-26) |
| `producer(watch:)` | the serializer index, invalidated by the `app/serializers` tree |
| `IoBoundary#read_file` / `#directory?` | the discoverer's project reads |
| `dynamic_return(methods:)` | the receiver-independent `object` rule (ADR-52 WD2) |
| `Scope#self_type` | the lexical gate — is `self` a serializer here? |
| `read_fact` | the cross-plugin model set |

## Why the ancestry closure, and why the name fallback stays

`SerializerDiscoverer` records every `class X < Y` under the search paths
and then closes the graph from `ActiveModel::Serializer` downwards, so a
project base serializer counts its subclasses in. Mastodon is the case
that forces it: 60 of its 153 serializers descend through
`ActivityPub::Serializer` and never name `ActiveModel::Serializer`
themselves, so a direct-superclass match (the shape `rigor-pundit`'s
policy discoverer uses) would have missed two fifths of them.

The `*Serializer` name-convention fallback survives the closure for
serializers outside `serializer_search_paths` — the same construction,
and the same argument, as `rigor-actionpack`'s `controller_scope?`.
Neither gate is the one that prevents a wrong answer; the model index is.

## Not covered

- **SimpleForm inputs.** `SimpleForm::Inputs::Base#object` shares the
  name and nothing else: its resource is named by the `simple_form_for`
  call site, not by the input class. A different gem, a different
  derivation, and a `rigor-simple-form` that does not exist yet.
- **`serializer:` / `each_serializer:` options.** They say which
  serializer renders an association, never which model a serializer
  serializes.
- **Attribute validation.** AMS resolves an `attributes :foo` name
  against a method on the serializer OR a method on the object, so a
  name absent from both is still not provably wrong.

## Related

- [`docs/notes/20260917-ams-object-recognizer.md`](../../docs/notes/20260917-ams-object-recognizer.md)
  — the Mastodon before/after that shipped it.
- [ADR-26](../../docs/adr/26-activerecord-relation-typing.md) — the `open_receivers:`
  contract the bundled signature depends on.
- [ADR-52](../../docs/adr/52-compiled-plugin-contribution-dispatch.md) — the
  `dynamic_return` gate this rule is compiled into.

## License

MPL-2.0, matching the parent Rigor project.
