# rigor-pundit

Validates Pundit `authorize` / `policy` / `policy_scope` calls
against a statically-discovered policy index: the policy class must
exist, and an `authorize(record, :action)` action must correspond
to a defined `<action>?` predicate on the policy. It reads source
only — no Pundit runtime dependency.

It ships bundled in `rigortype`. Activate it under `plugins:`:

```yaml
plugins:
  - rigor-pundit
```

## What it checks

```ruby
# app/policies/post_policy.rb
class PostPolicy < ApplicationPolicy
  def show?;    true; end
  def update?;  true; end
  def destroy?; true; end
end

authorize(Post, :show)      # info:  resolves to PostPolicy#show?
authorize(Post, :destory)   # error: PostPolicy#destory? is not defined (did you mean :destroy?)
authorize(Comment, :edit)   # error: no policy class CommentPolicy (did you mean … ?)
```

| Rule | Severity | Fires when |
| --- | --- | --- |
| `plugin.pundit.policy-call` | info | an `authorize` / `policy` / `policy_scope` call resolved to a discovered policy |
| `plugin.pundit.unknown-policy-class` | error | the record maps to a `<Type>Policy` with no entry in the index (with a did-you-mean) |
| `plugin.pundit.unknown-policy-method` | error | the policy exists but the `:action` has no `<action>?` predicate (lists known predicates + a did-you-mean) |
| `plugin.pundit.load-error` | warning | policy discovery failed (parse/read error) — once per file |

The record maps to a policy by constant name or inferred
`Nominal[T]` (`Post` → `PostPolicy`); `:update` normalises to
`update?`. `authorize(record)` without an action validates only
the policy class (the action is controller-runtime-bound).

## Configuration

```yaml
plugins:
  - gem: rigor-pundit
    config:
      policy_search_paths: ["app/policies"]    # default
      policy_base_classes: ["ApplicationPolicy"]  # default
```

## Limitations

- **Direct-superclass match only.** `class AdminPostPolicy <
  AdminPolicy` (where `AdminPolicy < ApplicationPolicy`) isn't
  discovered unless `AdminPolicy` is added to `policy_base_classes`.
- **Predicate methods only.** Non-`?` methods, and predicates built
  with `define_method` or inherited from concerns, are out of
  scope.
- **Untyped records pass through.** `authorize(local, :show)` is
  not validated when `local` has no inferred `Nominal[T]`.
- **`Scope` policies** are validated for class existence, not for
  `Scope#resolve`.

## Plugin internals

The policy discoverer / index and the contract surfaces this plugin
exercises are in the
[plugin's README](../../../plugins/rigor-pundit/README.md). To
write a plugin, see [`examples/`](../../../examples/README.md) and
the [`rigor-plugin-author`](../08-skills.md) skill.
