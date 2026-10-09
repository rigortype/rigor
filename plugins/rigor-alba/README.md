# rigor-alba

Recognises applications that use the [alba](https://github.com/okuramasafumi/alba)
JSON serializer. alba keeps its `sig/` in the repository but does not ship it in the gem, so in a user
project every alba method reads `Dynamic[top]`. The plugin contributes two things, and each only removes a
diagnostic or adds a root — it never adds a firing (issue #1682). It contributes no return types: `Alba.serialize(obj)`
runs the project's own `<Class>Resource#serialize`, which the project may override to return anything, and alba's RBS
declares `hashify`, `to_h` and `as_json` `untyped`.

1. **Block `self`.** `Alba.serialize(obj) { attributes :id }` and `Alba.hashify(obj) { ... }` `class_eval`
   the block on an anonymous `Class.new { include Alba::Resource }`. The DSL calls inside bind to
   `singleton(Alba::Resource)` (alba's own sig declares `[self: singleton(Resource)]`) instead of firing
   `call.unresolved-toplevel`.
2. **`rigor unused` roots.** A resource class body that says `many :articles` (also `one`, `has_many`,
   `has_one`, `association`) with no `resource:` makes alba load `ArticleResource` — or, failing that,
   `ArticleSerializer` — through `Alba.inflector`. That name appears nowhere in the source, so the class would
   be listed as unused. The plugin publishes it as a `:reachability_roots` fact.

> **Using this plugin?** The user guide lives in the manual at
> [docs/manual/plugins/rigor-alba.md](../../docs/manual/plugins/rigor-alba.md). This README covers the
> plugin's internals.

## What the plugin recognises

`demo/` is an app with an inline `Alba.serialize` / `Alba.hashify`, a resource whose `many :articles` and
`many :comments` carry no `resource:`, a namespaced `Admin::ReportResource`, and two resources nothing loads.
`rigor check` (run from `demo/`) prints only the coverage note, with no `call.unresolved-toplevel` row for the two
inline blocks (without the plugin it prints one per DSL call):

```text
.rigor.yml:1:1: info: 1 gem(s) in Gemfile.lock have no RBS available: alba. Consider `rbs collection install` to fetch community RBS from `ruby/gem_rbs_collection`, ship `sig/` in the gem itself, or opt the gem into `dependencies.source_inference:` in `.rigor.yml`. [rbs.coverage.missing-gem]
```

`rigor unused` (from `demo/`) lists the two resources nothing loads. `ArticleResource`,
`CommentSerializer` and `Admin::EntryResource` are not candidates — alba infers them from the `many` calls —
and `ReviewResource` is, because its association names `resource:` explicitly:

```text
Candidates — nothing reachable references these (2)
    1  OrphanResource    app/resources/orphan_resource.rb:3
    2  ReviewResource    app/resources/review_resource.rb:3
```

### Roots: what is and is not published

The inference mirrors `Alba::Association#resource_from` and `Alba.infer_resource_class`
(`lib/alba/association.rb`, `lib/alba.rb`). An association is considered only when alba would take the
inference path: a literal Symbol/String name, exactly one positional argument, no block, and no `resource:` or
`serializer:` keyword (a `**opts` splat could carry either, so it is skipped too). The name is classified with
`Rigor::Plugin::Inflector.classify` (ADR-39 — the real `ActiveSupport::Inflector`; when it is unavailable the
plugin publishes nothing rather than approximate).

alba then tries `<Nesting>::<X>Resource`, `<X>Resource`, `<Nesting>::<X>Serializer`, `<X>Serializer`, where
`<Nesting>` is the owning resource's namespace. The plugin publishes the first candidate that is a class the
project declares, and nothing otherwise — so a name no class matches can never become a root. An association
inside a `trait`, `nested`, `nested_attribute` or association block of the resource body is `class_eval`ed by alba
on an anonymous class, so only the top-level candidates are tried for it. A block of any other call (`each`, ...)
keeps the owner's nesting. Only classes
that include `Alba::Resource` (directly or through a project superclass) count as owners, which keeps
ActiveRecord's `has_many :articles` out.

## Layout

```text
plugins/rigor-alba/
├── README.md
├── sig/alba.rbs                          ← the two namespaces: Alba, Alba::Resource
├── lib/
│   ├── rigor-alba.rb
│   └── rigor/plugin/
│       ├── alba.rb                       ← manifest, dynamic_return rules, root publication
│       └── alba/
│           ├── resource_collector.rb     ← DeclarationWalk collector (classes, includes, associations)
│           ├── resource_discoverer.rb    ← walks resource_search_paths through IoBoundary
│           └── resource_index.rb         ← frozen index; the nesting-aware inference
└── demo/
    ├── .rigor.yml
    ├── .gitignore
    ├── Gemfile / Gemfile.lock            ← locks alba 3.10.0 (no runtime dependencies)
    ├── app/models/user.rb
    ├── app/resources/...
    └── demo.rb
```

## Running the demo

```sh
cd plugins/rigor-alba/demo
nix develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

and `rigor unused` in place of `rigor check` for the roots.

## Why a `sig/`

`Alba` is an unknown constant in a project that has no alba RBS, so it types as `Dynamic[top]` and neither a
`block_as_methods:` entry nor a receiver-gated rule can match it. `sig/alba.rbs` declares just the two
namespaces; both are `open_receivers:`, so no undeclared call on them is diagnosed. Declaring more would add
signatures alba's runtime may not honour, which is the false-positive direction this plugin refuses.

## Known limits

- The block `self` is bound where the engine evaluates a block as a statement or an assignment value
  (`json = Alba.serialize(x) { ... }`). A block on a call that is itself an argument of another call
  (`render json: Alba.serialize(x) { ... }`, `puts Alba.serialize(x) { ... }`) is not narrowed yet, so its DSL
  calls still read as `call.unresolved-toplevel`. That is the engine's operand-evaluation path, not something
  a plugin can supply.
- `resource_search_paths` (default `["app"]`) bounds both the classes that count as resources and the classes
  an inferred association may resolve to.

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... block_as_methods:)` | `Alba.serialize` / `Alba.hashify` block `self` (`singleton(Alba::Resource)`) |
| `manifest(... signature_paths:, open_receivers:)` | the two-namespace sig and its open surface |
| `Plugin::Base.producer :resource_index` | cached project scan, `watch:` on the search paths |
| `Inference::DeclarationWalk::Collector` | declaration context (`Module.nesting`-correct class names) without a bespoke walker |
| `#prepare` + `fact_store.publish` (ADR-9) | the `:reachability_roots` fact |
| `Plugin::Inflector` (ADR-39) | `classify` through the real ActiveSupport inflector |

## License

MPL-2.0, matching the parent Rigor project.
