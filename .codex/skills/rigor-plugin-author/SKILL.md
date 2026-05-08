---
name: rigor-plugin-author
description: End-to-end workflow for an AI agent to translate a user requirement into a working Rigor plugin under `examples/`. Use when the user asks to "create a Rigor plugin for X", "write a plugin that does Y", "extend Rigor for our DSL", or similar. Covers requirements gathering, template selection, scaffolding, integration spec, and verification.
---

# Rigor Plugin Author Workflow

This SKILL is for AI agents. It compresses the experience of having
authored the thirteen examples under [`examples/`](../../../examples/README.md)
(eight plugin-contract walkthroughs plus the Rails ecosystem
family — `rigor-rails-routes`, `rigor-rails-i18n`, `rigor-actionmailer`,
`rigor-activejob`, `rigor-pundit`) into a procedural pipeline so the
next plugin can be built end-to-end without re-discovering the gotchas.

The user-facing handbook for plugin **authoring** is the
[`examples/README.md`](../../../examples/README.md) landing page.
This document is the agent-facing **how-to-build** companion.

All commands MUST run through the Flake per `AGENTS.md`.

---

## Phase 0 — When this SKILL fires

Trigger the SKILL when the user requests a plugin in the broad
sense:

- "Rigor で X を解析するプラグインを作って"
- "Create a Rigor plugin that catches Y"
- "Extend Rigor to understand our DSL Z"
- "Write a plugin similar to rigor-units but for currency"

Do NOT trigger for:

- Modifications to existing plugins under `examples/` (those are
  ordinary edit tasks).
- Requests for the analyser engine itself (`lib/rigor/inference/`,
  `lib/rigor/analysis/`, `lib/rigor/plugin/`). Those are core
  development; this SKILL only covers writing third-party-style
  plugins under `examples/`.

---

## Phase 1 — Requirements gathering

Before any code, get the user to commit to answers for **all five**
of these. Ask them as a single message; do NOT scaffold anything
yet. The answers narrow the architecture choice in Phase 2.

### Q1. Trigger surface — what call shape activates the plugin?

- A. A specific module / class method (`Module.method(...)`,
  `Class#method(...)`).
- B. A specific implicit-receiver method (top-level `helper(...)`).
- C. A method whose name matches a pattern (`*_path`, `*_url`,
  `transition_to_*`).
- D. A constructor chain on a built-in type
  (`100.kilometers`, `"x".validates_as(:email)`).
- E. A DSL block (`state_machine do ... end`,
  `validates_with do ... end`).

### Q2. What does the plugin need to LOOK at?

- A. Just the call site (literal arguments, immediate receiver).
- B. The local-variable bindings flowing INTO the call site
  (variable came from earlier in the file).
- C. Declarations from EARLIER in the same file (a `state` block
  before the `transition_to` call).
- D. Declarations from ANOTHER file in the project (cross-file).
- E. An external resource — `config/routes.yml`, `db/schema.rb`,
  `config/locales/*.yml`.

### Q3. What does the plugin need to PROVE?

- A. The argument is one of a known finite set (route name, state
  name, deprecated method name).
- B. The argument's literal value matches a pattern (regex, format
  string).
- C. The arguments compose dimensionally (Distance + Distance =
  Distance, Distance + Time = error).
- D. The arity / shape matches a declared signature.
- E. The literal expression evaluates to a known type (Lisp eval
  pattern).

### Q4. What diagnostic output does the user want?

- A. **Info-only** — surface the inferred type / matched name as a
  trace, no errors.
- B. **Error on mismatch** — flag wrong inputs, otherwise stay
  silent.
- C. **Both** — info on success, error on mismatch.
- D. **Warning** for deprecation / soft contract violation.

### Q5. What is the plugin's CONFIGURATION shape?

- A. **None** — behaviour is hard-coded.
- B. **A few string knobs** (`module_name`, `severity`).
- C. **A list / hash of rules** (deprecation entries, regex
  patterns).
- D. **An external file path** (`routes_file: "config/routes.yml"`).
- E. **All of the above** (rich configuration).

---

## Phase 2 — Template selection

Map the answers to one of the six existing examples. Use the chosen
example as the **structural template** — copy the directory layout
and adapt the analyser body. Do NOT start from scratch.

