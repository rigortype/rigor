# frozen_string_literal: true

require "rigor/plugin"

require_relative "rails_i18n/locale_index"
require_relative "rails_i18n/locale_loader"
require_relative "rails_i18n/analyzer"

module Rigor
  module Plugin
    # rigor-rails-i18n — validates `t('key.path')` /
    # `I18n.t(...)` calls against `config/locales/*.yml`.
    #
    # Tier 1B of the [Rails plugins roadmap](../../../../docs/design/20260508-rails-plugins-roadmap.md).
    # Statically reads every YAML file under
    # `locale_search_paths` (default `config/locales/`),
    # builds a flat `dotted_key => Entry` index keyed by the
    # leaf key path, and validates every `t(literal_key, ...)`
    # call site against the catalogue. No Rails runtime
    # dependency.
    #
    # ## Configuration
    #
    #     plugins:
    #       - gem: rigor-rails-i18n
    #         config:
    #           locale_search_paths: ["config/locales"]   # default; optional
    #           configured_locales: ["en"]                # default; optional — locales the project ships
    #
    # ## What it checks
    #
    # 1. **Key existence** — `t('users.welcome')` is flagged
    #    when `users.welcome` does not appear in any locale.
    # 2. **Per-locale coverage** — when the key resolves in
    #    some locales but not all configured locales, the
    #    plugin emits a `missing-locale` warning. Suppressed
    #    when the call site passes `default:`.
    # 3. **Interpolation variables** — the leaf string's
    #    `%{var}` placeholders must match the call's keyword
    #    arguments. Missing placeholders are errors; extra
    #    arguments are warnings.
    #
    # ## Limitations (v0.1.0)
    #
    # - Only literal-string keys are validated. `t(key)` with
    #   a variable receiver is silently passed through.
    # - Lazy lookup (`t('.key')`) is supported for controller
    #   files (`app/controllers/**/*_controller.rb`): the key
    #   is expanded to `<controller_scope>.<action>.<key>`
    #   using the file path and the innermost enclosing `def`.
    #   Lazy keys in non-controller `.rb` files (models, helpers,
    #   mailers, …) are silently skipped — the controller/action
    #   scope cannot be statically determined there.
    # - Pluralization (`t('errors.messages.too_short',
    #   count: n)`) is recognised at the call site but the
    #   `count` key is not used to validate the locale's
    #   pluralization branches.
    # - YAML aliases / merges are accepted (Psych's standard
    #   `aliases: true`) but custom Ruby classes inside the
    #   YAML are NOT permitted (`safe_load`).
    class RailsI18n < Rigor::Plugin::Base
      manifest(
        id: "rails-i18n",
        # Bumped 2026-05-28 — skip `unknown-key` on Rails / rails-
        # i18n shipped defaults (`date.order`, `time.am`,
        # `support.array.*`, `errors.format`, …).
        version: "0.2.0",
        description: "Validates I18n `t(key)` calls against `config/locales/*.yml`.",
        config_schema: {
          "locale_search_paths" => { kind: :array, default: ["config/locales"] },
          "configured_locales" => { kind: :array, default: ["en"] }
        }
      )

      # `watch:` covers every `.yml` / `.yaml` file under the locale
      # search paths so the cache invalidates when locale files are
      # added, removed, or edited (ADR-60 WD3). `@load_errors` is a
      # producer-side capture: it is populated only when the block
      # runs (a cache miss / a watched file changed), which is exactly
      # when a malformed YAML must re-surface.
      producer :locale_index, watch: -> { [[@locale_search_paths, "**/*.yml", "**/*.yaml"]] } do |_params|
        loader = LocaleLoader.new(
          io_boundary: io_boundary,
          search_paths: @locale_search_paths
        )
        index = loader.load
        @load_errors = loader.load_errors
        index
      end

      def init(_services)
        @locale_search_paths = Array(config.fetch("locale_search_paths")).map(&:to_s)
        @configured_locales = Array(config.fetch("configured_locales")).map(&:to_s)
        @load_errors = []
        @load_errors_emitted = false
      end

      # File-level only: the once-per-run YAML load errors + the
      # runtime (cache-load) error. Per-call `t('key')` validation runs
      # over the engine-owned walk via the node_rule below (ADR-37). The
      # locale index is lazily loaded + memoised by `producer_value`.
      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        index = producer_value(:locale_index)
        diagnostics = []
        diagnostics.concat(consume_load_error_diagnostics(path)) unless @load_errors.empty?
        diagnostics << runtime_error_diagnostic(path) if index.nil? && producer_error(:locale_index)
        diagnostics
      end

      # The lazy-key (`t('.key')`) expansion needs the enclosing method
      # (the controller action), supplied by the node-rule NodeContext;
      # the controller scope comes from the file path.
      node_rule Prism::CallNode do |node, _scope, path, _fc, context|
        index = producer_value(:locale_index)
        next [] if index.nil? || index.empty?

        diagnostics_for(
          Analyzer.violations_for(
            call_node: node, locale_index: index, configured_locales: @configured_locales,
            controller_scope: Analyzer.controller_scope_from_path(path),
            action: context.enclosing_def&.name
          ),
          path: path, node: node
        )
      end

      private

      # The runner only invokes `diagnostics_for_file` for
      # Ruby files (`paths:` is filtered to `.rb`). YAML
      # parse errors therefore can't be anchored on the
      # offending locale file directly; instead, we emit
      # them once per run on the first analyzed Ruby file,
      # naming the offending YAML path in the message.
      def consume_load_error_diagnostics(path)
        return [] if @load_errors_emitted

        @load_errors_emitted = true
        @load_errors.map do |err|
          Rigor::Analysis::Diagnostic.new(
            path: path, line: 1, column: 1,
            message: "rigor-rails-i18n: failed to parse `#{err.path}`: #{err.message}",
            severity: :warning,
            rule: "load-error"
          )
        end
      end

      def runtime_error_diagnostic(path)
        error = producer_error(:locale_index)
        Rigor::Analysis::Diagnostic.new(
          path: path, line: 1, column: 1,
          message: "rigor-rails-i18n: failed to load locales: #{error.class}: #{error.message}",
          severity: :warning,
          rule: "load-error"
        )
      end
    end

    Rigor::Plugin.register(RailsI18n)
  end
end
