# frozen_string_literal: true

require "rigor/plugin"

require_relative "actionmailer/mailer_index"
require_relative "actionmailer/mailer_discoverer"
require_relative "actionmailer/analyzer"

module Rigor
  module Plugin
    # rigor-actionmailer — validates `Mailer.action(args)`
    # call sites and detects missing view templates.
    #
    # Tier 1C of the [Rails plugins roadmap](../../../../docs/design/20260508-rails-plugins-roadmap.md).
    # Statically discovers mailer classes by walking
    # `mailer_search_paths` and parsing each file with
    # Prism — no `action_mailer` runtime dependency.
    #
    # ## Configuration
    #
    #     plugins:
    #       - gem: rigor-actionmailer
    #         config:
    #           mailer_search_paths: ["app/mailers"]                  # default; optional
    #           mailer_base_classes: ["ApplicationMailer", "ActionMailer::Base"]  # default; optional
    #           views_root: "app/views"                                # default; optional
    #
    # ## What it checks
    #
    # 1. **Method existence** — `UserMailer.welcome(user)`
    #    is flagged when `welcome` is not defined on
    #    `UserMailer`.
    # 2. **Argument arity** — calls with too few / too many
    #    positional arguments emit `wrong-arity`.
    # 3. **View template existence** — for every action
    #    method, at least one of
    #    `app/views/<mailer_underscore>/<action>.{html,text}.{erb,haml,slim}`
    #    must exist. Missing actions get a `missing-view`
    #    diagnostic anchored on the action's `def`.
    #
    # ## Limitations (v0.1.0)
    #
    # - Direct-superclass match only.
    # - Action methods are read from the syntactic instance-
    #   side `def` list. `define_method` actions are out of
    #   scope.
    # - Adding a brand-new view file does not invalidate the
    #   cache until something the mailer file touches
    #   changes.
    class Actionmailer < Rigor::Plugin::Base
      manifest(
        id: "actionmailer",
        version: "0.1.0",
        description: "Validates ActionMailer call shape and view template existence.",
        config_schema: {
          "mailer_search_paths" => :array,
          "mailer_base_classes" => :array,
          "views_root" => :string
        }
      )

      DEFAULT_MAILER_SEARCH_PATHS = ["app/mailers"].freeze
      DEFAULT_MAILER_BASE_CLASSES = %w[ApplicationMailer ActionMailer::Base].freeze
      DEFAULT_VIEWS_ROOT = "app/views"

      producer :mailer_index do |_params|
        MailerDiscoverer.new(
          io_boundary: io_boundary,
          search_paths: @mailer_search_paths,
          base_classes: @mailer_base_classes,
          views_root: @views_root
        ).discover
      end

      def init(_services)
        @mailer_search_paths = Array(config.fetch("mailer_search_paths", DEFAULT_MAILER_SEARCH_PATHS)).map(&:to_s)
        @mailer_base_classes = Array(config.fetch("mailer_base_classes", DEFAULT_MAILER_BASE_CLASSES)).map(&:to_s)
        @views_root = config.fetch("views_root", DEFAULT_VIEWS_ROOT).to_s
        @mailer_index = nil
        @load_error = nil
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        index = mailer_index_or_nil
        return [load_error_diagnostic(path)] if index.nil? && @load_error
        return [] if index.nil? || index.empty?

        diagnostics = []
        diagnostics.concat(call_site_diagnostics(path, root, index))
        diagnostics.concat(missing_view_diagnostics(path, index))
        diagnostics
      end

      private

      def mailer_index_or_nil
        return @mailer_index if @mailer_index

        # Two-glob descriptor: every mailer class under
        # `mailer_search_paths` AND every view template under
        # `views_root`. Without explicit enumeration the cache
        # invalidates only on files the `IoBoundary` has already
        # read in the current process — empty on the first call
        # of a fresh process, so warm hits would serve stale
        # `MailerIndex` data after mailers are added / removed or
        # view templates are added (`view_exists?` failures aren't
        # recorded, so the auto-built descriptor cannot detect a
        # newly-added view).
        mailer_d = glob_descriptor(@mailer_search_paths, "**/*.rb")
        view_d = glob_descriptor([@views_root], "**/*")
        descriptor = Rigor::Cache::Descriptor.compose(mailer_d, view_d)
        @mailer_index = cache_for(:mailer_index, params: {}, descriptor: descriptor).call
      rescue StandardError => e
        @load_error = "rigor-actionmailer: failed to discover mailers: #{e.class}: #{e.message}"
        nil
      end

      def call_site_diagnostics(path, root, index)
        Analyzer.diagnose(path: path, root: root, mailer_index: index).map { |diag| build_diagnostic(diag) }
      end

      # Anchors `missing-view` diagnostics on the mailer file
      # itself: when the file currently being analysed is the
      # mailer's source file, emit one diagnostic per missing
      # action template at the action's `def` location.
      def missing_view_diagnostics(path, index)
        canonical = canonical_path(path)
        class_entry = index.find_by_file(canonical)
        return [] if class_entry.nil? || class_entry.missing_views.empty?

        class_entry.missing_views.map do |action_name|
          action_entry = class_entry.find_action(action_name)
          Rigor::Analysis::Diagnostic.new(
            path: path,
            line: action_entry&.def_line || 1,
            column: action_entry&.def_column || 1,
            severity: :warning,
            rule: "missing-view",
            message: "`#{class_entry.class_name}##{action_name}` has no view template " \
                     "under `#{@views_root}/#{underscore(class_entry.class_name.delete_prefix('::'))}/`"
          )
        end
      end

      def canonical_path(path)
        File.realpath(path)
      rescue StandardError
        File.expand_path(path)
      end

      def underscore(name)
        name.gsub("::", "/")
            .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
            .gsub(/([a-z\d])([A-Z])/, '\1_\2')
            .downcase
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

    Rigor::Plugin.register(Actionmailer)
  end
end