| If the answers look like… | Use template | Why |
| --- | --- | --- |
| Q1=A/B, Q2=A, Q3=A, Q5=C | [`rigor-deprecations`](../../../examples/rigor-deprecations/) | Smallest possible plugin; pure config-driven rules; ~80 lines. |
| Q1=A, Q2=A, Q3=E, Q5=A/B | [`rigor-lisp-eval`](../../../examples/rigor-lisp-eval/) | Recursive interpretation of the literal AST argument. |
| Q1=D, Q2=B, Q3=C, Q5=A | [`rigor-units`](../../../examples/rigor-units/) | Local-variable flow tracking through arithmetic and chained calls. |
| Q1=C/E, Q2=C, Q3=A, Q5=A/B | [`rigor-statesman`](../../../examples/rigor-statesman/) | Two-pass DSL analysis — collect declarations, then validate uses. |
| Q1=B, Q2=A/B, Q3=B, Q5=C | [`rigor-pattern`](../../../examples/rigor-pattern/) | Plugin asks the analyser via `Scope#type_of` + `literal_string_compatible?`; matches against a literal value. |
| Q1=A/B/C, Q2=E, Q3=A/D, Q5=C/D | [`rigor-routes`](../../../examples/rigor-routes/) | Reads a project file via `IoBoundary` under `TrustPolicy`; caches the parse via `Plugin::Base.producer`. |

If the requirement falls into NONE of the six, **stop and ask the
user**. The plugin contract surface in v0.1.0 may not yet expose
what they need (e.g. plugin-emitted return-type contributions are
queued for a v0.1.x slice — see the "Future direction" sections in
the example READMEs). Don't invent a workaround.

---

## Phase 3 — Scaffold

Pick a plugin id and gem name following the convention:

- **Plugin id** — kebab-case, lowercase, descriptive. Matches
  `Rigor::Plugin::Manifest::VALID_ID` (`/\A[a-z][a-z0-9._-]*\z/`).
  Examples: `routes`, `lisp-eval`, `deprecations`.
- **Gem name** — `rigor-<id>`. The plugin loader calls
  `require "rigor-<id>"` from each `.rigor.yml` `plugins:` entry.

Create the directory tree (replacing `<id>` and `ClassName` with the
chosen id and matching CamelCase Ruby class name):

```text
examples/rigor-<id>/
├── README.md
├── rigor-<id>.gemspec
├── lib/
│   ├── rigor-<id>.rb              ← gem entry; `require_relative "rigor/plugin/<id>"`
│   └── rigor/plugin/
│       └── <id>.rb                ← manifest, init, hook (small plugins keep all here)
│       └── <id>/                  ← only if the plugin has helpers
│           ├── analyzer.rb        ← AST walker (units / statesman pattern)
│           ├── method_table.rb    ← pure dispatch table (units pattern)
│           └── route_table.rb     ← parsed external state (routes pattern)
└── demo/
    ├── .rigor.yml                 ← `plugins: [rigor-<id>]`
    ├── demo.rb                    ← runnable example (no errors)
    ├── errors_demo.rb             ← intentionally ill-typed (only if Q4=B/C)
    ├── lib/runtime.rb             ← user-side runtime so demo.rb runs
    └── sig/...rbs                 ← only if the demo references typed method calls
```

### Gemspec template

```ruby
# rigor-<id>.gemspec
# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "rigor-<id>"
  spec.version = "0.1.0"
  spec.authors = ["Rigor contributors"]
  spec.email = ["maintainers@example.invalid"]

  spec.summary = "Rigor plugin example: <one-line description>."
  spec.description = "<two-sentence description that names the user-facing API the plugin types>."
  spec.license = "MPL-2.0"
  spec.required_ruby_version = [">= 4.0.0", "< 4.1"]
  spec.metadata = { "rubygems_mfa_required" => "true" }

  spec.files = Dir.glob(%w[README.md lib/**/*.rb])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
```

### Plugin entry template (`lib/rigor-<id>.rb`)

```ruby
# frozen_string_literal: true

require_relative "rigor/plugin/<id>"
```

### Plugin class skeleton (`lib/rigor/plugin/<id>.rb`)

