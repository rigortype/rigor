# rigor-devise

Teaches Rigor about the methods Devise mixes into a model from a
`devise :strategy, …` declaration, so cross-file calls to those
methods (`user.valid_password?("pw")`,
`user.send_reset_password_instructions`) resolve instead of
surfacing a false `call.undefined-method` — and resolve with their
real return types. It reads source only; no Devise runtime
dependency.

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-devise
```

## What it does — no diagnostics, no config

`rigor-devise` is a macro-expansion plugin (ADR-16 Tier B): it
emits no diagnostics and has no configuration. From a declaration
like

```ruby
class User < ApplicationRecord
  devise :database_authenticatable, :recoverable
end
```

it synthesises the instance methods each named strategy module
contributes, attaching them to the declaring class so a call in
another file type-checks:

```ruby
user.valid_password?("pw")              # bool
user.send_reset_password_instructions   # (the module's RBS return)
```

Return types are the strategy module's **authored RBS return**
(via `origin_module:` provenance), not a widened `Dynamic[T]`.
Eleven strategies are recognised — `database_authenticatable`,
`recoverable`, `rememberable`, `registerable`, `trackable`,
`validatable`, `confirmable`, `lockable`, `timeoutable`,
`omniauthable`, `authenticatable` — plus the always-included
`Devise::Models::Authenticatable`. Strategies declared inside an
`ActiveSupport::Concern`'s `included do … end` are re-targeted onto
whatever class includes the concern.

## Limitations

- **Instance methods only.** Per-module `ClassMethods` (e.g.
  `User.reset_password_by_token`) are not yet synthesised.
- **Controller helpers deferred.** `current_user` /
  `authenticate_user!` / `user_signed_in?` come from
  `devise_for :users` in the routes file (Tier C work), not the
  model declaration, so they are not contributed yet.
- **Third-party strategies aren't scanned.** A strategy registered
  via `Devise.add_module :foo` in an initializer is unknown to the
  bundled strategy table.

## Plugin internals

The macro manifest (the trait registry mapping each strategy to its
module), the concern re-targeting walk, the demo, and the
contract surfaces this plugin exercises are in the
[plugin's README](../../../plugins/rigor-devise/README.md);
[handbook chapter 9](../../handbook/09-plugins.md) covers the Tier B
macro substrate generally. To write a plugin, see
[`examples/`](../../../examples/README.md) and the
[`rigor-plugin-author`](../08-skills.md) skill.
