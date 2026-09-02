# frozen_string_literal: true

require "rigor/plugin"

require_relative "rails_routes/acronyms"
require_relative "rails_routes/helper_table"
require_relative "rails_routes/routes_parser"
require_relative "rails_routes/helper_discoverer"
require_relative "rails_routes/grape_api_discoverer"
require_relative "rails_routes/analyzer"

module Rigor
  module Plugin
    # rigor-rails-routes — validates Rails route-helper calls (`users_path`, `edit_user_path(@user)`, …)
    # against the project's `config/routes.rb`.
    #
    # Tier 1A of the [Rails plugins roadmap](../../../../docs/design/20260508-rails-plugins-roadmap.md).
    # Statically interprets the routes DSL via Prism — no `rails` runtime dependency. Recognised v0.1.0
    # surface:
    #
    # - `Rails.application.routes.draw do ... end`
    # - `resources :name [, only: [...] | except: [...]]`
    # - `resource :name`
    # - `get/post/patch/put/delete "/path", to:, as:`
    # - `root to: "..."` / `root "..."`
    # - One level of `namespace :foo do ... end`
    # - One level of nested `resources`
    #
    # The plugin publishes its parsed `:helper_table` through the ADR-9 cross-plugin fact store;
    # `rigor-actionpack` Phase 4 consumes it for route-helper validation in controller code.
    #
    # ## Configuration
    #
    #     plugins:
    #       - gem: rigor-rails-routes
    #         config:
    #           routes_file: config/routes.rb   # default; optional
    #
    # A project mounting a Grape API keeps its `grape-path-helpers` helpers (`api_v4_groups_badges_path`)
    # out of `unknown-helper`: those names come from grape's runtime route table, so {GrapeApiDiscoverer}
    # recognises the namespace their `prefix` / `version` declarations open rather than enumerating names
    # it cannot know.
    #
    # ## Limitations (v0.1.0)
    #
    # - `scope :path:` / `scope :module:` / `scope :as:` are not interpreted — helpers nested inside these
    #   constructs are silently skipped.
    # - Constraints / format restrictions / mountable engines are out of scope.
    # - The English inflector is intentionally tiny: it handles `posts` ↔ `post`, `users` ↔ `user`,
    #   `categories` ↔ `category`, `boxes` ↔ `box`. Custom inflections (`fish` ↔ `fish`, `child` ↔
    #   `children`) are out of scope; users who need them ship a hand-written RBS for the affected helper.
    class RailsRoutes < Rigor::Plugin::Base
      manifest(
        id: "rails-routes",
        # Bumped 2026-05-28 — GitLab FOSS sweep adds: (a) `draw_all :name` support (action_dispatch-draw_all
        # gem; single-file load semantics matching `draw :name`); (b) keyword-style `scope(path:
        # ':project_id', as: :project)` — path read from the `:path` keyword, not only from the positional
        # first arg; (c) detection of iterative `direct(name.sub(FROM, TO)) do ... end` alias-generation
        # idiom — generates `<TO>_*` aliases for every registered `<FROM>_*` helper. GitLab uses this to
        # shorten `namespace_project_*` → `project_*`. Bumped 2026-07-10 — recognises the open helper
        # namespace `grape-path-helpers` generates (`api_v4_*_path`), grounded in the project's own Grape
        # `prefix` / `version` declarations (see {GrapeApiDiscoverer}).
        # Bumped 2026-08-15 — the parser now also accumulates the CONTROLLER classes the routes file
        # dispatches to, published as the `:reachability_roots` fact for `rigor unused` (ADR-102 WD3). The
        # bump matters mechanically as well as editorially: the manifest version is part of the producer
        # cache key, so it retires `:helper_table` slots written before the table carried `controllers`.
        version: "0.29.0",
        description: "Validates Rails route-helper calls against `config/routes.rb`.",
        config_schema: {
          "routes_file" => { kind: :string, default: "config/routes.rb" },
          # `helper_paths` — the directories `HelperDiscoverer` walks for project-defined `*_path` / `*_url`
          # methods. Default to the whole `app/` tree — the suffix filter inside the discoverer keeps the
          # registered set tight, and real-world Rails apps routinely keep URL builders under
          # `app/controllers` (private `def page_url`, `def callback_url` shapes), `app/lib` (Mastodon's
          # `TranslationService::DeepL#base_url`), `app/services` (`SoftwareUpdateCheckService#api_url`),
          # `app/serializers`, `app/presenters`, `app/decorators`, not only `app/helpers/`. Walking the
          # whole tree is the honest answer to "does this `_path` / `_url` name exist anywhere in the
          # project?"; the cost is a one-time Prism parse per file at startup, which is bounded.
          "helper_paths" => { kind: :array, default: ["app"] },
          # `grape_api_paths` — the directories scanned for Grape API classes, whose `prefix` / `version`
          # declarations ground the open `api_v4_*_path` helper namespace `grape-path-helpers` generates
          # (see {GrapeApiDiscoverer}). Defaults cover the two conventional homes; a project with no grape
          # API declares no prefixes and nothing changes for it.
          "grape_api_paths" => { kind: :array, default: ["lib/api", "app/api"] }
        },
        produces: %i[helper_table reachability_roots]
      )

      # Cached producer — reads `config/routes.rb` through the trusted `IoBoundary` and parses through
      # {RoutesParser}. The descriptor's auto-collected `FileEntry` digest invalidates the cache on
      # routes-file edits.
      #
      # Passes a `file_reader` lambda so the parser can follow `draw(:admin)` → `config/routes/admin.rb`
      # partials. `watch:` (ADR-60 WD3) covers every `.rb` under `helper_paths:` and `grape_api_paths:` so
      # ADDING a helper file — or a Grape API whose `version` declaration opens a new namespace —
      # invalidates the table. The producer's own in-block reads (the routes file + the partials it follows
      # via `draw`) are captured post-compute, but a brand-new file the prior run never read would otherwise
      # read as fresh.
      producer :helper_table, watch: -> { (@helper_paths + @grape_api_paths).map { |dir| [dir, "**/*.rb"] } } do |_p|
        routes_dir = "#{File.dirname(@routes_file)}/routes"
        file_reader = lambda do |name|
          io_boundary.read_file("#{routes_dir}/#{name}")
        rescue StandardError
          nil
        end
        contents = io_boundary.read_file(@routes_file)
        RoutesParser.parse(contents, file_reader: file_reader, custom_helpers: discover_custom_helpers,
                                     grape_prefixes: discover_grape_prefixes,
                                     acronyms: discover_acronyms)
      end

      def init(_services)
        @routes_file = config.fetch("routes_file")
        # Derived from `routes_file:` rather than configured separately: both live under the same `config/`
        # tree in every Rails layout, and a second knob for a file the user never has to think about is a
        # setting nobody will set correctly.
        @inflections_file = File.join(File.dirname(@routes_file), "initializers", "inflections.rb")
        @helper_paths = Array(config.fetch("helper_paths")).map(&:to_s)
        @grape_api_paths = Array(config.fetch("grape_api_paths")).map(&:to_s)
        @helper_table = nil
        @helper_table_built = false
        @load_error = nil
      end

      # Walks every configured `helper_paths:` directory through the trusted `IoBoundary` and returns the
      # set of project-defined `*_path` / `*_url` method names for {HelperDiscoverer}. Each file digest is
      # captured by the boundary so editing a helper file invalidates the `:helper_table` cache
      # automatically. Returns the empty set when nothing under `helper_paths:` exists — the routes table
      # still works.
      def discover_custom_helpers
        contents_per_path = {}
        each_helper_file do |path|
          contents_per_path[path] = io_boundary.read_file(path)
        rescue Plugin::AccessDeniedError, Errno::ENOENT
          next
        end
        HelperDiscoverer.discover(contents_per_path)
      end

      # Walks `grape_api_paths:` through the trusted `IoBoundary` and returns the helper-name prefixes the
      # project's Grape API classes generate (`["api_v3", "api_v4"]`). Empty for a project with no grape API,
      # which leaves `unknown-helper` behaviour exactly as it was.
      def discover_grape_prefixes
        contents_per_path = {}
        each_ruby_file(@grape_api_paths) do |path|
          contents_per_path[path] = io_boundary.read_file(path)
        rescue Plugin::AccessDeniedError, Errno::ENOENT
          next
        end
        GrapeApiDiscoverer.discover(contents_per_path)
      end

      # Reads the project's `config/initializers/inflections.rb` through the trusted `IoBoundary` and returns
      # the acronyms it declares, for controller-class-name composition ({Acronyms}). The file is *parsed*,
      # never executed. Absent file → no acronyms → composition behaves exactly as it did before.
      def discover_acronyms
        Acronyms.discover(io_boundary.read_file(@inflections_file))
      rescue Plugin::AccessDeniedError, Errno::ENOENT
        []
      end

      def each_helper_file(&) = each_ruby_file(@helper_paths, &)

      def each_ruby_file(dirs, &)
        dirs.each do |dir|
          absolute = File.expand_path(dir)
          # ADR-45 WD1b (#613) — boundary-probed: a root that appears later invalidates the warm run.
          next unless io_boundary.directory?(absolute)

          Dir.glob(File.join(absolute, "**", "*.rb")).each(&)
        end
      end

      # Publishes the parsed table to the cross-plugin fact store; `rigor-actionpack` Phase 4 reads it via
      # `services.fact_store.read`.
      #
      # ADR-102 WD3 — also publishes `:reachability_roots`, the controller classes `config/routes.rb`
      # dispatches to. A controller is an entry point *nothing in the project references*: Rails reaches it
      # by name at request time, so a reference index sees a live controller exactly as it sees a dead one.
      # `rigor unused` reads this fact from every loaded plugin and seeds its mark-and-sweep with the union.
      # Nothing else consumes it, and it never reaches the `rigor check` diagnostic stream (WD1).
      def prepare(services)
        table = helper_table_or_nil
        return if table.nil?

        services.fact_store.publish(
          plugin_id: manifest.id,
          name: :helper_table,
          value: table.to_h
        )
        publish_reachability_roots(services, table)
      end

      # File-level only: the once-per-run load-error emission. Per-call helper validation runs over the
      # engine-owned walk via the node_rule below (ADR-37), with the same-file `shadowing` set built once
      # as the node-rule file context.
      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        table = helper_table_or_nil
        if table.nil? && @load_error
          return [] if @load_error_emitted

          @load_error_emitted = true
          return [load_error_diagnostic(path)]
        end

        []
      end

      node_file_context do |root, _scope|
        Analyzer.collect_shadowing_names(root)
      end

      node_rule Prism::CallNode do |node, _scope, path, shadowing|
        table = helper_table_or_nil
        next [] if table.nil? || table.empty?

        Analyzer.violations_for(call_node: node, helper_table: table, shadowing: shadowing, path: path).map do |violation|
          diagnostic(node, path: path, message: violation.message, severity: violation.severity, rule: violation.rule)
        end
      end

      private

      # Publishes nothing when the routes file named no controller — an empty root set is indistinguishable
      # from "this plugin contributed nothing", and an absent fact says so without a consumer having to
      # special-case an empty Array.
      def publish_reachability_roots(services, table)
        roots = table.controllers
        return if roots.empty?

        services.fact_store.publish(
          plugin_id: manifest.id,
          name: :reachability_roots,
          value: roots
        )
      end

      # The load-error path used to emit the same warning on every analyzed file in the project. On large
      # monorepos (Mastodon: 1,302 files; Solidus: ~1,000 files) and on legacy projects without a top-level
      # `config/routes.rb`, this multiplied a single root cause into 1,000+ identical diagnostics. The
      # error is project-global — report it once per run.

      def helper_table_or_nil
        # Memoise the build *attempt*, not just a truthy result: when the routes file is missing or
        # unparseable the table is nil, and the old `return @helper_table if @helper_table` re-ran the
        # whole read-and-parse on every call. The engine consults this per route-helper dispatch, so a nil
        # table meant re-reading (and, on a real project, re-parsing) `config/routes.rb` tens of thousands
        # of times per run. The result — nil included — is stable for the run, so one attempt is correct.
        return @helper_table if @helper_table_built

        @helper_table_built = true
        # ADR-60 WD3 record-and-validate: the producer's in-block reads (the routes file + the partials it
        # follows) are captured into the dependency descriptor AFTER the block runs, and the producer's
        # `watch:` covers helper-file additions — so no priming read is needed here.
        @helper_table = cache_for(:helper_table, params: {}).call
      rescue Plugin::AccessDeniedError => e
        @load_error = "rigor-rails-routes: #{e.message}"
        nil
      rescue Errno::ENOENT
        @load_error = "rigor-rails-routes: routes file `#{@routes_file}` not found; route checks skipped"
        nil
      rescue StandardError => e
        @load_error = "rigor-rails-routes: failed to parse `#{@routes_file}`: #{e.class}: #{e.message}"
        nil
      end

      def load_error_diagnostic(path)
        Rigor::Analysis::Diagnostic.new(
          path: path, line: 1, column: 1,
          message: @load_error,
          severity: :warning,
          rule: "load-error"
        )
      end
    end

    Rigor::Plugin.register(RailsRoutes)
  end
end
