# Phases 3–5 — Scaffold, walker pattern, demo

Pick a plugin id and gem name following the convention:

- **Plugin id** — kebab-case, lowercase, descriptive. Matches `Rigor::Plugin::Manifest::VALID_ID` (`/\A[a-z][a-z0-9._-]*\z/`). Examples: `routes`, `lisp-eval`, `deprecations`.
- **Gem name** — `rigor-<id>`. The plugin loader calls `require "rigor-<id>"` from each `.rigor.yml` `plugins:` entry.

Create the directory tree (replacing `<id>` and `ClassName` with the chosen id and matching CamelCase Ruby class name; substitute `examples/` for `plugins/` if Phase 0 placed the plugin there):

```text
plugins/rigor-<id>/   # or examples/rigor-<id>/ for a walkthrough
├── README.md
│                      # NOTE: a bundled plugin has NO gemspec — it ships
│                      # inside the single `rigortype` gem (ADR-31). Add a
│                      # `rigor-<id>.gemspec` ONLY for a third-party plugin
│                      # in its own repo (see "Gemspec template" below).
├── lib/
│   ├── rigor-<id>.rb              ← gem entry; require_relative "rigor/plugin/<id>"
│   └── rigor/plugin/
│       └── <id>.rb                ← manifest, init, hook (small plugins keep all here)
│       └── <id>/                  ← only if the plugin has helpers
│           ├── analyzer.rb        ← AST walker (units / statesman pattern)
│           ├── method_table.rb    ← pure dispatch table (units pattern)
│           └── route_table.rb     ← parsed external state (routes pattern)
└── demo/
    ├── .rigor.yml                 ← plugins: [rigor-<id>]
    ├── demo.rb                    ← runnable example (no errors)
    ├── errors_demo.rb             ← intentionally ill-typed (only if Q4=B/C)
    ├── lib/runtime.rb             ← user-side runtime so demo.rb runs
    └── sig/...rbs                 ← only if the demo references typed method calls
```

## Gemspec template (third-party plugins only)

**Skip this for a bundled plugin** (under `plugins/` or `examples/` in
this repo) — bundled plugins have no gemspec; they ship inside the single
`rigortype` gem (ADR-31, per-plugin gemspecs dropped in commit
`9769f5fa`). This template is for a **third-party** plugin authored in
its own repo (ADR-31 WD4), depending on `gem "rigortype"`:

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

## Plugin entry template (`lib/rigor-<id>.rb`)

```ruby
# frozen_string_literal: true

require_relative "rigor/plugin/<id>"
```

## Plugin class skeleton (`lib/rigor/plugin/<id>.rb`)

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
        # Read config defaults. See the analyser-body notes below.
      end

      # ADR-37: the engine owns the AST walk and dispatches every
      # matching node to this rule. Return Array<Rigor::Analysis::Diagnostic>,
      # positioned with the inherited `diagnostic(node, …)` helper (no
      # hand-rolled constructor). `context` (NodeContext) carries the
      # lexical ancestors when the check is context-dependent.
      node_rule Prism::CallNode do |node, scope, path, _file_context, _context|
        []
      end
    end

    Rigor::Plugin.register(ClassName)
  end
end
```

The inherited `Base#diagnostic(node, path:, message:, severity:, rule:,
location:)` builds the `Rigor::Analysis::Diagnostic` (1-based `line` /
`start_column + 1`, `plugin.<id>` stamped by the runner) — pass
`location: node.message_loc` to point at the method name. Do not
hand-roll a `Diagnostic.new` constructor or set `source_family`.

---

The rule body — recognising the DSL's call shapes — is the part that varies most by template. Don't invent a walker (the engine owns it now); keep non-trivial logic in a `lib/rigor/plugin/<id>/analyzer.rb` that takes the call node and returns location-free `Violation`s the rule positions with `diagnostic` (the `Analyzer.violations_for` split every bundled plugin uses — it also makes the logic unit-testable).

## Don't reimplement the target library (ADR-39)

When the DSL's analysis needs a *fact* the target library computes — an inflection (`users` → `User`), a status-code table, a name convention — **call the real library, don't reimplement it** ([ADR-39](../../../../docs/adr/39-plugin-target-library-invocation.md)). A hand-rolled approximation that diverges from the library's real behaviour produces a wrong derived fact = a false positive (this is why `rigor-rails-routes` / `rigor-activerecord` / `rigor-actionpack` / `rigor-actionmailer` / `rigor-factorybot` dropped their hand-rolled inflectors onto the shared `Rigor::Plugin::Inflector`, which calls the real `ActiveSupport::Inflector`). Declare the target gem on the plugin's gemspec; call only a **fixed allow-list of pure methods**; and **decline (emit nothing) when the library is unavailable — never approximate**. The isolation of the call (in-process / forked worker / `Ruby::Box`) is the user-selectable `plugins_isolation:` strategy (`process` by default) handled by `Plugin::Isolation` — you just call the method. For "did you mean …?" use `Rigor::Plugin::Base.suggest(name, candidates)` (DidYouMean-backed), not a hand-rolled Levenshtein.

## Template-specific reference points

These bundled plugins are all migrated onto `node_rule` — read one as a worked example of the shape you need:

- **rigor-deprecations** — `node_rule(Prism::CallNode)` matching against config rules; the simplest single-rule plugin. See `lib/rigor/plugin/deprecations.rb`.
- **rigor-statesman** — two-pass via `node_file_context` (collect declared states once) + `node_rule` (validate transitions against them). See `lib/rigor/plugin/statesman.rb`.
- **rigor-shoulda-matchers** / **rigor-actionpack** — context-dependent rules that read the enclosing `describe <Model>` / controller from the `NodeContext` ancestors. See `lib/rigor/plugin/shoulda_matchers.rb` and `plugins/rigor-actionpack/lib/rigor/plugin/actionpack.rb` (its `Analyzer.*_violations_for` split + `enclosing_controller_name`).
- **rigor-rails-routes** — `node_file_context` (same-file shadowing set) + `node_rule` + a `produces:` fact (`:helper_table`) published in `#prepare`. See `lib/rigor/plugin/rails_routes.rb`.
- **rigor-lisp-eval** / **rigor-units** (examples/) — recursive evaluation of a literal AST argument inside the rule; `rigor-units` threads `@bindings` and consults `scope.type_of`. See their `analyzer.rb` / `interpreter.rb`.
- **rigor-routes** (examples/) — `node_rule` for `*_path` / `*_url` calls, with the route table loaded via `cache_for(:route_table)` (see Phase 4.5 below).

