# Phases 6–10 — Integration spec, README, CHANGELOG, verify, commit

Mirror one of the existing specs under [`spec/integration/plugins/`](https://github.com/rigortype/rigor/tree/master/spec/integration/plugins/) (for production plugins) or [`spec/integration/examples/`](https://github.com/rigortype/rigor/tree/master/spec/integration/examples/) (for walkthroughs). The shared boilerplate (`run_plugin`, `plugin_diagnostics`, requirer construction, tmpdir lifecycle) lives in [`spec/integration/support/plugin_helpers.rb`](https://github.com/rigortype/rigor/blob/master/spec/integration/support/plugin_helpers.rb) and is auto-included for every `*_plugin_spec.rb` file under either directory (the `define_derived_metadata` regex matches `/spec/integration/(plugins|examples)/.+_plugin_spec\.rb`). The spec only needs the per-plugin parts.

```ruby
# spec/integration/plugins/<id>_plugin_spec.rb
# (use spec/integration/examples/<id>_plugin_spec.rb for a walkthrough)
# frozen_string_literal: true

require "spec_helper"

# Adjust the lib path to match Phase 0's placement: plugins/ vs examples/.
PLUGIN_LIB = File.expand_path("../../plugins/rigor-<id>/lib", __dir__)
$LOAD_PATH.unshift(PLUGIN_LIB) unless $LOAD_PATH.include?(PLUGIN_LIB)
require "rigor-<id>"

RSpec.describe "plugins/rigor-<id>" do # rubocop:disable RSpec/DescribeClass
  before { Rigor::Plugin.unregister! }
  after { Rigor::Plugin.unregister! }

  let(:plugin_class) { Rigor::Plugin::ClassName }

  it "describes a recognised diagnostic shape" do
    diags = plugin_diagnostics(run_plugin(source: "Some.call(...)\n"))
    expect(diags.first.message).to include("...")
  end

  # When the plugin needs project files (config/routes.yml,
  # db/schema.rb, app/models/*.rb), pass `files:`:
  it "validates against an external schema" do
    diags = plugin_diagnostics(run_plugin(
      source: "Model.find(1)\n",
      files: { "db/schema.rb" => "..." }
    ))
    # ...
  end

  # When the plugin needs a non-default config:
  it "honours custom config" do
    diags = plugin_diagnostics(run_plugin(
      source: "...",
      plugin_entry: { "gem" => "rigor-<id>", "config" => { "key" => "value" } }
    ))
    # ...
  end

  # When the spec needs multiple runs against the same tmpdir
  # (cache invalidation tests etc.), use the lower-level
  # run_plugin_in_dir helper:
  it "exercises cache invalidation" do
    Dir.mktmpdir do |dir|
      Rigor::Plugin.unregister!
      run_plugin_in_dir(
        dir: dir, source: "...",
        cache_store: cache_store,
        files: { "config/something.yml" => "..." }
      )

      Rigor::Plugin.unregister!
      run_plugin_in_dir(
        dir: dir, source: "...",
        cache_store: cache_store,
        files: { "config/something.yml" => "...changed..." }
      )
    end
  end
end
```

## What the helpers provide

| Helper | When to use |
| --- | --- |
| `run_plugin(source:, ...)` | The default. Creates a tmpdir, writes `demo.rb` and any `files:`, runs `Analysis::Runner`, returns `Result`. Auto-`unregister!`s the plugin registry on entry. |
| `run_plugin_in_dir(dir:, source:, ...)` | Lower-level: takes an existing tmpdir. Use for multi-run tests against the same project (cache invalidation, second-run-after-edit scenarios). Does NOT auto-unregister; the caller controls lifecycle. |
| `plugin_diagnostics(result)` | Filters a result down to `source_family == "plugin.<manifest.id>"`. Reads the id from `plugin_class.manifest.id` via the spec's `let`. |
| `build_plugin_requirer` | The requirer lambda the loader expects. For specs that drive `Analysis::Runner` themselves. |
| `materialize_files(dir, files)` | Convenience: writes `{path => contents}` into `dir`. |

The helpers read `plugin_class` via RSpec's method resolution chain, so the `let(:plugin_class) { ... }` declaration is the only spec-specific binding callers need.

## Spec gotchas

- **Plugin re-registration across runs.** `run_plugin` always calls `Rigor::Plugin.unregister!` on entry. `run_plugin_in_dir` does NOT — multi-run tests must call `unregister!` between invocations themselves. See `routes_plugin_spec.rb`'s `run_routes_in_dir_twice` for the canonical pattern.
- **`Dir.chdir` happens inside the helpers.** Relative paths (e.g. `config/routes.yml` from a plugin's `IoBoundary` read) resolve against the tmpdir, not the host CWD.
- **`spec/support/runner_helpers.rb`'s `analyze` doesn't load plugins.** That helper is for analyser-internal specs. Plugin specs use `run_plugin` from `plugin_helpers.rb`.

---

## Phase 7 — README

Use the README structure from `examples/rigor-routes/README.md` as the template. Required sections:

1. **Headline** — one paragraph naming what the plugin types and which architecture facet it primarily exercises.
2. **What the plugin recognises** — a `text` block of sample diagnostics (info + error rows). Match `rigor check`'s actual output verbatim.
3. **Layout** — directory tree.
4. **Running the demo** — `cd plugins/rigor-<id>/demo` + `RUBYLIB=...`.
5. **Plugin authoring surface this exercises** — table of which surfaces (manifest / config_schema / IoBoundary / cache producer / Scope#type_of / etc.) the plugin touches.
6. **Future direction** — boilerplate paragraph about plugin return-type contributions being queued for v0.1.x. Copy from another example's README and adapt.
7. **License** — `MPL-2.0, matching the parent Rigor project.`

## Phase 8 — CHANGELOG entry

Per `AGENTS.md` § "Release Cadence", add the entry under `## [Unreleased]` only — do NOT bump `Rigor::VERSION`. The user drives the cut-over.

```markdown
### Added — plugin: `rigor-<id>`

- **One-line description.** Two-to-three-sentence body describing the
  user-facing diagnostics, the architecture facet, and how to run
  the demo.
- **Configuration.** What the user puts in `.rigor.yml`.
- **Demo project** under `plugins/rigor-<id>/demo/` (or `examples/rigor-<id>/demo/` for a walkthrough).
- **Integration spec** at `spec/integration/plugins/<id>_plugin_spec.rb` (or `spec/integration/examples/<id>_plugin_spec.rb` for a walkthrough) — N examples covering …
```

## Phase 9 — Verify

Run the full Flake-mediated verification:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command make verify
nix --extra-experimental-features 'nix-command flakes' develop --command git diff --check
```

`make verify` must report:

- RSpec passing (the new integration spec adds N examples to the total).
- RuboCop 0 offenses (the plugin's own source is excluded by `.rubocop.yml`'s `plugins/**/*` and `examples/**/*` rules, but the integration spec under `spec/integration/{plugins,examples}/` IS linted — keep it under the per-example length / multiple-expectations limits, or add inline `# rubocop:disable` with a reason).
- `bundle exec exe/rigor check lib` reporting only the three documented pre-existing warnings (`Trinary#negate`, `IntegerRange#lower` / `#upper`).

## Phase 10 — Commit

One commit per plugin is preferred. Subject:

```text
Add rigor-<id> plugin (<facet>)             # for plugins/rigor-<id>/
Add rigor-<id> walkthrough (<facet>)        # for examples/rigor-<id>/
```

Body: explain WHY this plugin was needed (the user's requirement), WHICH facet it primarily exercises, and HOW the integration spec locks the diagnostic shape. ~72-column wrap.

The `tmp/`-anchored cache plus the per-demo `.gitignore` keep demo verification artefacts out of git automatically — `git status` should not list anything cache-related. (Older demos that set the default `.rigor/cache/` are caught by the repo-root `.gitignore`'s non-anchored `.rigor/cache/` pattern as a fallback.)
