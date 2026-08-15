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
| `manifest(... config_schema:, produces:)` | `policy_search_paths` / `policy_base_classes` / `authorization_call_paths` knobs (ADR-40 declared defaults) + the `:reachability_roots` fact. |
| `Plugin::Base.producer :policy_index` | Caches the discovered policy index across runs (cache invalidates via `producer watch:`). |
| `Plugin::Base.producer :authorized_policies` | Caches the `authorize` / `policy` / `policy_scope` call scan; watched separately, because adding a controller changes which policies are reached without touching `app/policies`. |
| `#prepare(services)` (ADR-9) | Publishes the reachability roots below. |
| `Plugin::Base#io_boundary` (`read_file`) | Reads each `.rb` file under `policy_search_paths` through the trusted scope. |
| `node_rule(Prism::CallNode)` (ADR-37) | Per-call validation of every `authorize` / `policy` / `policy_scope` over the engine-owned walk (the once-per-file load-error stays in `diagnostics_for_file`). |
| `Scope#type_of(receiver)` | Resolves the record argument's inferred type when it isn't a constant; gracefully degrades when the type isn't `Nominal[T]`. |
| `Plugin::Base.suggest` | did-you-mean suggestions for the `unknown-*` diagnostics. |

## Policy roots for `rigor unused`

A Pundit policy is reached by a name that appears nowhere in the source: `authorize @post` runs `PostPolicy#update?`, and the string `PostPolicy` is never written. So a reference index cannot tell a live policy from a dead one, and [`rigor unused`](../../docs/manual/02-cli-reference.md#rigor-unused) reports every policy in the project as a candidate.

The plugin closes that by publishing the reached policies as the `:reachability_roots` fact ([ADR-102](../../docs/adr/102-unused-code-reachability-report.md) WD3).

**It publishes the policies an authorization call names — not every class under `policy_search_paths`.** "A file exists under `app/policies`" is not evidence that anything authorizes against it, and an over-claiming root source silently hides real dead code, which is the failure mode the whole report exists to avoid. So the plugin scans `authorization_call_paths` (default `app/controllers`) for `authorize` / `policy` / `policy_scope` calls, derives the policy each one names, and intersects that with the policies it actually discovered. A policy nobody authorizes against stays in the report.

Two derivations, both grounded in Pundit's own `PolicyFinder`, which builds the policy name from the record's class:

- a constant argument — `authorize Post`, `policy_scope(Post.all)` — names `PostPolicy` exactly;
- a receiverless name — `authorize @post` / `authorize post` — is camelized, because the Rails convention that names the carrier after the record is the convention Pundit's lookup assumes.

Anything else contributes nothing rather than a guess. Because every derived name is intersected with the discovered policies, a derivation this gets wrong matches nothing and is dropped: the failure mode is a missing root, which surfaces in the report as a candidate a human can judge, rather than a spurious root, which surfaces as nothing at all. A namespaced policy (`Admin::PostPolicy`) is under-supplied for the same reason — the derivation is unqualified.

Set `authorization_call_paths` wider if you also authorize from `app/graphql`, `app/services` or similar; the default is narrow because the walk is a Prism parse per file on every run.

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
