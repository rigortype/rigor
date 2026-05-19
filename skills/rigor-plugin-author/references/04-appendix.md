# Appendix — pitfalls, real-Rails, cross-plugin facts, reading list

1. **Cache directory in the demo gets committed.** Each demo's `.rigor.yml` MUST set `cache.path: tmp/.rigor/cache` AND each demo MUST carry a `/tmp/`-only `.gitignore` (the repo-root `.gitignore` catches `/tmp/` only at the root). Demos that miss either piece can leak cache artefacts into commits. The repo-root `.gitignore`'s non-anchored `.rigor/cache/` pattern is a fallback for older demos that still default to that path.
2. **Plugin id collisions in tests.** `Rigor::Plugin.unregister!` in `before` AND `after` for every plugin spec; otherwise spec ordering bleeds plugin state across files.
3. **Manifest config_schema kinds.** Only `:string` / `:boolean` / `:integer` / `:array` / `:hash` / `:any` are accepted. Nested shapes (Hash inside Array) are not validated — the plugin must validate the inner shape itself in `#init`.
4. **Method-name match must be a Symbol.** `Prism::CallNode#name` returns a Symbol. `node.name == "users_path"` always fails; use `node.name == :users_path` or `node.name.to_s == "users_path"`.
5. **Operator method names are symbols.** `:+`, `:-`, `:<=`, etc. — not `"+"` strings.
6. **`scope.type_of(node)` not `scope[node]`.** The latter is the per-node scope index lookup; the former is the inferred type at that node's scope.
7. **`source_family` is set by the runner.** Plugin authors should NOT pass `source_family:` when constructing `Diagnostic`. The runner overwrites it with `"plugin.<manifest.id>"`.
8. **`literal_string_compatible?` vs `literal_string_carrier?`.** `compatible?` is the public predicate Rigor publishes for the "this might be a literal string" gate; `carrier?` is internal. Use `Type::Combinator.literal_string_compatible?(type)` from plugin code.
9. **Plugin source trees are excluded from RuboCop globally** (`.rubocop.yml`'s `Exclude:` list covers both `plugins/**/*` and `examples/**/*`). The integration specs under `spec/integration/plugins/` and `spec/integration/examples/` are NOT excluded — keep them within the project's RuboCop limits.
10. **The plugin's lib/ is NOT on the load path in tests.** The spec must `$LOAD_PATH.unshift(...)` before `require "rigor-<id>"`, or use a `requirer:` lambda that registers the plugin class directly.

---

## Real-Rails alignment (for `rigor-rails-*` plugins)

When authoring a Rails-side plugin (`rigor-rails-routes`, `rigor-actionpack`, `rigor-actionmailer`, `rigor-activejob`, the `rigor-activerecord` extensions, …), the plugin's behaviour MUST match what real Rails generates / accepts for the same input. Concretely:

- **Plugin source code never `require`s `rails` / `active_record` / `action_pack`.** It analyses Ruby source files, the same way the other examples do. Rigor stays decoupled from Rails.
- **Per-plugin `demo/` directories are self-contained.** No shared Rails-app skeleton across plugins — after `git subtree split` each `demo/` travels with its plugin. Some duplication of Rails-shaped tree (e.g. `app/models/application_record.rb`) is accepted in exchange for clean extraction.
- **Integration specs may exec real Rails to verify alignment.** Compare the plugin's parsed output against `rails routes -E` / `db:schema:dump` / similar real-Rails commands run against a small sample app in a tmpdir. The Rails sample app is a TEST-time tool, not a demo-time fixture.
- **The roadmap lives in [`docs/design/20260508-rails-plugins-roadmap.md`](https://github.com/rigortype/rigor/blob/master/docs/design/20260508-rails-plugins-roadmap.md).** Tier 1 plugins are unblocked on the current API. Tier 2 needs the cross-plugin API ([ADR-9](https://github.com/rigortype/rigor/blob/master/docs/adr/9-cross-plugin-api.md)) and lands after that ships.

## Cross-plugin facts (post-ADR-9)

Once ADR-9's slices land, plugins that consume facts another plugin produces use `services.fact_store`:

```ruby
# Producer side (e.g. rigor-activerecord):
class Activerecord < Plugin::Base
  manifest(id: "activerecord", version: "0.2.0", produces: [:model_index])

  def prepare(services)
    services.fact_store.publish(
      plugin_id: manifest.id, name: :model_index, value: model_index
    )
  end
end

# Consumer side (e.g. rigor-actionpack Phase 1):
class Actionpack < Plugin::Base
  manifest(
    id: "actionpack", version: "0.1.0",
    consumes: [{ plugin_id: "activerecord", name: :model_index }]
  )

  def diagnostics_for_file(path:, scope:, root:)
    ar_index = services.fact_store.read(plugin_id: "activerecord", name: :model_index)
    # ... use ar_index
  end
end
```

Until ADR-9 ships, plugins that need cross-plugin data either:

- **Duplicate the read** — read `db/schema.rb` independently even though `rigor-activerecord` already does. Acceptable as an interim measure; flag in the plugin's README that it will consolidate once ADR-9 ships.
- **Block on ADR-9** — defer the plugin until cross-plugin facts are available. Recommended for Tier 2 plugins per the roadmap.

---

## Reference index

When in doubt, read these in order:

1. **[`plugins/README.md`](https://github.com/rigortype/rigor/blob/master/plugins/README.md)** — the production-plugin catalogue. Twenty-seven plugins targeting real gems / frameworks, with the cross-plugin fact-channel table (ADR-9) and the ADR-16 substrate-consumer table. Read this when placing a new production plugin alongside its peers (Rails ecosystem tier, dry-rb family, testing-and-matchers, …).
2. **[`examples/README.md`](https://github.com/rigortype/rigor/blob/master/examples/README.md)** — the walkthrough catalogue. Five tutorial plugins over deliberately simplified virtual use cases (deprecations / lisp-eval / pattern / units / routes), one architectural surface per walkthrough. Read this to pick a structural template in Phase 2.
3. **[`docs/handbook/09-plugins.md`](https://github.com/rigortype/rigor/blob/master/docs/handbook/09-plugins.md)** — the user-facing one-pager. Names what plugins can and cannot do today.
4. **[`docs/internal-spec/plugin.md`](https://github.com/rigortype/rigor/blob/master/docs/internal-spec/plugin.md)** — slice-1 normative surface (registration, manifest, services).
5. **[`docs/internal-spec/plugin-trust.md`](https://github.com/rigortype/rigor/blob/master/docs/internal-spec/plugin-trust.md)** — slice-2 normative surface (`TrustPolicy`, `IoBoundary`).
6. **[`docs/internal-spec/plugin-cache-producers.md`](https://github.com/rigortype/rigor/blob/master/docs/internal-spec/plugin-cache-producers.md)** — slice-6 normative surface (`producer` DSL, `cache_for`).
7. **[`docs/adr/2-extension-api.md`](https://github.com/rigortype/rigor/blob/master/docs/adr/2-extension-api.md)** — binding design document. Read end-to-end before authoring a plugin that pushes the surface in a non-obvious direction.
8. **`spec/rigor/public_api_drift_spec.rb`** — pins every public namespace plugins touch. If the plugin needs a method not in the drift snapshots, the method is internal — do not depend on it.
9. **`spec/rigor/plugin/cache_producer_spec.rb`** — the "invalidates when files read via io_boundary BEFORE cache_for change between calls" example is the canonical reference for the slice-6 read-then-cache pattern.

## Closing checklist

Before declaring "the plugin is done":

- [ ] Phase 0 placement decided (`plugins/` for production, `examples/` for walkthrough) and confirmed with the user if ambiguous.
- [ ] Phase 1 questions answered explicitly by the user (not assumed).
- [ ] Template selected from Phase 2's table; no inventing.
- [ ] `plugins/rigor-<id>/` (or `examples/rigor-<id>/`) directory tree complete (gemspec, lib, demo).
- [ ] Demo runs cleanly under `rigor check`; diagnostics match the README's "What the plugin recognises" section verbatim.
- [ ] Integration spec at `spec/integration/plugins/<id>_plugin_spec.rb` (or `spec/integration/examples/<id>_plugin_spec.rb` for a walkthrough) passes; covers every diagnostic shape the plugin emits.
- [ ] README follows the structure in Phase 7.
- [ ] CHANGELOG entry under `## [Unreleased]` only.
- [ ] `make verify` clean.
- [ ] `.rigor.yml` sets `cache.path: tmp/.rigor/cache` and the demo carries a `/tmp/`-only `.gitignore`.
- [ ] `git status` shows no `.rigor/cache/` or `tmp/` directories.
- [ ] One commit, message follows AGENTS.md style.
- [ ] No `Rigor::VERSION` bump (per AGENTS.md § "Release Cadence").
