# rigor-statesman — example Rigor plugin

Reference example for the **two-pass DSL analysis** pattern.
Many DSL plugins (state machines, GraphQL types, ActiveModel
validations, route declarations) share this skeleton:

1. **Collect pass.** Walk the file once to gather every
   declaration the DSL emits — here, `state :foo` calls
   inside `state_machine do ... end` blocks.
2. **Validate pass.** Walk the file again, validating later
   references — here, `transition_to(:sym)` calls — against
   the collected set. Levenshtein distance ≤ 3 drives the
   did-you-mean suggestions.

The pattern's value: the plugin works on declarative DSLs
without needing Ruby type inference. Whether the receiver is
`Order.new`, `@order`, or `users.first`, every
`transition_to(:foo)` call site gets validated as long as
**some** state machine in the file declares the symbol.

## What the plugin recognises

```text
demo.rb:31:1:        info: transition_to(:submitted) — declared state [plugin.statesman.known-state]
demo.rb:32:1:        info: transition_to(:approved) — declared state [plugin.statesman.known-state]
errors_demo.rb:26:1: error: unknown state :approval (did you mean :approved?) [plugin.statesman.unknown-state]
errors_demo.rb:27:1: error: unknown state :submited (did you mean :submitted?) [plugin.statesman.unknown-state]
errors_demo.rb:30:1: error: unknown state :purgatory [plugin.statesman.unknown-state]
```

| Diagnostic | Severity | Rule |
| --- | --- | --- |
| `transition_to(:known_state)` | `:info` | `known-state` |
| `transition_to(:typo)` (close match) | `:error` | `unknown-state` (with did-you-mean) |
| `transition_to(:typo)` (no close match) | `:error` | `unknown-state` |
| file declares no state machine | silent | — |
| `transition_to(some_var)` (non-Symbol arg) | silent | — |

## Configuration

Defaults match the `Statesman::Machine` API; override via
`.rigor.yml` for `aasm` or other DSLs:

```yaml
plugins:
  - gem: rigor-statesman
    config:
      dsl_method: state_machine    # the do-block opener
      state_method: state          # state declaration inside the block
      transition_method: transition_to  # call-site under check
```

## Layout

```
rigor-statesman/
├── README.md
├── rigor-statesman.gemspec
├── lib/
│   ├── rigor-statesman.rb
│   └── rigor/plugin/statesman.rb   ← collect-then-validate analyzer
└── demo/
    ├── .rigor.yml
    ├── demo.rb                     ← state_machine + valid transitions
    ├── errors_demo.rb              ← intentionally ill-typed (do NOT run)
    └── lib/runtime.rb              ← runtime DSL, state-tracking
```

## Running the demo

```sh
cd examples/rigor-statesman/demo
RUBYLIB=$PWD/../lib bundle exec rigor check
```

## Plugin authoring surface this exercises

| Surface | Where in this plugin |
| --- | --- |
| Manifest with three string-keyed config options | top of `lib/rigor/plugin/statesman.rb` |
| `#init(services)` reads + memoises config | `Statesman#init` |
| Two-pass walking — collect → validate | `Statesman#collect_states` then `#validate_transitions` |
| Per-block AST traversal (`node.block`) | `Statesman#collect_states` enters the DSL block |
| Levenshtein-based did-you-mean | `Statesman#did_you_mean` private helper |

## File-scoping trade-off (intentional)

The plugin treats each file independently — states declared in
`models/order.rb` are not visible from `actions/promote.rb`. The
shipped Statesman / aasm DSL keeps the declaration and the
usage in the same model file, so the trade-off matches real
usage. Plugins that need cross-file declaration tracking would
extend the architecture by:

- adding a `Plugin::Base.producer` that builds a project-wide
  declaration index from all `*.rb` files (cached on the file
  digest fingerprint), or
- waiting for the v0.1.x **whole-project** plugin hook, which
  is queued for a follow-up slice once `diagnostics_for_file`
  is no longer the only emission entry.

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
