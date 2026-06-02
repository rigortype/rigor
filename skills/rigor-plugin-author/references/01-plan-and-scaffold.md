# 01 — Package and scaffold

Covers **Phase 1**. Output: a directory tree, a plugin class
skeleton that registers itself, and an `.rigor.yml` that activates
it.

## Naming

- **Plugin id** — kebab-case, starts with a letter, matches
  `/\A[a-z][a-z0-9._-]*\z/`. Descriptive: `units`, `myapp-dsl`,
  `legacy-macros`.
- **Require name** — Rigor activates a plugin by `require`-ing the
  name in the `.rigor.yml` `plugins:` entry. The convention is
  `rigor-<id>`, and the file that name resolves to must, when
  loaded, call `Rigor::Plugin.register`.
- **Ruby class** — CamelCase under `Rigor::Plugin`, e.g.
  `Rigor::Plugin::MyappDsl`.

## Standalone gem layout

```text
rigor-<id>/                      # its own repository
├── README.md
├── rigor-<id>.gemspec
├── Gemfile                      # gem "rigortype" (dev); gemspec
├── lib/
│   ├── rigor-<id>.rb            # require name → require_relative the class
│   └── rigor/plugin/
│       └── <id>.rb              # the plugin class + Rigor::Plugin.register
│       └── <id>/                # only if it needs helpers
│           └── analyzer.rb      # AST walker extracted out of the class
├── sig/                         # optional — RBS for the DSL (Phase 2)
└── spec/  or  test/             # fixture tests (Phase 3)
```

### Gemspec template

```ruby
# rigor-<id>.gemspec
# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name        = "rigor-<id>"
  spec.version     = "0.1.0"
  spec.authors     = ["Your Name"]
  spec.summary     = "Rigor plugin: <one line>."
  spec.description = "<two sentences naming the DSL / API the plugin types>."
  spec.license     = "MIT"        # your choice
  spec.required_ruby_version = ">= 3.2"

  spec.files        = Dir.glob(%w[README.md lib/**/*.rb sig/**/*.rbs])
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0", "< 2.0"
  # Pin tightly — the plugin contract is pre-1.0 (see SKILL.md).
  spec.add_dependency "rigortype", ">= 0.1.0", "< 0.2.0"
end
```

`prism` is Rigor's parser; a plugin walks `Prism::Node`s, so depend
on it directly.

## Project-private layout

A project-private plugin lives inside the application repo and is
never published. Rigor activates it by `require "rigor-<id>"`, so the
plugin's `lib/` must be on the **load path of the Ruby process that
runs `rigor`**. *Which* mechanism puts it there depends entirely on
**how `rigor` is installed** — and getting this wrong is the most
common project-private activation failure (`could not load plugin gem
"rigor-<id>"`).

> **First answer this: how does `rigor` run?** Per the
> `rigor-project-init` workflow and the manual's installation chapter,
> the recommended install is **standalone** (`mise` / `gem install`) —
> and crucially **`rigortype` is NOT in your app's `Gemfile`**. A
> standalone `rigor` does **not** load your project's bundle, so a
> `path:`-gem in the `Gemfile` + `bundle install` puts the plugin on
> the *bundle's* load path, which the standalone `rigor` never reads.
> The path-gem route below works **only** if you deliberately run
> `rigor` from a bundle that includes `rigortype` (an advanced / CI
> setup). For the default standalone install, use `RUBYLIB`.

### Recommended for a standalone (mise / gem install) `rigor` — `RUBYLIB`

Drop the plugin under the app and put its `lib/` (or its root, if the
entry file sits at the top) on `RUBYLIB` as an **absolute path**:

```text
your-app/rigor-ext/rigor-myapp.rb     # requires the plugin class
```

```sh
# Absolute path — a relative RUBYLIB is resolved against the process
# CWD and frequently does not match; use $(pwd).
RUBYLIB="$(pwd)/rigor-ext" rigor check
```

Ruby adds `RUBYLIB` entries to `$LOAD_PATH` at startup, so the
standalone `rigor` binary finds `require "rigor-myapp"`. Set it on
every invocation (CI included); a `Rakefile` task or a shell alias
keeps it ergonomic.