```ruby
# frozen_string_literal: true

require "rigor/plugin"

module Rigor
  module Plugin
    class ClassName < Rigor::Plugin::Base
      manifest(
        id: "<id>",
        version: "0.1.0",
        description: "<one-line>",
        config_schema: {
          # Phase 1 Q5 answers map here. Examples:
          # "module_name" => :string,
          # "rules" => :array,
          # "patterns" => :hash,
        }
      )

      def init(_services)
        # Read config defaults. See template-specific section below.
      end

      def diagnostics_for_file(path:, scope:, root:)
        # Walk `root` (Prism::Node), return Array<Rigor::Analysis::Diagnostic>.
        # See template-specific section below.
      end

      private

      # Diagnostic constructor helper — every plugin uses this shape.
      def diagnostic(path, node, severity:, rule:, message:)
        location = node.location
        Rigor::Analysis::Diagnostic.new(
          path: path,
          line: location.start_line,
          column: location.start_column + 1,
          message: message,
          severity: severity,
          rule: rule
        )
      end
    end

    Rigor::Plugin.register(ClassName)
  end
end
```

---

## Phase 4 — AST walker pattern (per template)

The analyser body inside `#diagnostics_for_file` is the part that
varies most by template. Don't invent a new walker — copy the
matching example's `lib/rigor/plugin/<id>/analyzer.rb` (or the
inline walker in the small plugins) and adapt the dispatch table.

### Template-specific reference points

- **rigor-deprecations** — single-pass walk, match `CallNode` against
  config rules. See `lib/rigor/plugin/deprecations.rb` `each_call`
  helper.
- **rigor-lisp-eval** — recursive evaluation of a literal AST
  argument. See `lib/rigor/plugin/lisp_eval/interpreter.rb#evaluate`
  for the recursion pattern; arrives at a tag (`:integer` /
  `:float` / `:bool`) bottom-up.
- **rigor-units** — `evaluate(node)` returns a dimension tag while
  threading `@bindings` (a Hash<Symbol, Symbol> of local-variable
  name → dimension tag). On `LocalVariableWriteNode`, evaluate the
  RHS and store the result. See
  `lib/rigor/plugin/units/analyzer.rb#evaluate`.
- **rigor-statesman** — two passes: `collect_states(root)` produces a
  Set; `validate_transitions(root, states)` consults it. See
  `lib/rigor/plugin/statesman.rb` `collect_states` /
  `validate_transitions`.
- **rigor-pattern** — the walker calls `scope.type_of(arg_node)` to
  ASK the analyser for the inferred type, then `literal_string_compatible?`
  to gate further checks. See `lib/rigor/plugin/pattern.rb`
  `analyse_call` and `literal_value_of`.
- **rigor-routes** — single-pass walk for `*_path` / `*_url` calls,
  but the route table is loaded via `cache_for(:route_table)` (see
  Phase 4.5).

### Phase 4.5 — IoBoundary + cache producer (rigor-routes only)

If Phase 1 Q2=E (external file), the plugin uses slice 2 + slice 6.
The exact pattern is documented in `cache_producer_spec.rb` — but
it is a TRAP if you get it wrong. The rule is:

```ruby
producer :route_table do |_params|
  contents = io_boundary.read_file(@routes_file)
  RouteTable.parse(contents)
end

def diagnostics_for_file(path:, scope:, root:)
  table = route_table  # see below
  # ... walker
end

private

def route_table
  return @table if @table

  # CRITICAL: read the file BEFORE cache_for so the IoBoundary's
  # FileEntry digest is captured in the descriptor at cache_for time.
  # If you read AFTER, the cache key has no file digest and never
  # invalidates.
  io_boundary.read_file(@routes_file)
  @table = cache_for(:route_table, params: {}).call
rescue Plugin::AccessDeniedError, Errno::ENOENT, Psych::SyntaxError => e
  @load_error = "rigor-#{manifest.id}: #{e.message}"
  nil
end
```

Demo `.rigor.yml` may need `plugins_io.allowed_paths:` if the
plugin reads from outside the project root + signature paths.

---

## Phase 5 — Demo

The demo project under `examples/rigor-<id>/demo/` makes the plugin
runnable. Two-file convention when Q4 is B or C:

- `demo.rb` — only the recognised / valid call sites. Runs cleanly
  under MRI.
- `errors_demo.rb` — intentionally ill-typed code that exercises the
  `:error` paths. Add a header comment: "DO NOT run via `ruby
  errors_demo.rb` — analyse with `rigor check`."

The `.rigor.yml` `paths:` lists both, so `rigor check` analyses
both. Set `cache.path` to a `tmp/`-anchored directory so the
cache is strictly per-demo and survives the eventual
`git subtree split`:

```yaml
paths:
  - demo.rb
  - errors_demo.rb

plugins:
  - rigor-<id>

cache:
  path: tmp/.rigor/cache
