# 12. Lightweight HKT (`JSON.parse` and friends)

`JSON.parse(str)` returns "some JSON value": `nil`, a bool, a
number, a string, an array of JSON values, or a hash of JSON
values. RBS describes that as `untyped` because there is no way
to spell a recursive sum type without quantifying over a type
constructor. Most type checkers shrug and let `JSON.parse(str)`
fade into `Dynamic[Top]`.

Rigor models it precisely:

```ruby
parsed = JSON.parse('{"name": "Alice"}')
assert_type(parsed,
  "Array[json::value[String]] | Float | " \
  "Hash[String, json::value[String]] | Integer | " \
  "String | false | nil | true")
```

The mechanism behind this — and the one that lets you wire the
same shape for your own DSL or stdlib method — is **Lightweight
HKT** ([ADR-20](../adr/20-lightweight-hkt.md)), Rigor's
defunctionalised encoding of higher-kinded types in the
[Yallop & White 2014](https://www.cl.cam.ac.uk/~jdy22/papers/lightweight-higher-kinded-polymorphism.pdf) /
[fp-ts `URItoKind`](https://github.com/gcanti/fp-ts/blob/master/src/HKT.ts)
style. This chapter walks through what it does, when to reach
for it, and how to author your own overlay.

## The five-second pitch

| Concept | Rigor spelling | Where you see it |
| --- | --- | --- |
| Type-constructor "tag" | Namespaced Symbol URI (`:json::value`, `:dry_monads::result`) | `%a{rigor:v1:hkt_register: uri=…}` directive |
| Abstract application `F<A>` | `Type::App[uri, args]` | Carrier in dispatcher output |
| Type-level definition | `%a{rigor:v1:hkt_define: uri=… params=… body=…}` directive | `.rbs` overlay file |
| Reducing `App[F, A]` to a real type | `env.hkt_registry.reduce(app)` (or `app.reduce(registry)`) | Called eagerly by the dispatcher tier for known stdlib methods |
| Hooking it to a method | `Builtins::HktBuiltins::METHOD_RETURN_OVERRIDES` table | Plugin / Rigor-bundled wiring |

The next sections show each of these in action.

## What's bundled today

Rigor ships one HKT registration out of the box: **`json::value[K]`**,
the recursive JSON-value sum. Two parts:

```rbs
# Registration — names the tag, declares its arity, variance,
# and erasure bound. The bound is what Rigor's RBS round-trip
# falls back to when reduction is blocked.
uri=json::value arity=1 variance=out bound=untyped

# Definition — the actual body, parameterised on K (the hash
# key type). Note the self-referential `App[json::value, K]`
# arms — Rigor's reducer handles recursion with lazy "tying-
# the-knot" semantics.
params=K body=
  nil | true | false | Integer | Float | String
  | Array[App[json::value, K]]
  | Hash[K, App[json::value, K]]
```

Eight stdlib methods route through this:

- `JSON.parse` / `JSON.parse!` / `JSON.load`
- `YAML.safe_load` / `YAML.safe_load_file`
- `Psych.safe_load` / `Psych.safe_load_file`

The HKT-builtin dispatcher tier sits ABOVE the standard RBS
dispatch, so even though upstream RBS declares
`JSON.parse: (string, ?options) -> untyped`, Rigor's answer is
the reduced Union. `YAML.load` / `YAML.unsafe_load` deliberately
stay out — they can return any Ruby object and have no useful
HKT envelope.

## Two kinds of call-site discrimination

The bundled overrides are not just `(receiver, method) → fixed
type`. Two **discriminators** look at the call's actual
arguments:

### `symbolize_names: true` swaps K

```ruby
JSON.parse(str)
# parsed: ... | Hash[String, json::value[String]] | ...

JSON.parse(str, symbolize_names: true)
# parsed: ... | Hash[Symbol, json::value[Symbol]] | ...
```

The `:json_symbolize_names` discriminator inspects the call's
second-argument `HashShape` for a literal `symbolize_names: true`
entry. Match swaps `K = String` for `K = Symbol` before the
reducer runs. Non-literal `symbolize_names: x` (a variable, a
non-`Constant<true>` value) stays on the default `String`
branch.

### `permitted_classes:` unions extra arms

```ruby
require "date"
parsed = YAML.safe_load(str, permitted_classes: [Date])
# parsed: ... | Date | ...
```

The `:yaml_permitted_classes` **post-reduce hook** runs after the
reducer and augments the result. It walks the second-argument
`HashShape` for a `permitted_classes:` key whose value is a
literal `Tuple` or `Array` of Singleton classes, maps each to a
`Nominal`, and unions them with the base `json::value` Union.
`[Date, Symbol]` adds both arms.

Non-literal `permitted_classes:` values (a variable, a `Dynamic`,
a non-Singleton element) silently no-op so Rigor never invents
classes it can't statically see.

## Authoring your own overlay

You can register your own HKT URIs in a `.rbs` file under your
`signature_paths:`. The annotations attach to a class or module
declaration (RBS's annotation grammar requires that):

```rbs
%a{rigor:v1:hkt_register: uri=my_app::box arity=1 variance=out bound=untyped}
%a{rigor:v1:hkt_define: uri=my_app::box params=K body=K | nil}
class MyAppBoxOverlay
end
```

A few rules:

- **URIs MUST be namespaced** (`<author>::<name>`). The `::`
  separator prevents cross-plugin collisions per ADR-20 WD1.
- **The payload format is space-separated `key=value` pairs.**
  RBS's `%a{...}` annotation grammar rejects quotes, so JSON
  payload won't work — the kv-form is what RBS will actually
  deliver.
- **`body=` is special-cased to gobble everything to the end** of
  the payload, so the body string can contain spaces, `|`, `[]`
  etc. without escaping.
- **`params=` is a comma-separated list** of UCName identifiers
  (`params=K` or `params=T,E`).
- **`bound=` accepts `untyped` (default) or a bare class name**.
  Richer bound forms (parameterised generics, unions,
  refinements) wait for a follow-up slice's expression parser.

When `Environment.for_project` builds the env, it scans the
loaded RBS for these annotations and merges them into
`env.hkt_registry` on top of the bundled builtins. Last-write-
wins on URI collisions so an overlay can override `json::value`
if you want to.

## The body grammar

`body=` is parsed by `HktBodyParser` into a tree the reducer
walks. The minimum-viable grammar (sufficient for `JSON.parse`'s
recursive sum and similar recursive-data-shape signatures):

| Form | Example | Meaning |
| --- | --- | --- |
| Atom | `nil` / `true` / `false` / `bool` / `untyped` | Constants and the `Dynamic[Top]` carrier |
| Nominal class | `Integer` / `String` / `Foo::Bar` / `::String` | `Nominal[class_name]` |
| Param reference | `K`, `T`, `E` (when in `params`) | Substituted at reduction time |
| Parameterised nominal | `Array[K]`, `Hash[K, V]` | `Nominal[..., type_args: [...]]` |
| Lightweight HKT application | `App[json::value, K]` | Another `Type::App` carrier, reduced lazily |
| Union | `A \| B \| C` | `Type::Union` (normalised) |

Disambiguation: a UCName matching one of `params` becomes a
`Param` node, **unless** it's followed by `::` (qualified class
continuation) or `[` (parameterised app), in which case it's
treated as a nominal. So `K` is a param ref, `K[X]` is the
class `K` applied to `X`.

## Reduction semantics — lazy "tying-the-knot"

The interesting part: `json::value`'s body contains
`Array[App[json::value, K]]` — a SELF-REFERENCE. A naive
recursive reducer would infinite-loop.

Rigor's reducer carries an **in-progress stack** keyed on
`(uri, reduced_args)`. When evaluating an `AppRef` whose
`(uri, args)` matches something already on the stack, it
returns the in-progress `Type::App` carrier as-is — lazily,
without unfolding. The standard fix-point trick for recursive
type aliases.

So reducing `App[json::value, [String]]` produces:

```
Union[ nil, true, false, Integer, Float, String,
       Array[ Type::App[json::value, [String]] ],  ← carrier left intact
       Hash[ String, Type::App[json::value, [String]] ] ]
```

The nested `Type::App` is a normal Rigor type; downstream
consumers (acceptance, narrowing, dispatch) handle it by
delegating to its `bound` (default `Dynamic[Top]`). If they
need one more level of unfolding, they call
`app.reduce(env.hkt_registry)` again — but the typical
consumer doesn't need to.

A **fuel budget** (default 64 reduction steps per call-site
evaluation) bounds runaway expansion. Exhaustion unwinds to
`app.bound`.

## What it doesn't do (yet)

Lightweight HKT is, well, lightweight. Conscious non-goals:

- **Conditional / indexed-access bodies** (`E <: T ? A : B`,
  `E in [k1, k2]`) — drafted in ADR-20 § D3 but not yet
  implemented. The `rigor-lisp-eval` demo's
  `lisp_type[E]` body needs this; it stays on the
  diagnostic-emitter path until the conditional grammar
  ships.
- **Multi-arg HKTs for non-recursive containers**
  (`Result[T, E]` / `Maybe[T]`) — the registry supports
  multi-arg URIs, but Rigor's existing carriers don't have
  the sealed-union shape `Result` needs (ADR-3 amendment is
  the gating piece).
- **Sugar syntax**. The explicit `%a{rigor:v1:hkt_register /
  hkt_define}` pair is the canonical form. A recursive
  `type alias` shorthand is a future option, gated on user
  feedback that the explicit form is too verbose.
- **Plugin-side resolver hookup**. Plugins can't yet register
  HKT URIs through their manifests; today only Rigor-bundled
  registrations and user `.rbs` overlays populate the
  registry.

If you hit one of these, ADR-20's § Implementation slicing
menu names the slice that addresses it.

## Where to look in the code

| Layer | Location |
| --- | --- |
| Carrier | [`lib/rigor/type/app.rb`](../../lib/rigor/type/app.rb) |
| Registry value objects | [`lib/rigor/inference/hkt_registry.rb`](../../lib/rigor/inference/hkt_registry.rb) |
| Body tree node types | [`lib/rigor/inference/hkt_body.rb`](../../lib/rigor/inference/hkt_body.rb) |
| Reducer (lazy self-ref + fuel) | [`lib/rigor/inference/hkt_reducer.rb`](../../lib/rigor/inference/hkt_reducer.rb) |
| Body-string grammar parser | [`lib/rigor/inference/hkt_body_parser.rb`](../../lib/rigor/inference/hkt_body_parser.rb) |
| Directive parser (`hkt_register` / `hkt_define`) | [`lib/rigor/rbs_extended/hkt_directives.rb`](../../lib/rigor/rbs_extended/hkt_directives.rb) |
| Bundled `json::value` + `METHOD_RETURN_OVERRIDES` | [`lib/rigor/builtins/hkt_builtins.rb`](../../lib/rigor/builtins/hkt_builtins.rb) |
| Dispatcher tier | [`lib/rigor/inference/method_dispatcher.rb`](../../lib/rigor/inference/method_dispatcher.rb) (`try_hkt_builtin_return`) |
| Environment integration | [`lib/rigor/environment.rb`](../../lib/rigor/environment.rb) (`#hkt_registry` + `HktRegistryHolder`) |
| RBS scan | [`lib/rigor/environment/rbs_loader.rb`](../../lib/rigor/environment/rbs_loader.rb) (`each_class_decl_annotation`) |

## What's next

If you came here from a "where does JSON.parse get its type
from?" question, the rest of the handbook covers the surrounding
machinery:

- [Chapter 2 — Everyday types](02-everyday-types.md) for the
  carrier zoo the reducer outputs.
- [Chapter 7 — RBS and `RBS::Extended`](07-rbs-and-extended.md)
  for the broader annotation grammar (`%a{rigor:v1:return:}`,
  `%a{rigor:v1:predicate-if-true:}`, …) the HKT directives
  sit alongside.
- [Appendix — Connections to type theory](appendix-type-theory.md)
  § "What Rigor does NOT model" for the formal-type-theory
  context that explains why Rigor adopted the lightweight
  encoding rather than real HKT.

If you want to author your own overlay end-to-end, the
worked example in
[`spec/rigor/environment_spec.rb`](../../spec/rigor/environment_spec.rb)
("ADR-20 HKT registry scan" context) is the smallest viable
reference — a fixture `.rbs` file with the directive pair, a
class declaration to anchor them on, and an `Environment.for_project`
call that surfaces the registration through `env.hkt_registry`.
