# rigor-pundit

Tier 3B of Rigor's Rails ecosystem family
([roadmap](../../docs/design/20260508-rails-plugins-roadmap.md)).
Validates Pundit `authorize(record, :action)` /
`policy(record)` / `policy_scope(scope)` calls against the
project's `app/policies/` tree. No Pundit runtime
dependency — the plugin reads project source via Prism
only.

## What the plugin recognises

Given policy classes:

```ruby
# app/policies/post_policy.rb
class PostPolicy < ApplicationPolicy
  def show?; ...; end
  def update?; ...; end
  def destroy?; ...; end
end
```

…the plugin validates every call site against the
discovered policies:

```text
demo.rb:16:1: info:    `authorize(...)` resolves to `PostPolicy`
demo.rb:17:1: info:    `authorize(...)` resolves to `PostPolicy`

errors_demo.rb:12:1: error: `PostPolicy#destory?` is not defined (known: destroy?, show?, update?) (did you mean `:destroy`?)
errors_demo.rb:21:1: error: no policy class `CommnetPolicy` for `authorize` call (did you mean `CommentPolicy`?)
```

## Recognised call shapes

| Shape | What gets checked |
| --- | --- |
| `authorize(Record, :action)` | Policy class exists, predicate defined |
| `authorize(record_expr, :action)` | Same, when `record_expr`'s inferred type is `Nominal[T]` |
| `authorize(record)` | Policy class exists; predicate skipped (the action is a runtime controller binding) |
| `policy(record)` | Policy class exists |
| `policy_scope(scope)` | Policy class exists |

The first argument is mapped to a policy class name via
Pundit's standard convention: `Post` → `PostPolicy`,
`Comment` → `CommentPolicy`, `Admin::User` →
`Admin::UserPolicy`. Records whose inferred type is NOT
`Nominal[T]` (untyped local variables, untyped instance
variables) are silently passed through.

The second argument is normalised to a predicate name:
both `:update` and `:update?` resolve to `update?`.

## Configuration

```yaml
plugins:
  - gem: rigor-pundit
    config:
      policy_search_paths: ["app/policies"]    # default; optional
      policy_base_classes: ["ApplicationPolicy"]  # default; optional
```

## Limitations (v0.1.0)

- **Direct-superclass match only.** `class AdminPolicy <
  ApplicationPolicy` is discovered. `class
  AdminPostPolicy < AdminPolicy` is NOT, unless you list
  `AdminPolicy` in `policy_base_classes`.
- **Predicate methods only.** Non-`?`-suffixed methods on
  policy classes are excluded (`initialize`, `resolve`
  for `Scope`, helper methods).
- **Implicit-form action skipped.** `authorize(record)`
  defers the action to the controller's current action
  at runtime; the static analyzer can't recover that
  without controller context.
- **Untyped records pass through.** `authorize(local_var,
  :show)` does not validate when `local_var` has no
  inferred `Nominal[T]` type.

## Layout

```text
examples/rigor-pundit/
├── README.md
├── rigor-pundit.gemspec
├── lib/
│   ├── rigor-pundit.rb
│   └── rigor/plugin/
│       ├── pundit.rb
│       └── pundit/
│           ├── policy_index.rb        ← frozen `{class_name => Entry}` value object
│           ├── policy_discoverer.rb   ← walks app/policies, builds the index
│           └── analyzer.rb            ← per-call validation
└── demo/
    ├── .rigor.yml
    ├── .gitignore
    ├── app/policies/
    │   ├── post_policy.rb
    │   └── comment_policy.rb
    ├── demo.rb
    └── errors_demo.rb
```

## Running the demo

```sh
cd examples/rigor-pundit/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... config_schema:)` | Optional `policy_search_paths` / `policy_base_classes` knobs. |
| `Plugin::Base.producer :policy_index` | Caches the discovered policy index across runs. |
| `Plugin::Base#io_boundary` (`read_file`) | Reads each `.rb` file under `policy_search_paths` through the trusted scope; the digest list feeds the cache descriptor. |
| `Plugin::Base#diagnostics_for_file` | Per-file walker validates every `authorize` / `policy` / `policy_scope` call. |
| `Scope#type_of(receiver)` | Resolves the record argument's inferred type when it isn't a constant; gracefully degrades when the type isn't `Nominal[T]`. |

## Future direction

- **Indirect inheritance**: walk the discovered policy
  hierarchy so subclasses inherit predicate methods from
  their parents instead of needing every base class
  listed in `policy_base_classes`.
- **Controller context**: when `rigor-actionpack` lands
  and publishes the controller's current action as an
  ADR-9 fact, the implicit form `authorize(record)` can
  resolve the predicate.
- **`Scope` policies**: `policy_scope(Post)` is currently
  validated only for class existence; once a Pundit
  `Scope` inner class is recognised, the
  `Scope#resolve` method can be validated too.
- **`cancancan` adapter**: a sibling plugin with the same
  shape but different conventions could share this
  plugin's discoverer / analyzer scaffolding via subtree
  split.

## License

MPL-2.0, matching the parent Rigor project.