```

Pair it with a per-demo `.gitignore` so the cache stays out of git:

```
# examples/rigor-<id>/demo/.gitignore
/tmp/
```

Verify the demo runs:

```sh
cd examples/rigor-<id>/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../../Gemfile \
  rigor check
```

The diagnostic stream should match what the README claims. The
`tmp/` cache layout keeps demo runs from polluting the repo —
`git status` after the run should be clean.

---

## Phase 6 — Integration spec

Mirror one of the existing specs under
`spec/integration/examples/`. The shared boilerplate
(`run_plugin`, `plugin_diagnostics`, requirer construction,
tmpdir lifecycle) lives in
[`spec/integration/examples/support/plugin_helpers.rb`](../../../spec/integration/examples/support/plugin_helpers.rb)
and is auto-included for every `*_plugin_spec.rb` file under
that directory. The spec only needs the per-plugin parts.

```ruby
# spec/integration/examples/<id>_plugin_spec.rb
# frozen_string_literal: true

require "spec_helper"

PLUGIN_LIB = File.expand_path("../../../examples/rigor-<id>/lib", __dir__)
$LOAD_PATH.unshift(PLUGIN_LIB) unless $LOAD_PATH.include?(PLUGIN_LIB)
require "rigor-<id>"

RSpec.describe "examples/rigor-<id>" do # rubocop:disable RSpec/DescribeClass
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

### What the helpers provide

| Helper | When to use |
| --- | --- |
| `run_plugin(source:, ...)` | The default. Creates a tmpdir, writes `demo.rb` and any `files:`, runs `Analysis::Runner`, returns `Result`. Auto-`unregister!`s the plugin registry on entry. |
| `run_plugin_in_dir(dir:, source:, ...)` | Lower-level: takes an existing tmpdir. Use for multi-run tests against the same project (cache invalidation, second-run-after-edit scenarios). Does NOT auto-unregister; the caller controls lifecycle. |
| `plugin_diagnostics(result)` | Filters a result down to `source_family == "plugin.<manifest.id>"`. Reads the id from `plugin_class.manifest.id` via the spec's `let`. |
| `build_plugin_requirer` | The requirer lambda the loader expects. For specs that drive `Analysis::Runner` themselves. |
| `materialize_files(dir, files)` | Convenience: writes `{path => contents}` into `dir`. |

The helpers read `plugin_class` via RSpec's method resolution
chain, so the `let(:plugin_class) { ... }` declaration is the
only spec-specific binding callers need.

### Spec gotchas

- **Plugin re-registration across runs.** `run_plugin` always
  calls `Rigor::Plugin.unregister!` on entry. `run_plugin_in_dir`
  does NOT — multi-run tests must call `unregister!` between
  invocations themselves. See
  `routes_plugin_spec.rb`'s `run_routes_in_dir_twice` for the
  canonical pattern.
