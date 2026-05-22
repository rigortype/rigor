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
never published. Two ways to make `require "rigor-<id>"` succeed:

### Recommended — a path gem

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

`bundle install` then puts `rigor-myapp` on the load path, so Rigor's
`require "rigor-myapp"` resolves. This keeps the plugin versioned,
testable, and trivially promotable to a real gem later.

### Simplest — a bare file on the load path

If you do not want a gemspec at all, drop `rigor-myapp.rb` somewhere
and run `rigor` with that directory on `RUBYLIB`:

```text
your-app/rigor-ext/rigor-myapp.rb     # requires the plugin class
```

```sh
RUBYLIB=rigor-ext rigor check
```

Workable, but the `RUBYLIB` has to be set on every invocation (CI
included). Prefer the path gem unless the plugin is a throwaway.

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

      # Called per analysed file. `root` is the file's Prism AST,
      # `scope` answers inferred-type queries. Return an Array of
      # Rigor::Analysis::Diagnostic. See 02-walker-and-types.md.
      def diagnostics_for_file(path:, scope:, root:)
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

A scaffolded plugin that loads (even if `diagnostics_for_file` still
returns `[]`) and is activated in `.rigor.yml`. Proceed to Phase 2
([`02-walker-and-types.md`](02-walker-and-types.md)) to make it
actually analyse.
