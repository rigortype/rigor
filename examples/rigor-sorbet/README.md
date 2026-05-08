# rigor-sorbet (slices 1 + 2 + 3)

The eighth worked example. Reads inline Sorbet `sig { ... }`
blocks on first-party Ruby code and contributes the parsed
return type at every call site, so chained calls
(`Slug.default_length.even?`) resolve through Rigor's normal
dispatch instead of degrading to `Dynamic[top]`. As of slice 2,
also recognises Sorbet's type-assertion calls (`T.let` /
`T.cast` / `T.must` / `T.unsafe`) and lifts them to
`FlowContribution` return-type contributions. Slice 3 widens
the type-vocabulary translator to cover the dense middle of
Sorbet's surface — generic class applications (`T::Array[E]`,
`T::Hash[K, V]`, `T::Set[E]`, `T::Range[E]`, `T::Enumerable[E]`,
`T::Enumerator[E]`), class-object types (`T.class_of(C)`,
`T::Class[T]`), tuple literals `[A, B]` and shape literals
`{a: A, b: B}` in sig position.

This is **slices 1 + 2 + 3 of [ADR-11](../../docs/adr/11-sorbet-input-adapter.md)**.
Later slices walk Sorbet's RBI directories (slice 4),
honour `# typed:` sigils + finalise dispatcher tier ordering
(slice 5), and wire `T.absurd` into `flow.unreachable-branch`
(slice 6). `T.bind`, `T.assert_type!`, `T.must_because`, and
`T.reveal_type` remain deferred to a slice-2 follow-up.

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

Slice 2's assertion recogniser lifts `T.let` / `T.cast` /
`T.must` / `T.unsafe` to the same contribution shape:

```ruby
counter = T.let(0, Integer)         # counter: Integer (widened from Constant<0>)
counter.even?                        # ✓ resolves on Integer

T.cast(some_value, String).upcase    # ✓ String#upcase resolves

maybe = T.let(nil, T.nilable(Integer))
T.must(maybe).bit_length             # ✓ Integer#bit_length (nil stripped)

T.unsafe(opaque).any_method_at_all   # ✓ silenced — Dynamic[top]
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

## Slice 2 assertion forms

| Sorbet form           | Contribution                              |
| --------------------- | ----------------------------------------- |
| `T.let(expr, T)`      | return type ← translated `T`              |
| `T.cast(expr, T)`     | return type ← translated `T`              |
| `T.must(expr)`        | return type ← `inferred(expr) - nil`      |
| `T.unsafe(expr)`      | return type ← `Dynamic[top]`              |

`T.bind`, `T.assert_type!`, `T.must_because`, `T.absurd` and
`T.reveal_type` are deferred to a follow-up slice.

## Type vocabulary (slices 1 + 3)

| Sorbet form              | Rigor representation                     |
| ------------------------ | ---------------------------------------- |
| `Integer` etc.           | `Nominal["Integer"]`                     |
| `::Foo::Bar`             | `Nominal["Foo::Bar"]`                    |
| `T.untyped`              | `Dynamic[top]`                           |
| `T.anything`             | `top`                                    |
| `T.noreturn`             | `bot`                                    |
| `T.nilable(X)`           | `Union[X, Constant[nil]]`                |
| `T.any(A, B, ...)`       | `Union[A, B, ...]`                       |
| `T.all(A, B, ...)`       | `Intersection[A, B, ...]`                |
| `T::Boolean`             | `Union[Constant[true], Constant[false]]` |
| `T::Array[E]`            | `Nominal["Array", [E]]`                  |
| `T::Hash[K, V]`          | `Nominal["Hash", [K, V]]`                |
| `T::Set[E]`              | `Nominal["Set", [E]]`                    |
| `T::Range[E]`            | `Nominal["Range", [E]]`                  |
| `T::Enumerable[E]`       | `Nominal["Enumerable", [E]]`             |
| `T::Enumerator[E]`       | `Nominal["Enumerator", [E]]`             |
| `T::Class[T]`            | `Singleton[T-class-name]` (lossy)        |
| `T.class_of(C)`          | `Singleton[C]`                           |
| `[A, B]` (tuple in sig)  | `Tuple[A, B]`                            |
| `{a: A, b: B}` (shape)   | `HashShape{a: A, b: B}` (closed)         |

Anything outside this table (`T.proc`, `T.attached_class`,
`T.self_type`, `T.type_parameter`, `T::Struct` / `T::Enum`
subclasses, …) still degrades silently to `Dynamic[top]`.
Slice 4 of the ADR walks Sorbet's RBI directories (which
typically use the same vocabulary, so the same coverage
applies). Diagnostics flagging unsupported constructs land
in a later slice; the silent-degradation policy keeps the
signal-to-noise ratio high during the early adoption period.

## Layout

```text
examples/rigor-sorbet/
├── README.md
├── rigor-sorbet.gemspec
├── lib/
│   ├── rigor-sorbet.rb
│   └── rigor/plugin/
│       ├── sorbet.rb                  ← plugin entry: manifest, hooks, lookup
│       └── sorbet/
│           ├── method_signature.rb    ← frozen value object
│           ├── catalog.rb             ← per-run signature table
│           ├── catalog_walker.rb      ← Prism walker, sig + def pairing
│           ├── sig_parser.rb          ← chained-call mini-interpreter
│           ├── type_translator.rb     ← Sorbet → Rigor types
│           └── assertion_recognizer.rb ← T.let / T.cast / T.must / T.unsafe
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
