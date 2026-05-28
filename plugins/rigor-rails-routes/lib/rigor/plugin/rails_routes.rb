# frozen_string_literal: true

require "rigor/plugin"

require_relative "rails_routes/helper_table"
require_relative "rails_routes/routes_parser"
require_relative "rails_routes/helper_discoverer"
require_relative "rails_routes/analyzer"

module Rigor
  module Plugin
    # rigor-rails-routes — validates Rails route-helper calls
    # (`users_path`, `edit_user_path(@user)`, …) against the
    # project's `config/routes.rb`.
    #
    # Tier 1A of the [Rails plugins roadmap](../../../../docs/design/20260508-rails-plugins-roadmap.md).
    # Statically interprets the routes DSL via Prism — no
    # `rails` runtime dependency. Recognised v0.1.0 surface:
    #
    # - `Rails.application.routes.draw do ... end`
    # - `resources :name [, only: [...] | except: [...]]`
    # - `resource :name`
    # - `get/post/patch/put/delete "/path", to:, as:`
    # - `root to: "..."` / `root "..."`
    # - One level of `namespace :foo do ... end`
    # - One level of nested `resources`
    #
    # The plugin publishes its parsed `:helper_table` through
    # the ADR-9 cross-plugin fact store so future
    # `rigor-actionpack` Phase 4 can consume it for
    # route-helper validation in controller code.
    #
    # ## Configuration
    #
    #     plugins:
    #       - gem: rigor-rails-routes
    #         config:
    #           routes_file: config/routes.rb   # default; optional
    #
    # ## Limitations (v0.1.0)
    #
    # - `scope :path:` / `scope :module:` / `scope :as:` are
    #   not interpreted — helpers nested inside these
    #   constructs are silently skipped.
    # - Constraints / format restrictions / mountable
    #   engines are out of scope.
    # - The English inflector is intentionally tiny: it
    #   handles `posts` ↔ `post`, `users` ↔ `user`,
    #   `categories` ↔ `category`, `boxes` ↔ `box`. Custom
    #   inflections (`fish` ↔ `fish`, `child` ↔ `children`)
    #   are out of scope; users who need them ship a hand-
    #   written RBS for the affected helper.
    class RailsRoutes < Rigor::Plugin::Base
      manifest(
        id: "rails-routes",
        # Bumped 2026-05-28 — GitLab FOSS sweep adds: (a)
        # `draw_all :name` support (action_dispatch-draw_all
        # gem; single-file load semantics matching `draw :name`);
        # (b) keyword-style `scope(path: ':project_id',
        # as: :project)` — path read from the `:path` keyword,
        # not only from the positional first arg; (c) detection
        # of iterative `direct(name.sub(FROM, TO)) do ... end`
        # alias-generation idiom — generates `<TO>_*` aliases
        # for every registered `<FROM>_*` helper. GitLab uses
        # this to shorten `namespace_project_*` → `project_*`.
        version: "0.15.0",
        description: "Validates Rails route-helper calls against `config/routes.rb`.",
        config_schema: {
          "routes_file" => :string,
          "helper_paths" => :array
        },
        produces: [:helper_table]
      )

      DEFAULT_ROUTES_FILE = "config/routes.rb"

      # The directories `HelperDiscoverer` walks for project-
      # defined `*_path` / `*_url` methods. Default to the whole
      # `app/` tree — the suffix filter inside the discoverer
      # keeps the registered set tight, and real-world Rails
      # apps routinely keep URL builders under `app/controllers`
      # (private `def page_url`, `def callback_url` shapes),
      # `app/lib` (Mastodon's `TranslationService::DeepL#base_url`),
      # `app/services` (`SoftwareUpdateCheckService#api_url`),
      # `app/serializers`, `app/presenters`, `app/decorators`,
      # not only `app/helpers/`. Walking the whole tree is the
      # honest answer to "does this `_path` / `_url` name exist
      # anywhere in the project?"; the cost is a one-time Prism
      # parse per file at startup, which is bounded.
      DEFAULT_HELPER_PATHS = ["app"].freeze

      # Cached producer — reads `config/routes.rb` through
      # the trusted `IoBoundary` and parses through
      # {RoutesParser}. The descriptor's auto-collected
      # `FileEntry` digest invalidates the cache on routes-
      # file edits.
      #
      # Passes a `file_reader` lambda so the parser can follow
      # `draw(:admin)` → `config/routes/admin.rb` partials.
      producer :helper_table do |_params|
        routes_dir = "#{File.dirname(@routes_file)}/routes"
        file_reader = lambda do |name|
          io_boundary.read_file("#{routes_dir}/#{name}")
        rescue StandardError
          nil
        end
        contents = io_boundary.read_file(@routes_file)
        custom_helpers = discover_custom_helpers
        RoutesParser.parse(contents, file_reader: file_reader, custom_helpers: custom_helpers)
      end

      def init(_services)
        @routes_file = config.fetch("routes_file", DEFAULT_ROUTES_FILE)
        @helper_paths = Array(config.fetch("helper_paths", DEFAULT_HELPER_PATHS)).map(&:to_s)
        @helper_table = nil
        @load_error = nil
      end

      # Walks every configured `helper_paths:` directory
      # through the trusted `IoBoundary` and returns the set
      # of project-defined `*_path` / `*_url` method names
      # for {HelperDiscoverer}. Each file digest is captured
      # by the boundary so editing a helper file invalidates
      # the `:helper_table` cache automatically. Returns the
      # empty set when nothing under `helper_paths:` exists —
      # the routes table still works.
      def discover_custom_helpers
        contents_per_path = {}
        each_helper_file do |path|
          contents_per_path[path] = io_boundary.read_file(path)
        rescue Plugin::AccessDeniedError, Errno::ENOENT
          next
        end
        HelperDiscoverer.discover(contents_per_path)
      end

      def pre_read_helper_files
        each_helper_file do |path|
          io_boundary.read_file(path)
        rescue Plugin::AccessDeniedError, Errno::ENOENT
          next
        end
      end

      def each_helper_file(&)
        @helper_paths.each do |dir|
          absolute = File.expand_path(dir)
          next unless File.directory?(absolute)

          Dir.glob(File.join(absolute, "**", "*.rb")).each(&)
        end
      end

      # Publishes the parsed table to the cross-plugin fact
      # store so future Tier 2 plugins (rigor-actionpack
      # Phase 4) can read it via `services.fact_store.read`.
      def prepare(services)
        table = helper_table_or_nil
        return if table.nil?

        services.fact_store.publish(
          plugin_id: manifest.id,
          name: :helper_table,
          value: table.to_h
        )
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        table = helper_table_or_nil
        if table.nil? && @load_error
          return [] if @load_error_emitted

          @load_error_emitted = true
          return [load_error_diagnostic(path)]
        end
        return [] if table.nil? || table.empty?

        Analyzer.diagnose(path: path, root: root, helper_table: table)
                .map { |diag| build_diagnostic(diag) }
      end

      private

      # The load-error path used to emit the same warning on
      # every analyzed file in the project. On large monorepos
      # (Mastodon: 1,302 files; Solidus: ~1,000 files) and on
      # legacy projects without a top-level `config/routes.rb`,
      # this multiplied a single root cause into 1,000+
      # identical diagnostics. The error is project-global —
      # report it once per run.

      def helper_table_or_nil
        return @helper_table if @helper_table

        # Read first so the IoBoundary's FileEntry digest
        # captures into the descriptor before `cache_for`
        # snapshots it (the same pattern documented in
        # rigor-routes / rigor-activerecord). Helper files are
        # pre-read for the same reason — editing a file under
        # `app/helpers/` MUST invalidate the helper_table cache
        # so the new custom-helper set is picked up.
        io_boundary.read_file(@routes_file)
        pre_read_helper_files
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

      def build_diagnostic(diag)
        Rigor::Analysis::Diagnostic.new(
          path: diag.path, line: diag.line, column: diag.column,
          message: diag.message, severity: diag.severity, rule: diag.rule
        )
      end
    end

    Rigor::Plugin.register(RailsRoutes)
  end
end