## Phase 4.5 — IoBoundary + cache producer (rigor-routes only)

If [Phase 1](01-requirements.md) Q2=E (external file), the plugin uses slice 2 + slice 6. Since ADR-60 WD3 (`cache_for` is record-and-validate) the old "read BEFORE `cache_for`" trap is gone: the producer reads its inputs *inside* the block, and `cache_for` captures those reads into the dependency descriptor *after* the block runs. For a producer that globs a directory, declare `watch:` so a file *addition* invalidates too (an in-block read can't see a file that wasn't read). Use `producer_value` / `producer_error` for the lazy-load + error surface:

```ruby
# Single named file — the in-block read is captured; no watch: needed.
producer :route_table do |_params|
  contents = io_boundary.read_file(@routes_file)
  RouteTable.parse(contents)
end

# Directory glob — watch: covers additions/removals. The Proc is
# instance_exec'd at cache_for time, so #init-derived roots are in scope.
producer :model_index, watch: -> { [[@model_search_paths, "**/*.rb"]] } do |_params|
  ModelDiscoverer.new(io_boundary: io_boundary, search_paths: @model_search_paths).discover
end

node_rule Prism::CallNode do |node, _scope, path|
  table = producer_value(:route_table)   # lazy-load + memo + StandardError rescue
  next [] if table.nil?
  diagnostics_for(Analyzer.violations_for(call_node: node, table: table), path: path, node: node)
end

# diagnostics_for_file surfaces the load error if one was rescued:
def diagnostics_for_file(path:, scope:, root:)
  return [load_error_diagnostic(path)] if producer_value(:route_table).nil? && producer_error(:route_table)

  []
end
```

`producer_value(id)` runs the producer once and memoises the result (nil included); `producer_error(id)` returns the `StandardError` it rescued (nil on success). A plugin that needs *distinct* per-failure messages (AccessDenied vs ENOENT vs parse error) keeps a bespoke `rescue` ladder around `cache_for(id).call` and branches on `producer_error(id).class` — see `rigor-rails-routes` / `rigor-activerecord`. `glob_descriptor` is private since WD3; use `watch:`.

Demo `.rigor.yml` may need `plugins_io.allowed_paths:` if the plugin reads from outside the project root + signature paths.

---

The demo project under `plugins/rigor-<id>/demo/` (or `examples/rigor-<id>/demo/`, matching Phase 0's placement) makes the plugin runnable. Two-file convention when Q4 is B or C:

- `demo.rb` — only the recognised / valid call sites. Runs cleanly under MRI.
- `errors_demo.rb` — intentionally ill-typed code that exercises the `:error` paths. Add a header comment: "DO NOT run via `ruby errors_demo.rb` — analyse with `rigor check`."

The `.rigor.yml` `paths:` lists both, so `rigor check` analyses both. Set `cache.path` to a `tmp/`-anchored directory so the cache is strictly per-demo (and travels with the demo if the plugin is ever copied out to a third-party repo):

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
# plugins/rigor-<id>/demo/.gitignore   (or examples/rigor-<id>/demo/.gitignore)
/tmp/
```

Verify the demo runs (substitute `examples/` for `plugins/` if Phase 0 placed the plugin there):

```sh
cd plugins/rigor-<id>/demo
nix --extra-experimental-features 'nix-command flakes' develop --command \
  env RUBYLIB="$PWD/../lib" bundle exec --gemfile=$PWD/../../Gemfile \
  rigor check
```

The diagnostic stream should match what the README claims. The `tmp/` cache layout keeps demo runs from polluting the repo — `git status` after the run should be clean.
