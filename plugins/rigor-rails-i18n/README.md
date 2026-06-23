# rigor-rails-i18n

Tier 1B of Rigor's Rails ecosystem family
([roadmap](../../docs/design/20260508-rails-plugins-roadmap.md)).
Validates `t('key.path')` / `I18n.t(...)` /
`I18n.translate(...)` calls against
`config/locales/*.yml`. Reports missing keys (with
did-you-mean suggestions), per-locale coverage gaps, and
interpolation-variable mismatches. No Rails runtime
dependency — the plugin reads YAML through Prism and
`YAML.safe_load` only.

> **Using this plugin?** The user guide — recognised call shapes
> (including lazy `t('.key')`), the framework-shipped key prefixes
> it skips, configuration, and limitations — lives in the manual at
> [docs/manual/plugins/rigor-rails-i18n.md](../../docs/manual/plugins/rigor-rails-i18n.md).
> This README covers the plugin's internals.

## Layout

```text
plugins/rigor-rails-i18n/
├── README.md
├── lib/
│   ├── rigor-rails-i18n.rb
│   └── rigor/plugin/
│       ├── rails_i18n.rb
│       └── rails_i18n/
│           ├── locale_index.rb     ← frozen `dotted_key => Entry` value object
│           ├── locale_loader.rb    ← walks config/locales, parses YAML, builds the index
│           └── analyzer.rb         ← per-call validation + view template lazy-key scanning
└── demo/
    ├── .rigor.yml
    ├── .gitignore
    ├── config/locales/
    │   ├── en.yml
    │   └── ja.yml
    ├── demo.rb
    └── errors_demo.rb
```

## Running the demo

```sh
cd plugins/rigor-rails-i18n/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

## Plugin authoring surface this exercises

| Surface | Used for |
| --- | --- |
| `manifest(... config_schema:)` | `locale_search_paths` / `configured_locales` / `view_search_paths` knobs (ADR-40 declared defaults). |
| `Plugin::Base.producer :locale_index` | Caches the discovered locale index across runs (cache invalidates via `producer watch:`). |
| `Plugin::Base.producer :view_diagnostics` | Scans view templates under `view_search_paths` for lazy `t('.key')` calls; caches across runs. |
| `Plugin::Base#io_boundary` (`read_file`) | Reads each `.yml` / `.yaml` under `locale_search_paths` and each `.erb` / `.haml` / `.slim` under `view_search_paths` through the trusted scope. |
| `node_rule` + `NodeContext` (ADR-37) | Per-call validation over the engine-owned walk; the lexical ancestor chain resolves a lazy `t('.key')` to its enclosing controller action. |

## Future direction

- **Per-locale interpolation enforcement**: split the
  required-placeholder set per locale so a call complete for `en`
  but missing a variable for `ja` can be flagged.
- **Pluralization branches**: enrich the index with
  `:zero` / `:one` / `:other` keys and validate
  `t(..., count: …)` against them.
- **View interpolation validation**: the current scanner uses a
  regex to extract `t('.key')` calls, so interpolation hashes
  inside templates (e.g. `t('.greeting', name: @user.name)`) are
  not parsed. A Prism-AST-based ERB walker would let the plugin
  validate `t('.key', **opts)` interpolation variables in views
  the same way it validates controller calls.
- **Once-per-run diagnostic channel**: the view scan is a
  project-wide pass emitted through the per-file diagnostic hook,
  so under `--workers` each fork-pool worker re-emits the full set
  (the same limitation the `load-error` path carries). A deduped
  once-per-run plugin project-diagnostic channel would let both
  surface exactly once regardless of the worker count.

## License

MPL-2.0, matching the parent Rigor project.
