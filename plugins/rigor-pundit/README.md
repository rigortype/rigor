# rigor-pundit

Tier 3B of Rigor's Rails ecosystem family
([roadmap](../../docs/design/20260508-rails-plugins-roadmap.md)).
Validates Pundit `authorize(record, :action)` /
`policy(record)` / `policy_scope(scope)` calls against the
project's `app/policies/` tree. No Pundit runtime
dependency — the plugin reads project source via Prism
only.

> **Using this plugin?** The user guide — recognised call shapes,
> the diagnostic catalogue, configuration, and limitations — lives
> in the manual at
> [docs/manual/plugins/rigor-pundit.md](../../docs/manual/plugins/rigor-pundit.md).
> This README covers the plugin's internals.

## Layout

```text
plugins/rigor-pundit/
├── README.md
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
cd plugins/rigor-pundit/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... config_schema:)` | `policy_search_paths` / `policy_base_classes` knobs (ADR-40 declared defaults). |
| `Plugin::Base.producer :policy_index` | Caches the discovered policy index across runs (cache invalidates via `producer watch:`). |
| `Plugin::Base#io_boundary` (`read_file`) | Reads each `.rb` file under `policy_search_paths` through the trusted scope. |
| `node_rule(Prism::CallNode)` (ADR-37) | Per-call validation of every `authorize` / `policy` / `policy_scope` over the engine-owned walk (the once-per-file load-error stays in `diagnostics_for_file`). |
| `Scope#type_of(receiver)` | Resolves the record argument's inferred type when it isn't a constant; gracefully degrades when the type isn't `Nominal[T]`. |
| `Plugin::Base.suggest` | did-you-mean suggestions for the `unknown-*` diagnostics. |

## Future direction

- **Indirect inheritance**: walk the discovered policy
  hierarchy so subclasses inherit predicate methods from
  their parents instead of needing every base class
  listed in `policy_base_classes`.
- **Controller context**: the implicit form `authorize(record)`
  could resolve its predicate if the controller's current action
  were available as a fact (e.g. published by `rigor-actionpack`).
- **`Scope` policies**: `policy_scope(Post)` is currently
  validated only for class existence; once a Pundit
  `Scope` inner class is recognised, the
  `Scope#resolve` method can be validated too.

## License

MPL-2.0, matching the parent Rigor project.
