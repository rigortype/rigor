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
      authorization_call_paths: ["app/controllers"]  # default
```

`authorization_call_paths` is where the plugin looks for the
`authorize` / `policy` / `policy_scope` calls behind the reachability
roots below. Widen it if you also authorize from `app/graphql` or
`app/services`; it defaults narrow because the walk is a parse per
file on every run.

## Policy roots for `rigor unused`

`authorize @post` runs `PostPolicy#update?`, and the name
`PostPolicy` is never written down. So without help,
[`rigor unused`](../02-cli-reference.md#rigor-unused) reports every
policy in your app as possibly dead. This plugin supplies the
policies your code actually authorizes against, so they drop out of
the candidate list.

It publishes the policies **an authorization call names**, not every
class under `policy_search_paths`. A policy nothing authorizes
against stays in the report, which is the answer you wanted to see:
a root source that claims more than it can show hides real dead code
without telling you.

A policy the plugin cannot attribute to a call — a namespaced
`Admin::PostPolicy`, a record argument it cannot read — stays a
candidate rather than being guessed at.

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
