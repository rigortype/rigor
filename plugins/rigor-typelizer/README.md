# rigor-typelizer

Roots the serializer classes that [typelizer](https://github.com/skryukov/typelizer) generates TypeScript
interfaces from, so `rigor unused` does not list them as removal candidates (issue #1704). It contributes no
diagnostic and no type: it only adds roots.

typelizer's `Typelizer.target_serializers` (`lib/typelizer.rb`) is `base_classes + base_classes.flat_map(&:descendants)`,
and `Typelizer::DSL.included` / `.extended` (`lib/typelizer/dsl.rb`) add `base.to_s` to `base_classes` when the
class has a name. A class that does `include Typelizer::DSL` or `extend Typelizer::DSL`, and each of its
subclasses, therefore becomes a TypeScript interface that the frontend uses without Ruby ever naming the class.

> **Using this plugin?** The user guide lives in the manual at
> [docs/manual/plugins/rigor-typelizer.md](../../docs/manual/plugins/rigor-typelizer.md). This README covers the
> plugin's internals.

## What the plugin recognises

`demo/` is an app with a DSL base class, a subclass, an `extend`-ing class, a compact-header subclass, a plain
class, a module that includes the DSL, and a DSL class outside `dirs`. `rigor unused` (from `demo/`) lists only
the four that typelizer does not generate an interface for:

```text
Candidates — nothing reachable references these (4)
    1  ModuleUser         app/serializers/shared_fields.rb:9
    2  PlainFormatter     app/serializers/plain_formatter.rb:4
    3  SharedFields       app/serializers/shared_fields.rb:5
    4  StraySerializer    app/lib/stray_serializer.rb:4
```

`ApplicationSerializer`, `UserSerializer`, `EventSerializer` and `Admin::ReportSerializer` are roots. Without the
plugin all eight are candidates. `rigor check` prints only the coverage note: the plugin adds no diagnostic.

### What is and is not published

- A class declared in a file under `dirs` whose own body says `include Typelizer::DSL` or
  `extend Typelizer::DSL` (also `::Typelizer::DSL`, and among several arguments).
- Every project class whose superclass chain reaches such a class. The superclass is resolved as Ruby does, against
  the `Module.nesting` of the class header, so a compact `class Admin::X < Base` looks `Base` up lexically and
  not under `Admin`.
- **Not** a `module` that includes the DSL, and **not** a class that includes such a module. `DSL.included`
  registers the module's own name, `target_serializers` then calls `.descendants` on it (a `Module` has no such
  method), and the hook never runs for a class that only includes the module. Neither yields an interface, and a
  spurious root would hide a dead class.
- **Not** a DSL call inside `class << self`, and not a class outside `dirs`.

## Layout

```text
plugins/rigor-typelizer/
├── README.md
├── lib/
│   ├── rigor-typelizer.rb
│   └── rigor/plugin/
│       ├── typelizer.rb                    ← manifest, root publication
│       └── typelizer/
│           ├── serializer_collector.rb     ← DeclarationWalk collector (classes, DSL include/extend)
│           ├── serializer_discoverer.rb    ← walks dirs through IoBoundary
│           └── serializer_index.rb         ← frozen index; the superclass-chain walk
└── demo/
    ├── .rigor.yml
    ├── .gitignore
    ├── Gemfile / Gemfile.lock              ← locks typelizer 0.14.0
    ├── app/serializers/...
    └── demo.rb
```

## Running the demo

```sh
cd plugins/rigor-typelizer/demo
nix develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor unused
```

## Known limits

- `reject_class` is a runtime lambda in typelizer's configuration and is not modelled. A rejected class is still
  rooted: a hidden candidate, never a false finding.
- `dirs` (default `["app/resources", "app/serializers"]`, what `Typelizer::Railtie` sets when `dirs` is empty)
  bounds both the classes that count and the superclasses followed. A DSL base declared outside `dirs` roots
  nothing below it.
- Only the static header and body are read: a conditional `include`, a DSL applied through `send` or a
  metaprogrammed macro is not seen.
- typelizer's `writer` configuration may select files per writer; every writer is treated alike.

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `Plugin::Base.producer :serializer_index` | cached project scan, `watch:` on `dirs` |
| `Inference::DeclarationWalk::Collector` | `Module.nesting`-correct class names without a bespoke walker |
| `#prepare` + `fact_store.publish` (ADR-9) | the `:reachability_roots` fact |

## License

MPL-2.0, matching the parent Rigor project.