- **`Dir.chdir` happens inside the helpers.** Relative paths
  (e.g. `config/routes.yml` from a plugin's `IoBoundary` read)
  resolve against the tmpdir, not the host CWD.
- **`spec/support/runner_helpers.rb`'s `analyze` doesn't load
  plugins.** That helper is for analyser-internal specs. Plugin
  specs use `run_plugin` from `plugin_helpers.rb`.

---

## Phase 7 — README

Use the README structure from `examples/rigor-routes/README.md` as
the template. Required sections:

1. **Headline** — one paragraph naming what the plugin types and
   which architecture facet it primarily exercises.
2. **What the plugin recognises** — a `text` block of sample
   diagnostics (info + error rows). Match `rigor check`'s actual
   output verbatim.
3. **Layout** — directory tree.
4. **Running the demo** — `cd examples/rigor-<id>/demo` + `RUBYLIB=...`.
5. **Plugin authoring surface this exercises** — table of which
   surfaces (manifest / config_schema / IoBoundary / cache producer
   / Scope#type_of / etc.) the plugin touches.
6. **Future direction** — boilerplate paragraph about plugin return-
   type contributions being queued for v0.1.x. Copy from another
   example's README and adapt.
7. **License** — `MPL-2.0, matching the parent Rigor project.`

---

## Phase 8 — CHANGELOG entry

Per `AGENTS.md` § "Release Cadence", add the entry under
`## [Unreleased]` only — do NOT bump `Rigor::VERSION`. The user
drives the cut-over.

```markdown
### Added — example plugin: `rigor-<id>`

- **One-line description.** Two-to-three-sentence body describing the
  user-facing diagnostics, the architecture facet, and how to run
  the demo.
- **Configuration.** What the user puts in `.rigor.yml`.
- **Demo project** under `examples/rigor-<id>/demo/`.
- **Integration spec** at `spec/integration/examples/<id>_plugin_spec.rb` — N examples covering …
```

---

## Phase 9 — Verify

Run the full Flake-mediated verification:

```sh
nix --extra-experimental-features 'nix-command flakes' develop --command make verify
nix --extra-experimental-features 'nix-command flakes' develop --command git diff --check
```

`make verify` must report:

- RSpec passing (the new integration spec adds N examples to the
  total).
- RuboCop 0 offenses (the example's own source is excluded by
  `.rubocop.yml`'s `examples/**/*` rule, but the integration spec
  IS linted — keep it under the per-example length / multiple-
  expectations limits, or add inline `# rubocop:disable` with a
  reason).
- `bundle exec exe/rigor check lib` reporting only the three
  documented pre-existing warnings (`Trinary#negate`,
  `IntegerRange#lower` / `#upper`).

---

## Phase 10 — Commit

One commit per plugin is preferred. Subject:

```text
Add rigor-<id> example plugin (<facet>)
```

Body: explain WHY this plugin was needed (the user's requirement),
WHICH facet it primarily exercises, and HOW the integration spec
locks the diagnostic shape. ~72-column wrap.

The `tmp/`-anchored cache plus the per-demo `.gitignore` keep
demo verification artefacts out of git automatically — `git status`
should not list anything cache-related. (Older demos that set the
default `.rigor/cache/` are caught by the repo-root `.gitignore`'s
non-anchored `.rigor/cache/` pattern as a fallback.)

---

## Common pitfalls (the "got me last time" list)

1. **Cache directory in the demo gets committed.** Each demo's
   `.rigor.yml` MUST set `cache.path: tmp/.rigor/cache` AND each
   demo MUST carry a `/tmp/`-only `.gitignore` (the repo-root
   `.gitignore` catches `/tmp/` only at the root). Demos that
   miss either piece can leak cache artefacts into commits. The
   repo-root `.gitignore`'s non-anchored `.rigor/cache/` pattern
   is a fallback for older demos that still default to that path.
2. **Plugin id collisions in tests.** `Rigor::Plugin.unregister!`
   in `before` AND `after` for every plugin spec; otherwise spec
   ordering bleeds plugin state across files.
3. **Manifest config_schema kinds.** Only `:string` / `:boolean` /
   `:integer` / `:array` / `:hash` / `:any` are accepted. Nested
   shapes (Hash inside Array) are not validated — the plugin must
   validate the inner shape itself in `#init`.
4. **Method-name match must be a Symbol.** `Prism::CallNode#name`
   returns a Symbol. `node.name == "users_path"` always fails;
   use `node.name == :users_path` or `node.name.to_s == "users_path"`.
5. **Operator method names are symbols.** `:+`, `:-`, `:<=`, etc.
   not `"+"` strings.
6. **`scope.type_of(node)` not `scope[node]`.** The latter is the
   per-node scope index lookup; the former is the inferred type at
   that node's scope.
7. **`source_family` is set by the runner.** Plugin authors should
   NOT pass `source_family:` when constructing `Diagnostic`. The
   runner overwrites it with `"plugin.<manifest.id>"`.
8. **`literal_string_compatible?` vs `literal_string_carrier?`.**
   `compatible?` is the public predicate Rigor publishes for the
   "this might be a literal string" gate; `carrier?` is internal.
   Use `Type::Combinator.literal_string_compatible?(type)` from
   plugin code.
9. **Examples are excluded from RuboCop globally** (`.rubocop.yml`'s
   `Exclude:` list). The integration spec under
   `spec/integration/examples/` is NOT excluded — keep it within
   the project's RuboCop limits.
10. **The plugin's lib/ is NOT on the load path in tests.** The
    spec must `$LOAD_PATH.unshift(...)` before `require "rigor-<id>"`,
    or use a `requirer:` lambda that registers the plugin class
    directly.

---

## Real-Rails alignment (for `rigor-rails-*` plugins)

When authoring a Rails-side plugin (`rigor-rails-routes`,
`rigor-actionpack`, `rigor-actionmailer`, `rigor-activejob`,
the `rigor-activerecord` extensions, …), the plugin's
behaviour MUST match what real Rails generates / accepts for
the same input. Concretely:

- **Plugin source code never `require`s `rails` /
  `active_record` / `action_pack`.** It analyses Ruby source
  files, the same way the other examples do. Rigor stays
  decoupled from Rails.
- **Per-plugin `demo/` directories are self-contained.** No
  shared Rails-app skeleton across plugins — after
  `git subtree split` each `demo/` travels with its plugin.
  Some duplication of Rails-shaped tree (e.g.
  `app/models/application_record.rb`) is accepted in exchange
  for clean extraction.
- **Integration specs may exec real Rails to verify
  alignment.** Compare the plugin's parsed output against
  `rails routes -E` / `db:schema:dump` / similar real-Rails
  commands run against a small sample app in a tmpdir. The
  Rails sample app is a TEST-time tool, not a demo-time
  fixture.
- **The roadmap lives in
  [`docs/design/20260508-rails-plugins-roadmap.md`](../../../docs/design/20260508-rails-plugins-roadmap.md).**
  Tier 1 plugins are unblocked on the current API. Tier 2
  needs the cross-plugin API ([ADR-9](../../../docs/adr/9-cross-plugin-api.md))
  and lands after that ships.

## Cross-plugin facts (post-ADR-9)

Once ADR-9's slices land, plugins that consume facts another
plugin produces use `services.fact_store`:

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

Phase 4.7 of this SKILL — gets a full section once ADR-9 ships
and the API surface is in `spec/rigor/public_api_drift_spec.rb`.
Until then, plugins that need cross-plugin data either:

- **duplicate the read** — read `db/schema.rb` independently
  even though `rigor-activerecord` already does. Acceptable as
  an interim measure; flag in the plugin's README that it'll
  consolidate once ADR-9 ships.
- **block on ADR-9** — defer the plugin until cross-plugin
  facts are available. Recommended for Tier 2 plugins per the
  roadmap.

## Reference index

When in doubt, read these in order:

1. **[`examples/README.md`](../../../examples/README.md)** — the
   landing page. Comparison table and recommended reading order
   across the thirteen worked examples (eight plugin-contract
   walkthroughs + five Rails ecosystem plugins covering Tier 1
   + Tier 3B).
2. **[`docs/handbook/09-plugins.md`](../../../docs/handbook/09-plugins.md)**
   — the user-facing one-pager. Names what plugins can and cannot
   do today.
3. **[`docs/internal-spec/plugin.md`](../../../docs/internal-spec/plugin.md)**
   — slice-1 normative surface (registration, manifest, services).
4. **[`docs/internal-spec/plugin-trust.md`](../../../docs/internal-spec/plugin-trust.md)**
   — slice-2 normative surface (`TrustPolicy`, `IoBoundary`).
5. **[`docs/internal-spec/plugin-cache-producers.md`](../../../docs/internal-spec/plugin-cache-producers.md)**
   — slice-6 normative surface (`producer` DSL, `cache_for`).
6. **[`docs/adr/2-extension-api.md`](../../../docs/adr/2-extension-api.md)**
   — binding design document. Read end-to-end before authoring a
   plugin that pushes the surface in a non-obvious direction.
7. **`spec/rigor/public_api_drift_spec.rb`** — pins every public
   namespace plugins touch. If the plugin needs a method not in
   the drift snapshots, the method is internal — do not depend on
   it.
8. **`spec/rigor/plugin/cache_producer_spec.rb`** — the
   "invalidates when files read via io_boundary BEFORE cache_for
   change between calls" example is the canonical reference for
   the slice-6 read-then-cache pattern.

---

## Closing checklist

Before declaring "the plugin is done":

- [ ] Phase 1 questions answered explicitly by the user (not
      assumed).
- [ ] Template selected from Phase 2's table; no inventing.
- [ ] `examples/rigor-<id>/` directory tree complete (gemspec,
      lib, demo).
- [ ] Demo runs cleanly under `rigor check`; diagnostics match the
      README's "What the plugin recognises" section verbatim.
- [ ] Integration spec at `spec/integration/examples/<id>_plugin_spec.rb`
      passes; covers every diagnostic shape the plugin emits.
- [ ] README follows the structure in Phase 7.
- [ ] CHANGELOG entry under `## [Unreleased]` only.
- [ ] `make verify` clean.
- [ ] `.rigor.yml` sets `cache.path: tmp/.rigor/cache` and the
      demo carries a `/tmp/`-only `.gitignore`.
- [ ] `git status` shows no `.rigor/cache/` or `tmp/` directories.
- [ ] One commit, message follows AGENTS.md style.
- [ ] No `Rigor::VERSION` bump (per AGENTS.md § "Release Cadence").
