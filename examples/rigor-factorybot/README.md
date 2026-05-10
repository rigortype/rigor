# rigor-factorybot (Phase 1 (a) — self-contained validation)

Validates every `FactoryBot.create(:name, key: ...)` /
`.build(...)` / `.build_stubbed(...)` / `.attributes_for(...)`
/ `*_list` call against an index built from
`factory_search_paths` (default `["spec/factories",
"spec/factories.rb"]` covering both the modern multi-file
convention and the legacy single-file form). No FactoryBot
runtime dependency.

The full FactoryBot plugin spans two phases:

| Phase | Surface | Status |
| --- | --- | --- |
| 1 (a) | **Factory + attribute key validation** (self-contained) | **landed** |
| 1 (c) | **AR column cross-check** via `rigor-activerecord :model_index` (ADR-9 fact) | **landed** |

Subsequent slices add traits, sequences, parent / child
factories, and dynamic factory names; each composes
additively under the same plugin id.

## What the plugin recognises

```ruby
# spec/factories/users.rb
FactoryBot.define do
  factory :user do
    name  { "Alice" }
    email { "alice@example.com" }
    role  { "member" }
  end
end
```

```ruby
# spec/users_spec.rb (or anywhere — the path filter is
# absent in Phase 1 (a))
FactoryBot.create(:user)                              # ✓ info trace
FactoryBot.create(:user, name: "X", role: "admin")    # ✓ info trace
FactoryBot.build(:post, headline: "Hi")               # ✗ unknown-attribute (suggest :title)
FactoryBot.create(:usre)                              # ✗ unknown-factory (suggest :user)
```

The legacy `FactoryGirl` constant is recognised the same way
as `FactoryBot`.

## What's recognised inside `factory :name do ... end`

- `name { "Alice" }` — implicit attribute via
  `method_missing` with a block (modern syntax).
- `name "Alice"` — implicit attribute with a positional
  argument (legacy syntax).
- `add_attribute(:name) { "Alice" }` — explicit form.

Sequences (`sequence(:email) { ... }`), associations
(`association :author`), traits (`trait :admin do ... end`),
and parent / child relationships (`factory :admin, parent:
:user do ... end`) ship in follow-up slices. Factories whose
name is a non-literal expression (`factory FACTORY_NAME do
... end`) are silently skipped.

## Diagnostics

| Rule | Severity | Fires when |
| --- | --- | --- |
| `plugin.factorybot.factory-call` | info | The entry call resolved to a known factory; lists the factory's declared attribute set. |
| `plugin.factorybot.unknown-factory` | error | The first positional argument's literal `:name` is not in the factory index. Includes a `DidYouMean::SpellChecker` suggestion drawn from the index. |
| `plugin.factorybot.unknown-attribute` | error | A keyword-argument key is not declared on the resolved factory. Includes a `DidYouMean::SpellChecker` suggestion drawn from the factory's declared attribute names. |

## Configuration

```yaml
plugins:
  - gem: rigor-factorybot
    config:
      factory_search_paths:
        - spec/factories
        - spec/factories.rb
        # Minitest projects override:
        # - test/factories
```

## Recognised entry methods

`FactoryBot.create`, `.build`, `.build_stubbed`,
`.attributes_for`, `.create_list`, `.build_list`,
`.build_stubbed_list`. Implicit-receiver calls
(`create(:name)` inside a `include
FactoryBot::Syntax::Methods` context) are NOT recognised in
Phase 1 (a) — too many false positives on plain `create`
calls outside test files; this needs receiver-type inference
(Phase 1 (b)).

## Limitations

- **Literal arguments only.** `FactoryBot.create(name)`
  where `name` is a local variable is silently passed
  through.
- **No nested-trait recognition.** Attributes inside
  `trait :admin do ... end` are not collected; using a
  trait-only attribute via `create(:user, :admin,
  trait_only: ...)` will surface `unknown-attribute` until
  the trait slice ships.
- **No AR column cross-check yet.** Phase 1 (c) ships that
  via the `rigor-activerecord :model_index` ADR-9 fact once
  `rigor-activerecord` adds the publish hook.

## Demo

```sh
cd examples/rigor-factorybot/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

Demo ships:

- `spec/factories/users.rb` — declares `:user` (3 attrs) and
  `:post` (3 attrs).
- `demo.rb` — exercises every recognised entry call shape;
  emits `factory-call` info traces.
- `errors_demo.rb` — triggers each error path
  (`unknown-factory` with did-you-mean,
  `unknown-attribute` with did-you-mean — twice).

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(...)` + `config_schema` | declares the optional `factory_search_paths` config knob |
| `Plugin::Base#io_boundary` (`read_file`) | reads `spec/factories` content under the trusted scope |
| `Plugin::Base.producer` + `#cache_for` | caches the per-run factory index keyed on the IoBoundary's collected `FileEntry` digests |
| `Plugin::Base#diagnostics_for_file` | per-file emission hook |
| `Rigor::Analysis::Diagnostic` | builds the three diagnostic shapes |
| `DidYouMean::SpellChecker` | suggesters for both `unknown-*` rules |

## License

MPL-2.0, matching the parent Rigor project.
