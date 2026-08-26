# rigor-statesman

Validates `transition_to(:state)` calls against the states declared
in a `state_machine do … end` block, within the same file. A
transition to an undeclared state is flagged (with a did-you-mean
suggestion). It reads source only — no Statesman runtime
dependency. (The DSL method names are configurable, so it also fits
AASM-shaped state machines.)

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-statesman
```

## What it checks

```ruby
class Order
  state_machine do
    state :draft, initial: true
    state :submitted
    state :approved
  end
end

order.transition_to(:submitted)   # info:  known state
order.transition_to(:approval)    # error: unknown state :approval (did you mean :approved?)
order.transition_to(:purgatory)   # error: unknown state :purgatory
```

| Rule | Severity | Fires when |
| --- | --- | --- |
| `plugin.statesman.known-state` | info | `transition_to(:sym)` where `:sym` is declared in an in-file `state_machine` block |
| `plugin.statesman.unknown-state` | error | `transition_to(:sym)` where `:sym` is not declared (with a `Base.suggest` did-you-mean) |

Multiple `state_machine` blocks in one file union their states.
Non-literal-symbol arguments and files with no state machine are
silently passed through.

## Configuration

```yaml
plugins:
  - gem: rigor-statesman
    config:
      dsl_method: "state_machine"     # default; the block-opening method
      state_method: "state"           # default; the state-declaring method
      transition_method: "transition_to"  # default; the call to validate
```

Renaming these adapts the plugin to a different state-machine DSL
(e.g. AASM's `aasm do … state … end`).

## Limitations

- **File-scoped.** States declared in `models/order.rb` aren't
  visible from another file — each file validates independently.
- **Literal symbols only.** A variable or method-call argument is
  not checked.
- **Receiver-agnostic.** The check fires on any receiver as long as
  *some* state machine in the file declares the symbol; it does not
  tie a `transition_to` to a specific machine.

## Plugin internals

`rigor-statesman` is the reference example for the two-pass
(collect-then-validate) pattern: a `node_file_context` pass
collects the declared states once, and a `node_rule` validates each
`transition_to` over the engine-owned walk. The layout, demo, and
contract surfaces are in the
[plugin's README](https://github.com/rigortype/rigor/blob/master/plugins/rigor-statesman/README.md). To
write a plugin, see [`examples/`](https://github.com/rigortype/rigor/blob/master/examples/README.md) and
the [`rigor-plugin-author`](../08-skills.md) skill.
