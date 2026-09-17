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

`object` types to a model only where TWO independent things agree: the
`<Model>Serializer` naming convention resolves to exactly one model
`rigor-activerecord` discovered, AND that model answers every name the
serializer reads off its resource. A `model_overrides` entry short-circuits
both. Everything else declines. Running the demo:

```text
app/serializers/errors_serializer.rb:11:23: error: undefined method `nickname' for String [call.undefined-method]
app/serializers/probe_serializer.rb:10:13: info: dump_type: Account [dump.type]
app/serializers/probe_serializer.rb:11:13: info: dump_type: String [dump.type]
app/serializers/probe_serializer.rb:20:13: info: dump_type: Dynamic[top] [dump.type]
```

The two middle lines are the derivation and what it buys: `object` is
`Account`, so `object.username` is the `accounts.username` column's
`String`. The last is `Probe::NothingSerializer`, whose name resolves to
no model. The first is why the derivation is worth having at all — with a
checked type under `object`, a bogus call below it is an error rather
than a shrug.

The demo also carries `REST::ConversationSerializer`, a copy of
Mastodon's: its name resolves to the real `Conversation` model and its
resource is an `AccountConversation`, so the surface check declines it.

## Layout

```text
plugins/rigor-active-model-serializers/
├── README.md
├── lib/
│   ├── rigor-active-model-serializers.rb          # gem entry point
│   └── rigor/plugin/
│       ├── active_model_serializers.rb            # manifest + the dynamic_return rule
│       └── active_model_serializers/
│           ├── serializer_discoverer.rb           # the walk, the closure, the per-class facts
│           └── serializer_index.rb                # the discovered set
├── sig/
│   └── active_model_serializers.rbs               # the gem's framework constants
└── demo/
    ├── .rigor.yml
    ├── app/models/{account,conversation}.rb
    ├── app/serializers/{probe,errors}_serializer.rb
    ├── app/serializers/rest/{account,conversation}_serializer.rb
    └── db/schema.rb
```

## Running the demo

```sh
cd plugins/rigor-active-model-serializers/demo
RUBYLIB=$PWD/../lib bundle exec rigor check
```

The demo enables `rigor-activerecord` alongside, because the model index
is both what resolves the name and what the serializer is checked against.

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(config_schema:)` | `serializer_search_paths`, `serializer_base_classes`, `model_overrides` |
| `manifest(consumes:)` | `rigor-activerecord`'s `:model_index`, optional (ADR-9) |
| `manifest(signature_paths:)` | the bundled `sig/active_model_serializers.rbs` (ADR-25) |
| `manifest(open_receivers:)` | keeps every declared class and module lenient (ADR-26) |
| `producer(watch:)` | the serializer index, invalidated by the searched trees |
| `IoBoundary#read_file` / `#directory?` | the discoverer's project reads |
| `dynamic_return(methods:)` | the receiver-independent `object` rule (ADR-52 WD2) |
| `Scope#self_type` | the lexical gate — which serializer is `self` here? |
| `Scope#user_def_through_ancestors` | an explicit `def object`, and the model's own Ruby methods |
| `read_fact` | the cross-plugin model set |

## Why the model has to answer, not merely exist

The naming convention is a guess, and the model index only proves the
guessed class EXISTS. The first version of this plugin stopped there, and
was wrong on three Mastodon serializers while producing a byte-identical
diagnostic set — an Active Record model's surface is open, so a
wrong-but-real model absorbs every read in silence. A corpus diff is not
evidence that a contributed type is correct.

So `SerializerDiscoverer` records, per class, the names the serializer
will read off its resource: the `attributes` / `attribute` / `has_many` /
`has_one` / `belongs_to` symbols it does not define itself, plus every
`object.<name>` in its body, minus the methods every `Object` has (which
say nothing about which class the resource is). The model must answer all
of them, from its `:model_index` row or from a project `def` the ancestor
walk finds. Requiring all rather than most is deliberate: a decorator
around a model shares most of the model's surface, and the one or two
extra names are exactly what say so.

## Why the ancestry closure, and why there is no name fallback

`SerializerDiscoverer` records every `class X < Y` under the search paths
and closes the graph from `ActiveModel::Serializer` downwards, so a
project base serializer counts its subclasses in. Membership of that
closure is the ONLY serializer gate. An earlier version also admitted any
class whose name ended with `Serializer`, which typed `object` inside a
`Json::ConversationSerializer` with no serializer ancestry and an `object`
method of its own, erasing a true positive. `object` is an ordinary method
name; the suffix is not evidence.

That is why `app/lib` is in the default `serializer_search_paths`. The
closure can only reach a base serializer it has parsed, and Mastodon's
`ActivityPub::Serializer` — the parent of 60 of its 153 serializers — is at
`app/lib/activitypub/serializer.rb`. Measured index size there: 108
serializers with `["app/serializers"]` alone, 173 with `app/lib` added.

## Not covered

- **SimpleForm inputs.** `SimpleForm::Inputs::Base#object` shares the
  name and nothing else: its resource is named by the `simple_form_for`
  call site, not by the input class. A different gem, a different
  derivation, and a `rigor-simple-form` that does not exist yet.
- **`serializer:` / `each_serializer:` options.** They say which
  serializer renders an association, never which model a serializer
  serializes.
- **Model surface the index cannot see.** `delegate`, an association
  declared in a concern's `included do`, and attachment macros are all
  things the model answers and the `:model_index` fact does not carry, so
  a serializer reading one is declined. That fold belongs in
  `rigor-activerecord`; the note records which Mastodon serializers it
  would recover.

## Related

- [`docs/notes/20260917-ams-object-recognizer.md`](../../docs/notes/20260917-ams-object-recognizer.md)
  — the Mastodon before/after, the three wrong derivations the first
  version made, and the reach numbers.
- [ADR-26](../../docs/adr/26-activerecord-relation-typing.md) — the
  `open_receivers:` contract the bundled signature depends on.
- [ADR-52](../../docs/adr/52-compiled-plugin-contribution-dispatch.md) —
  the `dynamic_return` gate this rule is compiled into.

## License

MPL-2.0, matching the parent Rigor project.
