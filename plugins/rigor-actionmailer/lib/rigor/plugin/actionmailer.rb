# frozen_string_literal: true

require "rigor/plugin"

require_relative "actionmailer/mailer_index"
require_relative "actionmailer/mailer_discoverer"
require_relative "actionmailer/analyzer"

module Rigor
  module Plugin
    # rigor-actionmailer — validates `Mailer.action(args)` call sites and detects missing view templates.
    #
    # Tier 1C of the [Rails plugins roadmap](../../../../docs/design/20260508-rails-plugins-roadmap.md).
    # Statically discovers mailer classes by walking `mailer_search_paths` and parsing each file with
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
    # 1. **Method existence** — `UserMailer.welcome(user)` is flagged when `welcome` is not defined on
    #    `UserMailer`.
    # 2. **Argument arity** — calls with too few / too many positional arguments emit `wrong-arity`.
    # 3. **View template existence** — for every action method, at least one of
    #    `app/views/<mailer_underscore>/<action>.{html,text}.{erb,haml,slim}` must exist. Missing
    #    actions get a `missing-view` diagnostic anchored on the action's `def`.
    #
    # ## Limitations (v0.1.0)
    #
    # - Direct-superclass match only.
    # - Action methods are read from the syntactic instance-side `def` list. `define_method` actions are
    #   out of scope.
    # - Adding a brand-new view file does not invalidate the cache until something the mailer file
    #   touches changes.
    class Actionmailer < Rigor::Plugin::Base
      manifest(
        id: "actionmailer",
        # Bumped 2026-05-28 — extended RESERVED_CLASS_METHODS to include `respond_to?` / `public_send` /
        # `send` / `__send__` / `method` and friends so dynamic-dispatch idioms
        # (`Mailer.respond_to?(action)` / `Mailer.public_send(action)`) stop firing `unknown-action`
        # against the Ruby reflection method.
        version: "0.4.0",
        description: "Validates ActionMailer call shape and view template existence.",
        config_schema: {
          "mailer_search_paths" => { kind: :array, default: ["app/mailers"] },
          "mailer_base_classes" => { kind: :array, default: %w[ApplicationMailer ActionMailer::Base] },
          "views_root" => { kind: :string, default: "app/views" }
        }
      )

      # `watch:` covers every mailer class under `mailer_search_paths` AND every view template under
      # `views_root` (ADR-60 WD3) — a newly-added view a mailer references must invalidate the index,
      # and `view_exists?` failures the producer never records would otherwise be invisible to the
      # dependency descriptor.
      producer :mailer_index,
               watch: -> { [[@mailer_search_paths, "**/*.rb"], [@views_root, "**/*"]] } do |_params|
        MailerDiscoverer.new(
          io_boundary: io_boundary,
          search_paths: @mailer_search_paths,
          base_classes: @mailer_base_classes,
          views_root: @views_root
        ).discover
      end

      def init(_services)
        @mailer_search_paths = Array(config.fetch("mailer_search_paths")).map(&:to_s)
        @mailer_base_classes = Array(config.fetch("mailer_base_classes")).map(&:to_s)
        @views_root = config.fetch("views_root").to_s
      end

      # File-level: load-error + the missing-view check (anchored on the mailer's own source file, so it
      # is genuinely per-file, not per-call). The per-call mailer validation (action existence / arity)
      # runs over the engine-owned walk via the node_rule below (ADR-37). The mailer index is lazily
      # loaded + memoised, shared.
      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        index = producer_value(:mailer_index)
        return [load_error_diagnostic(path)] if index.nil? && producer_error(:mailer_index)
        return [] if index.nil? || index.empty?

        missing_view_diagnostics(path, index)
      end

      node_rule Prism::CallNode do |node, _scope, path|
        index = producer_value(:mailer_index)
        next [] if index.nil? || index.empty?

        diagnostics_for(Analyzer.violations_for(call_node: node, mailer_index: index), path: path, node: node)
      end

      private

      # Anchors `missing-view` diagnostics on the mailer file itself: when the file currently being
      # analysed is the mailer's source file, emit one diagnostic per missing action template at the
      # action's `def` location.
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
                     "under `#{@views_root}/#{Rigor::Plugin::Inflector.underscore(class_entry.class_name.delete_prefix('::'))}/`"
          )
        end
      end

      def canonical_path(path)
        File.realpath(path)
      rescue StandardError
        File.expand_path(path)
      end

      def load_error_diagnostic(path)
        error = producer_error(:mailer_index)
        Rigor::Analysis::Diagnostic.new(
          path: path, line: 1, column: 1,
          message: "rigor-actionmailer: failed to discover mailers: #{error.class}: #{error.message}",
          severity: :warning,
          rule: "load-error"
        )
      end
    end

    Rigor::Plugin.register(Actionmailer)
  end
end
