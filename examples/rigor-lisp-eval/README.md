# rigor-lisp-eval — example Rigor plugin

A worked example of the Rigor v0.1.0 plugin authoring surface.

The plugin types the return value of literal `Lisp.eval(...)`
calls — a tiny S-expression-style interpreter — by recursively
walking the AST argument and folding it through a static type
table. The inferred type surfaces as a diagnostic at every
call site:

```text
demo/demo.rb:3:9: info: Lisp.eval return type inferred as Integer [plugin.lisp-eval.inferred-return-type]
```

It is a *companion to the analyzer*, not an extension of the
analyzer's inference engine. v0.1.0 plugins emit diagnostics
and contribute cache entries; the protocol that lets a plugin
override the analyzer's own inferred return type for a call
site is queued for a later v0.1.x slice. When that ships, the
same interpreter inside this plugin will move into a return-type
contribution. The diagnostic-side surface stays useful either
way.

## What the plugin recognises

```ruby
Lisp.eval(7)                              # => Integer
Lisp.eval(3.14)                           # => Float
Lisp.eval(true)                           # => bool
Lisp.eval([:+, 1, [:*, 2, 3]])            # => Integer
Lisp.eval([:+, 1, [:*, 2.0, 3]])          # => Float
Lisp.eval([:<, 1, 2])                     # => bool
Lisp.eval([:if, [:<, 1, 2], 1, 2.0])      # => Integer | Float
Lisp.eval([:and, true, [:not, false]])    # => bool
```

Ill-typed expressions surface as `error` diagnostics:

```ruby
Lisp.eval([:+, 1, true])
# error: `+` expects numeric operands, got Integer and bool
#        [plugin.lisp-eval.type-error]
```

Call sites whose argument is *not* a literal Lisp expression
(`Lisp.eval(some_method)`, `Lisp.eval(@cached)`, …) are
ignored — the plugin stays silent rather than guessing.

## Layout

```
rigor-lisp-eval/
├── README.md                           ← this file
├── rigor-lisp-eval.gemspec             ← gem packaging template
├── lib/
│   ├── rigor-lisp-eval.rb              ← gem entry; requires + registers
│   └── rigor/plugin/
│       ├── lisp_eval.rb                ← the plugin (manifest, hooks, walker)
│       └── lisp_eval/interpreter.rb    ← the static type interpreter
└── demo/
    ├── .rigor.yml                      ← `plugins: [rigor-lisp-eval]`
    ├── demo.rb                         ← user code that calls Lisp.eval(...)
    ├── lib/lisp.rb                     ← user-side runtime implementation
    └── sig/lisp.rbs                    ← `Lisp.eval` RBS signature
```

## Running the demo

The plugin is not published as a gem; it lives inside the
Rigor source tree as a sample. To run it locally without
building the gem, point Ruby at the plugin's `lib/`:

```sh
cd examples/rigor-lisp-eval/demo
RUBYLIB=$PWD/../lib bundle exec rigor check demo.rb
```

The plugin loader resolves `rigor-lisp-eval` through
`Kernel.require`; with `RUBYLIB` set, that finds the
in-repo source.

## Plugin authoring surface this exercises

| Surface | Where in this plugin |
| --- | --- |
| `Rigor::Plugin::Base.manifest(...)` | `lib/rigor/plugin/lisp_eval.rb` (top of class) |
| `Rigor::Plugin.register(...)` | bottom of `lib/rigor/plugin/lisp_eval.rb` |
| `#init(services)` config plumbing | `LispEval#init` reads `@config` defaults |
| `config_schema` enforcement | manifest declares `module_name` / `method_name` / `severity` |
| `#diagnostics_for_file(path:, scope:, root:)` | walks Prism AST under `root`, emits per-call diagnostics |
| `Rigor::Analysis::Diagnostic` construction | `#diagnostic_for_inferred_type` / `#diagnostic_for_error` |
| `source_family` auto-stamping | runner stamps `plugin.lisp-eval` automatically — the plugin never sets it |

## What this plugin does NOT exercise

These surfaces exist in v0.1.0 but the example does not use
them. Each is documented separately:

- `Plugin::Base.producer` / `#cache_for` — cache producers
  (`docs/internal-spec/plugin-cache-producers.md`).
- `Plugin::TrustPolicy` / `Plugin::IoBoundary` — declarative
  read-scope policy (`docs/internal-spec/plugin-trust.md`).

The Lisp interpreter is purely AST-driven, has no I/O, and is
fast enough not to need caching, so the example stays
narrowly focused on the diagnostic emission protocol.

## Future direction — lightweight HKT / type-level eval

The plugin currently surfaces the inferred type as a diagnostic
because v0.1.0 has no plugin hook for return-type
contributions. Two adjacent surfaces would let the example move
from "describes the type" to "supplies the type":

1. **Plugin return-type contributions.** Once plugins can emit
   `FlowContribution` bundles consumed by
   `Inference::MethodDispatcher`, the same `Interpreter` body
   moves into a `return_type` slot and the diagnostic stays as
   a user-facing trace.
2. **Lightweight HKT — type-level `eval`.** Rigor's extension
   spec already lists *conditional types* and *indexed-access
   types* under
   [`docs/type-specification/rigor-extensions.md`](../../docs/type-specification/rigor-extensions.md) (rows 22 and 51) as
   forms it MAY support for library signatures. With those,
   `Lisp.eval`'s RBS sig itself becomes structurally precise:

   ```rbs
   def self.eval: [E] (E expr) -> lisp_type[E]

   type lisp_type[E] =
       (E <: Integer ? Integer
     : E <: Float    ? Float
     : E <: bool     ? bool
     : E <: [:+ | :- | :* | :/, A, B]   ? numeric_join[lisp_type[A], lisp_type[B]]
     : E <: [:< | :> | :<= | :>= | :==, _, _] ? bool
     : E <: [:and | :or | :not, *_]     ? bool
     : E <: [:if, _, A, B]              ? (lisp_type[A] | lisp_type[B])
     : untyped)
   ```

   The runtime interpreter (`demo/lib/lisp.rb`) and the static
   type function then live in one declarative table; the
   analyzer's call-site inference replaces the diagnostic with
   a real return type; and `untyped` disappears from the demo's
   `sig/lisp.rbs` entirely.

The same comment is duplicated at the head of
`demo/sig/lisp.rbs` so signature readers see the future shape
without leaving the file.

## License

MPL-2.0, matching the parent Rigor project.