> **Pitfall — do not wrap this in `bundle exec`.** `bundle exec`
> rebuilds `$LOAD_PATH` from the bundle and drops `RUBYLIB` entries, so
> `RUBYLIB=… bundle exec rigor` fails to find the plugin. If for some
> reason you must run `rigor` through `bundle exec` (or any wrapper
> that resets the load path), pass the directory as a Ruby flag
> instead — `RUBYOPT="-I$(pwd)/rigor-ext" rigor check` — which Bundler
> preserves.

Verify activation with `rigor plugins` (plural): the entry should show
`[OK ]` with `load-error: 0`. If it shows `[ERR] could not load plugin
gem`, the load path is the problem, not the plugin code.

### Advanced (only when `rigor` runs from a bundle) — a path gem

Keep the plugin in a subdirectory with its own gemspec, and reference
it from the app's `Gemfile` by path:

```text
your-app/
├── Gemfile
├── rigor-plugin/                # the plugin, unpublished
│   ├── rigor-myapp.gemspec
│   └── lib/
│       ├── rigor-myapp.rb
│       └── rigor/plugin/myapp.rb
└── .rigor.yml
```

```ruby
# your-app/Gemfile
gem "rigortype", "~> 0.1.0"
gem "rigor-myapp", path: "rigor-plugin"
```

`bundle install` puts `rigor-myapp` on the bundle's load path — but
this only helps if you then **run `rigor` through that bundle**
(`bundle exec rigor`, or a bundle whose `bin/` is on `PATH`). It also
means `rigortype` *is* in this `Gemfile`, which the `rigor-project-init`
workflow recommends against for the analyzer-as-tool install. So treat
this route as the **CI / isolated-bundle** option, not the default. It
keeps the plugin versioned, testable, and trivially promotable to a
real gem later — choose it when your `rigor` already runs from a
bundle; otherwise use `RUBYLIB` above.

## The plugin class skeleton

`lib/rigor-<id>.rb` — the require entry point:

```ruby
# frozen_string_literal: true

require_relative "rigor/plugin/<id>"
```

`lib/rigor/plugin/<id>.rb` — the plugin class:

```ruby
# frozen_string_literal: true

require "rigor/plugin"

module Rigor
  module Plugin
    class MyappDsl < Rigor::Plugin::Base
      manifest(
        id: "<id>",
        version: "0.1.0",
        description: "<one line>",
        # Optional: declare config keys the user may set under
        # `.rigor.yml` plugins: [{ gem:, config: { … } }].
        config_schema: {
          # "module_name" => :string,
          # "rules"       => :array,
        }
      )

      # Called once at load time with the service container.
      # Read config defaults here. `config` is the validated
      # user config Hash.
      def init(_services)
        @module_name = config.fetch("module_name", "Default")
      end

      # The engine owns the AST walk and hands every matching node to
      # this rule. `scope` answers inferred-type queries; return an
      # Array of Rigor::Analysis::Diagnostic (built via `diagnostic`).
      # See 02-walker-and-types.md.
      node_rule Prism::CallNode do |node, scope, path, _file_context, _context|
        []
      end
    end

    Rigor::Plugin.register(MyappDsl)
  end
end
```

`Rigor::Plugin.register` at the bottom is mandatory — the loader
`require`s the gem, then looks for a freshly-registered plugin
class. A gem that registers nothing fails to load with a clear
error.

## Activate the plugin in `.rigor.yml`

```yaml
plugins:
  - rigor-<id>

# Hash form when the plugin takes config:
# plugins:
#   - gem: rigor-<id>
#     config:
#       module_name: MyApp
```

Confirm activation with the public CLI:

```sh
rigor check
```

A misconfigured plugin surfaces as a `plugin-loader` diagnostic
rather than crashing the run — read that message if the plugin seems
inert.

## Output of this module

A scaffolded plugin that loads (even if its `node_rule` still
returns `[]`) and is activated in `.rigor.yml`. Proceed to Phase 2
([`02-walker-and-types.md`](02-walker-and-types.md)) to make it
actually analyse.
