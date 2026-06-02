# rigor-devise

ADR-16 **Tier B** substrate consumer: recognises Devise's model-side
`devise :strategy_a, :strategy_b` DSL on `ActiveRecord::Base`
subclasses and explodes each strategy's RBS instance methods onto
the calling model class.

> **Using this plugin?** The user guide — recognised strategies,
> what it contributes, and limitations — lives in the manual at
> [docs/manual/plugins/rigor-devise.md](../../docs/manual/plugins/rigor-devise.md).
> This README covers the plugin's internals.

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
sites; the `SyntheticMethodIndex` stores the per-method explosion;
the dispatcher tier `try_synthetic_method` surfaces them below RBS
dispatch.

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
`user.send_reset_password_instructions`, `user.email` now resolve
through the substrate tier — no more `call.undefined-method`.

## Return-type precision (slice 6a, landed)

Tier B synthesis delivers both method-name resolution AND precise
return-type recovery. The dispatcher's `try_synthetic_method` tier
redispatches on `Nominal[origin_module]` via `RbsDispatch.try_dispatch`
to recover the module's **authored RBS return** — so
`user.valid_password?("pw")` is `bool`, not `Dynamic[T]`. The
`origin_module:` provenance recorded at synthesis time is what makes
this lookup possible without rescanning.

## Trait set covered

Mirrors the modules Devise registers via `Devise.add_module`
at `lib/devise/modules.rb`:

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

## Not yet synthesised

- **Per-strategy `ClassMethods`.** Devise's per-module `ClassMethods`
  pattern (`Recoverable.reset_password_by_token` etc.) needs a
  separate sub-primitive; the registry covers instance methods only.
- **Controller-side helpers** (`current_user`, `authenticate_user!`,
  `user_signed_in?`, `user_session`) — Tier C work parameterised by
  the `devise_for :resource` route declaration; deferred to a future
  slice that consumes the route fact.
- **User-side `Devise.add_module :my_strategy`** in
  `config/initializers/devise.rb` — needs an initializer-scanner not
  yet in the substrate.

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
across the file boundary from `demo.rb`; the calls resolve through
the synthetic-method tier with their authored return types.

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
