# rigor-factorybot

Validates every `FactoryBot.create(:name, key: …)` / `.build(…)` /
`.build_stubbed(…)` / `.attributes_for(…)` / `*_list` call against
an index of your factory definitions: an unknown factory name or an
attribute key the factory doesn't declare is flagged (each with a
did-you-mean). When [`rigor-activerecord`](rigor-activerecord.md) is
also active, attribute keys are additionally cross-checked against
the model's columns. No FactoryBot runtime dependency.

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-factorybot
  # - rigor-activerecord   # optional: enables the AR column cross-check
```

## What it checks

```ruby
# spec/factories/users.rb
FactoryBot.define do
  factory :user do
    name  { "Alice" }
    email { "alice@example.com" }
  end
end

FactoryBot.create(:user, name: "X")     # ✓ info trace
FactoryBot.build(:post, headline: "Hi") # ✗ unknown-attribute (suggest :title)
FactoryBot.create(:usre)                # ✗ unknown-factory (suggest :user)
```

| Rule | Severity | Fires when |
| --- | --- | --- |
| `plugin.factorybot.factory-call` | info | the call resolved to a known factory; lists its declared attributes |
| `plugin.factorybot.unknown-factory` | error | the literal `:name` isn't in the factory index (with a did-you-mean) |
| `plugin.factorybot.unknown-attribute` | error | a keyword key isn't a declared attribute (with a did-you-mean); also checked against the model's columns when `:model_index` is available |

The legacy `FactoryGirl` constant is recognised the same way.
Recognised entry methods: `create` / `build` / `build_stubbed` /
`attributes_for` and the `*_list` variants. Inside a factory it
recognises `name { … }` (modern), `name "…"` (legacy positional),
and `add_attribute(:name) { … }`.

## Configuration

```yaml
plugins:
  - gem: rigor-factorybot
    config:
      factory_search_paths: ["spec/factories", "spec/factories.rb"]  # default
      # Minitest projects: ["test/factories"]
```

## Factory references for `rigor unused`

`factory :user, class: "Admin::User"` names a class as a string, and
a bare `factory :user` relies on FactoryBot constantizing the factory
name. Neither is a constant reference, so
[`rigor unused`](../02-cli-reference.md#rigor-unused) cannot see them
and would report a factoried model as dead.

This plugin supplies those model classes — as **test-role
references**, not as roots. A class reached only through a factory
therefore leaves the candidate list and appears under **Reachable
only from test code** instead. That is deliberate: a model kept alive
by its factory and its spec and nothing else is dead production code
with a live test, and rooting factories would have hidden exactly
that finding.

## Limitations

- **Literal arguments only** — `FactoryBot.create(name)` with a
  variable name passes through.
- **Traits / sequences / associations not collected yet** — an
  attribute defined only inside `trait :admin do … end` can surface
  a false `unknown-attribute` until the trait slice ships.
- **Explicit receiver only** — bare `create(:user)` (from
  `include FactoryBot::Syntax::Methods`) is not recognised in this
  slice; it needs receiver-type inference, which would otherwise
  false-positive on every unrelated `create` call.

## Plugin internals

The factory discoverer / index, the cached producer, the
`:model_index` consumption, the demo, and the contract surfaces
this plugin exercises are in the
[plugin's README](../../../plugins/rigor-factorybot/README.md). To
write a plugin, see [`examples/`](../../../examples/README.md) and
the [`rigor-plugin-author`](../08-skills.md) skill.
