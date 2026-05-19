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
    # - Lazy lookup (`t('.title')` resolved against the
    #   rendered controller / view path) is out of scope.
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
        version: "0.1.0",
        description: "Validates I18n `t(key)` calls against `config/locales/*.yml`.",
        config_schema: {
          "locale_search_paths" => :array,
          "configured_locales" => :array
        }
      )

      DEFAULT_LOCALE_SEARCH_PATHS = ["config/locales"].freeze
      DEFAULT_CONFIGURED_LOCALES = ["en"].freeze

      producer :locale_index do |_params|
        loader = LocaleLoader.new(
          io_boundary: io_boundary,
          search_paths: @locale_search_paths
        )
        index = loader.load
        @load_errors = loader.load_errors
        index
      end

      def init(_services)
        @locale_search_paths = Array(config.fetch("locale_search_paths", DEFAULT_LOCALE_SEARCH_PATHS)).map(&:to_s)
        @configured_locales = Array(config.fetch("configured_locales", DEFAULT_CONFIGURED_LOCALES)).map(&:to_s)
        @locale_index = nil
        @load_errors = []
        @load_errors_emitted = false
        @runtime_error = nil
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        index = locale_index_or_nil
        diagnostics = []
        diagnostics.concat(consume_load_error_diagnostics(path)) unless @load_errors.empty?
        return diagnostics + [runtime_error_diagnostic(path)] if index.nil? && @runtime_error
        return diagnostics if index.nil? || index.empty?

        diagnostics.concat(
          Analyzer.diagnose(
            path: path,
            root: root,
            locale_index: index,
            configured_locales: @configured_locales
          ).map { |diag| build_diagnostic(diag) }
        )
        diagnostics
      end

      private

      def locale_index_or_nil
        return @locale_index if @locale_index

        # Pass an explicit descriptor covering every `.yml` / `.yaml`
        # file under the configured locale search paths so the cache
        # invalidates when locale files are added, removed, or edited.
        # Without it the auto-built descriptor depends on the
        # `IoBoundary`'s in-process read history — empty on the
        # first call of a fresh process — so warm cache hits would
        # serve stale `LocaleIndex` data and hide per-call load
        # errors (a malformed YAML in one run would not surface
        # when a healthy cache entry from an earlier run exists).
        descriptor = glob_descriptor(@locale_search_paths, "**/*.yml", "**/*.yaml")
        @locale_index = cache_for(:locale_index, params: {}, descriptor: descriptor).call
      rescue StandardError => e
        @runtime_error = "rigor-rails-i18n: failed to load locales: #{e.class}: #{e.message}"
        nil
      end

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
        Rigor::Analysis::Diagnostic.new(
          path: path, line: 1, column: 1,
          message: @runtime_error,
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

    Rigor::Plugin.register(RailsI18n)
  end
end
