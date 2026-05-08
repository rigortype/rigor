# rigor-sorbet (slice 1)

The eighth worked example. Reads inline Sorbet `sig { ... }`
blocks on first-party Ruby code and contributes the parsed
return type at every call site, so chained calls
(`Slug.default_length.even?`) resolve through Rigor's normal
dispatch instead of degrading to `Dynamic[top]`.

This is **slice 1 of [ADR-11](../../docs/adr/11-sorbet-input-adapter.md)**.
The current cut covers method-signature contributions only;
later slices add the `T.let` / `T.cast` / `T.must` / `T.bind` /
`T.absurd` flow primitives, broaden the type-vocabulary
translator, walk Sorbet's RBI directories, and honour `# typed:`
sigils.

## What the plugin recognises

Given a method preceded by a `sig` block:

```ruby
class Slug
  extend T::Sig

  sig { params(name: String).returns(String) }
  def normalise(name)
    name.downcase.gsub(/\s+/, "-")
  end

  sig { returns(Integer) }
  def self.default_length
    32
  end
end
```

…the plugin lets call sites resolve through the parsed sig:

```text
slug = Slug.new
slug.normalise("Alice").upcase   # ✓ returns String, .upcase resolves
Slug.default_length.even?         # ✓ returns Integer, .even? resolves
```

Malformed sigs surface as `plugin.sorbet.parse-error` warnings:

```text
demo/errors_demo.rb:18:3: plugin.sorbet.parse-error
  Sorbet `sig` block must end in `.returns(...)` or `.void`.

demo/errors_demo.rb:25:3: plugin.sorbet.parse-error
  `sig` block is not immediately followed by a method definition.

demo/errors_demo.rb:34:3: plugin.sorbet.parse-error
  Two `sig` blocks in a row; the first one has no following method definition.
```

## Slice 1 type vocabulary

| Sorbet form         | Rigor representation                     |
| ------------------- | ---------------------------------------- |
| `Integer` etc.      | `Nominal["Integer"]`                     |
| `::Foo::Bar`        | `Nominal["Foo::Bar"]`                    |
| `T.untyped`         | `Dynamic[top]`                           |
| `T.anything`        | `top`                                    |
| `T.noreturn`        | `bot`                                    |
| `T.nilable(X)`      | `Union[X, Constant[nil]]`                |
| `T.any(A, B, ...)`  | `Union[A, B, ...]`                       |
| `T.all(A, B, ...)`  | `Intersection[A, B, ...]`                |
| `T::Boolean`        | `Union[Constant[true], Constant[false]]` |

Anything outside this table (`T.proc`, `T::Array[E]`,
`T.class_of`, `T::Struct`, …) currently degrades to
`Dynamic[top]` silently. Slice 3 of the ADR widens the
translator.

## Layout

```text
examples/rigor-sorbet/
├── README.md
├── rigor-sorbet.gemspec
├── lib/
│   ├── rigor-sorbet.rb
│   └── rigor/plugin/
│       ├── sorbet.rb               ← plugin entry: manifest, hooks, lookup
│       └── sorbet/
│           ├── method_signature.rb ← frozen value object
│           ├── catalog.rb          ← per-run signature table
│           ├── catalog_walker.rb   ← Prism walker, sig + def pairing
│           ├── sig_parser.rb       ← chained-call mini-interpreter
│           └── type_translator.rb  ← Sorbet → Rigor types
└── demo/
    ├── .rigor.yml
    ├── .gitignore
    ├── demo.rb                     ← runnable example, no errors
    └── errors_demo.rb              ← exercises parse-error warnings
```

## Running the demo

```sh
cd examples/rigor-sorbet/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

## Plugin authoring surface this exercises

| Surface                                    | Used for |
| ------------------------------------------ | -------- |
| `manifest(...)` + `config_schema`          | declares the optional `paths:` config knob |
| `Plugin::Base#io_boundary` (`read_file`)   | reads project source under the trusted scope when populating the catalog |
| `Plugin::Base#flow_contribution_for`       | contributes the parsed return type at every call site |
| `Plugin::Base#diagnostics_for_file`        | emits `plugin.sorbet.parse-error` for malformed sig blocks |
| `Scope#type_of` (via `flow_contribution_for`) | resolves instance-side receivers to `Nominal[T]` for catalog lookup |
| `Type::Combinator.{nominal_of,union,intersection,untyped,top,bot,constant_of}` | constructs the Rigor-side carriers from the Sorbet vocabulary |

## Future direction

Slice 2 of ADR-11 wires the `T.let` / `T.cast` / `T.must` /
`T.bind` flow assertions through the same `flow_contribution_for`
substrate as their `%a{rigor:v1:assert:}` analogues. Slice 3
broadens the type-vocabulary translator (`T.proc`, `T::Array`,
`T.class_of`, `T.attached_class`). Slice 4 adds the RBI
directory walker so `sorbet/rbi/{gems,annotations,dsl,shims}/`
contributes external types alongside ADR-10's opt-in
gem-source inference. Slice 5 honours `# typed:` sigils and
fixes the dispatcher tier ordering. Slice 6 wires `T.absurd`
into `flow.unreachable-branch`. Each slice lives behind its
own ADR-11-backed CHANGELOG entry; the contract surface this
slice ships is stable and won't be renamed.

## License

MPL-2.0, matching the parent Rigor project.
