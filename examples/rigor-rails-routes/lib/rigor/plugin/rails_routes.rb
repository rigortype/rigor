# frozen_string_literal: true

require "rigor/plugin"

require_relative "rails_routes/helper_table"
require_relative "rails_routes/routes_parser"
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
        version: "0.1.0",
        description: "Validates Rails route-helper calls against `config/routes.rb`.",
        config_schema: {
          "routes_file" => :string
        },
        produces: [:helper_table]
      )

      DEFAULT_ROUTES_FILE = "config/routes.rb"

      # Cached producer — reads `config/routes.rb` through
      # the trusted `IoBoundary` and parses through
      # {RoutesParser}. The descriptor's auto-collected
      # `FileEntry` digest invalidates the cache on routes-
      # file edits.
      producer :helper_table do |_params|
        contents = io_boundary.read_file(@routes_file)
        RoutesParser.parse(contents)
      end

      def init(_services)
        @routes_file = config.fetch("routes_file", DEFAULT_ROUTES_FILE)
        @helper_table = nil
        @load_error = nil
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
        return [load_error_diagnostic(path)] if table.nil? && @load_error
        return [] if table.nil? || table.empty?

        Analyzer.diagnose(path: path, root: root, helper_table: table)
                .map { |diag| build_diagnostic(diag) }
      end

      private

      def helper_table_or_nil
        return @helper_table if @helper_table

        # Read first so the IoBoundary's FileEntry digest
        # captures into the descriptor before `cache_for`
        # snapshots it (the same pattern documented in
        # rigor-routes / rigor-activerecord).
        io_boundary.read_file(@routes_file)
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
