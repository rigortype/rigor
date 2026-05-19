# Phases 3–5 — Scaffold, walker pattern, demo

Pick a plugin id and gem name following the convention:

- **Plugin id** — kebab-case, lowercase, descriptive. Matches `Rigor::Plugin::Manifest::VALID_ID` (`/\A[a-z][a-z0-9._-]*\z/`). Examples: `routes`, `lisp-eval`, `deprecations`.
- **Gem name** — `rigor-<id>`. The plugin loader calls `require "rigor-<id>"` from each `.rigor.yml` `plugins:` entry.

Create the directory tree (replacing `<id>` and `ClassName` with the chosen id and matching CamelCase Ruby class name; substitute `examples/` for `plugins/` if Phase 0 placed the plugin there):

```text
plugins/rigor-<id>/   # or examples/rigor-<id>/ for a walkthrough
├── README.md
├── rigor-<id>.gemspec
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

## Gemspec template

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
        # Read config defaults. See Phase 4 (references/04-walker-patterns.md).
      end

      def diagnostics_for_file(path:, scope:, root:)
        # Walk `root` (Prism::Node), return Array<Rigor::Analysis::Diagnostic>.
        # See Phase 4 (references/04-walker-patterns.md) for the per-template body.
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

The analyser body inside `#diagnostics_for_file` is the part that varies most by template. Don't invent a new walker — copy the matching example's `lib/rigor/plugin/<id>/analyzer.rb` (or the inline walker in the small plugins) and adapt the dispatch table.

## Template-specific reference points

- **rigor-deprecations** — single-pass walk, match `CallNode` against config rules. See `lib/rigor/plugin/deprecations.rb` `each_call` helper.
- **rigor-lisp-eval** — recursive evaluation of a literal AST argument. See `lib/rigor/plugin/lisp_eval/interpreter.rb#evaluate` for the recursion pattern; arrives at a tag (`:integer` / `:float` / `:bool`) bottom-up.
- **rigor-units** — `evaluate(node)` returns a dimension tag while threading `@bindings` (a Hash<Symbol, Symbol> of local-variable name → dimension tag). On `LocalVariableWriteNode`, evaluate the RHS and store the result. See `lib/rigor/plugin/units/analyzer.rb#evaluate`.
- **rigor-statesman** — two passes: `collect_states(root)` produces a Set; `validate_transitions(root, states)` consults it. See `lib/rigor/plugin/statesman.rb` `collect_states` / `validate_transitions`.
- **rigor-pattern** — the walker calls `scope.type_of(arg_node)` to ASK the analyser for the inferred type, then `literal_string_compatible?` to gate further checks. See `lib/rigor/plugin/pattern.rb` `analyse_call` and `literal_value_of`.
- **rigor-routes** — single-pass walk for `*_path` / `*_url` calls, but the route table is loaded via `cache_for(:route_table)` (see Phase 4.5 below).

## Phase 4.5 — IoBoundary + cache producer (rigor-routes only)

If [Phase 1](01-requirements.md) Q2=E (external file), the plugin uses slice 2 + slice 6. The exact pattern is documented in `cache_producer_spec.rb` — but it is a TRAP if you get it wrong. The rule is:

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

Demo `.rigor.yml` may need `plugins_io.allowed_paths:` if the plugin reads from outside the project root + signature paths.

---

The demo project under `plugins/rigor-<id>/demo/` (or `examples/rigor-<id>/demo/`, matching Phase 0's placement) makes the plugin runnable. Two-file convention when Q4 is B or C:

- `demo.rb` — only the recognised / valid call sites. Runs cleanly under MRI.
- `errors_demo.rb` — intentionally ill-typed code that exercises the `:error` paths. Add a header comment: "DO NOT run via `ruby errors_demo.rb` — analyse with `rigor check`."

The `.rigor.yml` `paths:` lists both, so `rigor check` analyses both. Set `cache.path` to a `tmp/`-anchored directory so the cache is strictly per-demo and survives the eventual `git subtree split`:

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
