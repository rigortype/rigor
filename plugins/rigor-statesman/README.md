# rigor-statesman

Reference example for the **two-pass DSL analysis** pattern.
Many DSL plugins (state machines, GraphQL types, ActiveModel
validations, route declarations) share this skeleton:

1. **Collect pass.** Walk the file once to gather every
   declaration the DSL emits — here, `state :foo` calls
   inside `state_machine do ... end` blocks.
2. **Validate pass.** Walk the file again, validating later
   references — here, `transition_to(:sym)` calls — against
   the collected set, with `Rigor::Plugin::Base.suggest`
   (`DidYouMean::SpellChecker`) driving the did-you-mean.

> **Using this plugin?** The user guide — what it checks, its
> configuration, and limitations — lives in the manual at
> [docs/manual/plugins/rigor-statesman.md](../../docs/manual/plugins/rigor-statesman.md).
> This README covers the plugin's internals.

The pattern's value: the plugin works on declarative DSLs
without needing Ruby type inference. Whether the receiver is
`Order.new`, `@order`, or `users.first`, every
`transition_to(:foo)` call site gets validated as long as
**some** state machine in the file declares the symbol.

## Layout

```
rigor-statesman/
├── README.md
├── lib/
│   ├── rigor-statesman.rb
│   └── rigor/plugin/statesman.rb   ← collect-then-validate analyzer
└── demo/
    ├── .rigor.dist.yml             ← distribution template (copy to .rigor.yml)
    ├── demo.rb                     ← state_machine + valid transitions
    ├── errors_demo.rb              ← intentionally ill-typed (do NOT run)
    └── lib/runtime.rb              ← runtime DSL, state-tracking
```

## Running the demo

```sh
cd plugins/rigor-statesman/demo
cp .rigor.dist.yml .rigor.yml
RUBYLIB=$PWD/../lib bundle exec rigor check
```

## Plugin authoring surface this exercises

| Surface | Where in this plugin |
| --- | --- |
| Manifest with three string-keyed config options (ADR-40 declared defaults) | top of `lib/rigor/plugin/statesman.rb` |
| `node_file_context` (ADR-37) — the collect pass | gathers `state :foo` once per file, threaded to the validate rule |
| `node_rule(Prism::CallNode)` (ADR-37) — the validate pass | checks each `transition_to(:sym)` over the engine-owned walk |
| `Rigor::Plugin::Base.suggest` | did-you-mean suggestions (DidYouMean::SpellChecker) |

This was the first two-pass (`node_file_context` + `node_rule`)
consumer — the engine owns both walks; the plugin supplies only the
collect and validate logic.

## File-scoping trade-off (intentional)

The plugin treats each file independently — states declared in
`models/order.rb` are not visible from `actions/promote.rb`. The
shipped Statesman / aasm DSL keeps the declaration and the
usage in the same model file, so the trade-off matches real
usage. A plugin that needed cross-file declaration tracking would
add a `Plugin::Base.producer` building a project-wide declaration
index from all `*.rb` files (cached on the file-digest fingerprint)
and publish it as an ADR-9 fact for the validate pass to read.

## Compared with the other examples

| | lisp-eval | units | routes | pattern | **statesman** |
| --- | --- | --- | --- | --- | --- |
| AST walking | ✅ | ✅ | ✅ | ✅ | ✅ |
| Local-variable flow | — | ✅ | — | — | — |
| `IoBoundary` (slice 2) | — | — | ✅ | — | — |
| `cache_for` / producer (slice 6) | — | — | ✅ | — | — |
| Engine collaboration via `Scope#type_of` | — | — | — | ✅ | — |
| **Two-pass DSL** (collect → validate) | — | — | — | — | ✅ |
| Did-you-mean suggestions | — | — | ✅ | — | ✅ |

## Future direction — lightweight HKT

With a richer Rigor type-level surface, the state set could
project into a refined-symbol type:

```rbs
class Order
  type State = :draft | :submitted | :approved | :rejected

  def transition_to: (State) -> void
end
```

The plugin's collect pass then publishes the State alias via a
`FlowContribution` bundle and the analyzer's existing
literal-symbol narrowing handles the validate pass.

## License

MPL-2.0, matching the parent Rigor project.
