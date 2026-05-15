# rigor-devise — example Rigor plugin

ADR-16 **Tier B** worked target: recognises Devise's model-side
`devise :strategy_a, :strategy_b` DSL on `ActiveRecord::Base`
subclasses and explodes each strategy's RBS instance methods onto
the calling model class.

This plugin is the **first worked consumer of `Plugin::Macro::TraitRegistry`**
(ADR-16 slice 3c). Like `rigor-sinatra` (Tier A) and
`rigor-dry-struct` (Tier C), its body is purely **declarative**:

```ruby
class Devise < Rigor::Plugin::Base
  manifest(
    id: "devise",
    version: "0.1.0",
    trait_registries: [
      Rigor::Plugin::Macro::TraitRegistry.new(
        receiver_constraint: "ActiveRecord::Base",
        method_name: :devise,
        symbol_arg_position: :rest,
        modules_by_symbol: {
          database_authenticatable: "Devise::Models::DatabaseAuthenticatable",
          recoverable:              "Devise::Models::Recoverable",
          rememberable:             "Devise::Models::Rememberable",
          # … see lib/rigor/plugin/devise.rb for the full table
        },
        always_included: ["Devise::Models::Authenticatable"]
      )
    ]
  )
end
```

No `diagnostics_for_file`, no AST walker, no plugin-side state.
The substrate's slice-3b scanner walks `<X>.devise(:a, :b)` call
sites; the existing `SyntheticMethodIndex` (slice 2b primitive)
stores the per-method explosion; the slice-2b dispatcher tier
`try_synthetic_method` surfaces them below RBS dispatch.

## What the plugin does

For source like

```ruby
class User < ApplicationRecord
  devise :database_authenticatable, :recoverable
end
```

the substrate's pre-pass:

1. Sees the `devise` call. `User <- ApplicationRecord <- ActiveRecord::Base`
   matches the registry's `receiver_constraint`.
2. Resolves the trait symbols: `:database_authenticatable` →
   `Devise::Models::DatabaseAuthenticatable`, `:recoverable` →
   `Devise::Models::Recoverable`. Adds the always-included
   `Devise::Models::Authenticatable`.
3. For each module, looks up its RBS instance methods through
   `Environment::RbsLoader#instance_definition` and enumerates
   the method names.
4. Synthesises one `SyntheticMethod` per (User, instance method)
   pair into the `SyntheticMethodIndex` with `origin_module:`
   recorded in the provenance.

Cross-file calls like `user.valid_password?(...)`,
`user.send_reset_password_instructions`, `user.email` now
resolve through the substrate tier and return `Dynamic[T]` —
no more `call.undefined-method`.

## Floor / ceiling per ADR-16 WD13

The v0.1.x deliverable is the **floor**: synthesised method
**names** emit and are visible to cross-file dispatch.
**Return types degrade to `Dynamic[T]`** at the dispatcher's
slice-2b `try_synthetic_method` tier. The `origin_module:`
provenance field is recorded so a future slice (slice 6 —
precision promotion) can dispatch through the module's RBS to
recover the authored return type without rescanning. That's
the **ceiling**, NOT a slice-3c commitment.

## Trait set covered

Mirrors the modules Devise registers via `Devise.add_module`
at `lib/devise/modules.rb` (see the per-library survey § Devise
for the canonical list):

| Symbol | Module |
| --- | --- |
| `:database_authenticatable` | `Devise::Models::DatabaseAuthenticatable` |
| `:recoverable` | `Devise::Models::Recoverable` |
| `:rememberable` | `Devise::Models::Rememberable` |
| `:registerable` | `Devise::Models::Registerable` |
| `:trackable` | `Devise::Models::Trackable` |
| `:validatable` | `Devise::Models::Validatable` |
| `:confirmable` | `Devise::Models::Confirmable` |
| `:lockable` | `Devise::Models::Lockable` |
| `:timeoutable` | `Devise::Models::Timeoutable` |
| `:omniauthable` | `Devise::Models::Omniauthable` |
| `:authenticatable` | `Devise::Models::Authenticatable` |

Always-included regardless of selection:
`Devise::Models::Authenticatable`.

## What the plugin does NOT do (yet)

- **Return-type precision.** Per WD13 — module methods are
  `Dynamic[T]` at the floor. Ceiling is the slice-6 promotion
  via `origin_module` provenance.
- **`extend ClassMethods` (per-strategy class methods).**
  Devise's per-module `ClassMethods` pattern (`Recoverable.reset_password_by_token`
  etc.) needs a separate sub-primitive; slice 3 covers
  instance methods only.
- **Controller-side helpers** (`current_user`,
  `authenticate_user!`, `user_signed_in?`, `user_session`).
  These are Tier C work parameterised by the `devise_for :resource`
  route declaration; deferred to a future slice that consumes
  ADR-9 fact-store entries from a `rigor-rails-routes`-style
  walker.
- **User-side `Devise.add_module :my_strategy`.** Third-party
  Devise extensions registering new strategies in
  `config/initializers/devise.rb` aren't scanned. Adding that
  path needs an initializer-scanner not yet in the substrate.
- **`included do` blocks** (Devise's per-module `attr_reader
  :password` etc.). Those are ActiveSupport::Concern body
  facts; slice 4 (Concern re-targeting walker) handles them.

## Configuration

```yaml
plugins:
  - rigor-devise
```

No plugin-specific config keys. The bundled module table is
fixed at the manifest level.

## Running the demo

The demo provides minimal RBS stubs locally
(`demo/sig/devise.rbs`). A real project depending on Devise
would consume the upstream gem's RBS through rigor's
Bundler-awareness path.

```sh
cd demo
cp .rigor.dist.yml .rigor.yml
RUBYLIB=$PWD/../lib bundle exec rigor check
```

The demo's `consumer.rb` calls `user.valid_password?`,
`user.update_with_password`, `user.send_reset_password_instructions`,
`user.remember_me!`, `admin.lock_access!`, `admin.failed_attempts`
across the file boundary from `demo.rb`. With the plugin enabled
these calls resolve through the synthetic-method tier; without
it they would all degrade to undefined-method or `Dynamic[T]`
via the user-class fallback.

## Related

- [ADR-16](../../docs/adr/16-macro-expansion.md) — the substrate
  contract.
- `Rigor::Plugin::Macro::TraitRegistry`
  ([lib/rigor/plugin/macro/trait_registry.rb](../../lib/rigor/plugin/macro/trait_registry.rb))
  — the value class the manifest entries instantiate.
- `Rigor::Inference::SyntheticMethodScanner`
  ([lib/rigor/inference/synthetic_method_scanner.rb](../../lib/rigor/inference/synthetic_method_scanner.rb))
  — the pre-pass that walks Tier B call sites and explodes
  module RBS methods into the index.
- Per-library survey, Devise section:
  [`docs/notes/20260515-macro-expansion-library-survey.md`](../../docs/notes/20260515-macro-expansion-library-survey.md).
