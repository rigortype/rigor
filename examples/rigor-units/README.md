# rigor-units — example Rigor plugin

A second worked example of the Rigor v0.1.0 plugin authoring
surface. While [`rigor-lisp-eval`](../rigor-lisp-eval/) shows
how to type a literal AST argument, `rigor-units` shows how to
**track types through the program** — propagating dimensional
types across local-variable assignments, method chains, and
arithmetic.

The plugin types a small units-of-measure DSL that extends
`Numeric` with constructor methods (`100.kilometers`,
`2.hours`) and propagates four dimensions through subsequent
operations:

| Dimension | Constructed by | Examples |
| --- | --- | --- |
| `Distance` | `.kilometers` / `.meters` / `.miles` / `.feet` | `100.kilometers`, `500.meters` |
| `Time` | `.seconds` / `.minutes` / `.hours` | `2.hours`, `5.seconds` |
| `Speed` | `Distance / Time`, `Distance.per_hour` | `distance / time`, `60.kilometers.per_hour` |
| `Acceleration` | `Speed / Time`, `Distance.per_second_squared` | `(v1 - v0) / dt`, `9.8.meters.per_second_squared` |

## What the plugin recognises

```text
demo.rb:13:1: info: local `distance` inferred as Distance [plugin.units.inferred-binding]
demo.rb:14:1: info: local `time` inferred as Time [plugin.units.inferred-binding]
demo.rb:17:1: info: local `total_distance` inferred as Distance [plugin.units.inferred-binding]
demo.rb:24:1: info: local `speed` inferred as Speed [plugin.units.inferred-binding]
demo.rb:26:6: info: `speed.in_kilometers_per_hour` returns Float (Speed → kilometers per hour) [plugin.units.in-method-result]
...
```

Dimensional mismatches surface as `error` diagnostics:

```ruby
distance = 100.kilometers
time     = 2.hours

distance + time
# error: dimensional mismatch: `Distance + Time` is not defined
#        [plugin.units.dimension-mismatch]

speed = distance / time
puts speed.in_meters
# error: Speed has no `.in_meters` query
#        (allowed: .in_meters_per_second, .in_kilometers_per_hour, .in_miles_per_hour)
#        [plugin.units.in-method-mismatch]

if distance <= time
# error: dimensional mismatch: `Distance <= Time` is not defined
#        [plugin.units.dimension-mismatch]
```

Recognised operations:

| Operation | Result |
| --- | --- |
| `Distance + Distance` / `Distance - Distance` | `Distance` |
| `Time + Time` / `Time - Time` | `Time` |
| `Speed + Speed` / `Speed - Speed` | `Speed` |
| `Distance / Time` | `Speed` |
| `Speed / Time` | `Acceleration` |
| `Speed * Time` / `Time * Speed` | `Distance` |
| `Acceleration * Time` / `Time * Acceleration` | `Speed` |
| `Distance.per_hour` / `.per_minute` / `.per_second` | `Speed` |
| `Distance.per_second_squared` (etc.) | `Acceleration` |
| `<dim> < <dim>` / `<= >= == != >` (matching dimensions) | `bool` |
| `<dim>.in_<unit>` (matching dimension) | `Float` |

## Layout

```
rigor-units/
├── README.md
├── rigor-units.gemspec
├── lib/
│   ├── rigor-units.rb
│   └── rigor/plugin/
│       ├── units.rb                ← manifest + diagnostics_for_file hook
│       └── units/
│           ├── method_table.rb     ← (receiver, method, args) → result dispatch
│           └── analyzer.rb         ← AST walker + local-binding map
└── demo/
    ├── .rigor.yml
    ├── demo.rb                     ← the user-facing example
    ├── lib/units.rb                ← runtime: Distance / Time / Speed / Acceleration
    └── sig/units.rbs               ← permissive RBS sigs (untyped today)
```

## Running the demo

```sh
cd examples/rigor-units/demo
RUBYLIB=$PWD/../lib bundle exec rigor check demo.rb
```

The plugin loader resolves `rigor-units` through `Kernel.require`;
with `RUBYLIB` set, that finds the in-repo source.

## Plugin authoring surface this exercises

Adds **AST flow analysis with local-variable binding tracking**
on top of the surfaces `rigor-lisp-eval` covered:

| Surface | Where in this plugin |
| --- | --- |
| Manifest declaration | `lib/rigor/plugin/units.rb` |
| `#diagnostics_for_file(path:, scope:, root:)` | walks the parsed root |
| Per-file analyzer state | `Analyzer` instance lives one-per-file |
| Local-variable binding map | `@bindings` Hash threaded through `evaluate` |
| Multi-pass evaluation | `evaluate(node, emit_terminal:)` distinguishes leaf vs. nested calls so chained `.in_*` only emits once per chain |
| Pure dispatch table | `MethodTable.dispatch` — separable, easily extended |

## What this plugin does NOT exercise

- **Path-sensitive flow.** A binding written inside an `if`
  branch leaks to the outer scope, mirroring the analyser's
  v0.0.x scope semantics. Real flow narrowing for
  plugin-authored bindings will land alongside the v0.1.x
  return-type contribution slice.
- **Method-body / class-body scoping.** The analyser is
  flat — every binding lives in one bag. Sufficient for
  top-level scripts; users adapting the plugin to a Rails app
  would extend `Analyzer` to push / pop scope frames at
  `Prism::DefNode` / `Prism::ClassNode` boundaries.
- **Cache producers / IoBoundary / TrustPolicy.** The dispatch
  table is in-memory and there is no I/O, so the plugin opts
  out of the cache surface.

## Future direction — lightweight HKT

The same future-shape note applies as to the Lisp example:
once Rigor grows a lightweight type-level computation surface
(conditional / indexed-access types per
[`docs/type-specification/rigor-extensions.md`](../../docs/type-specification/rigor-extensions.md) rows 22 / 51),
the dispatch table here becomes expressible directly in
`sig/units.rbs`:

```rbs
class Distance
  def +: (Distance) -> Distance
  def /: [T] (T) -> (T <: Time ? Speed : untyped)
end
```

When that lands, the plugin moves from emitting diagnostics to
producing `FlowContribution` bundles, the runtime and static
type function live in one declarative table, and the
`untyped`s in `demo/sig/units.rbs` collapse into precise
return types.

## License

MPL-2.0, matching the parent Rigor project.
