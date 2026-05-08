# frozen_string_literal: true

module Rigor
  class Configuration
    # ADR-8 § "Severity profile" — three named profiles tune the
    # severity of every built-in `Analysis::CheckRules` rule for
    # the run. Profiles are applied as a **final filter** on
    # `Diagnostic#severity`: rules emit with their authored
    # severity, then `Analysis::Runner` re-stamps the severity
    # from the active profile before adding the diagnostic to
    # the result.
    #
    # Three profiles:
    #
    # - `lenient`: Only proven (`:no`) diagnostics are errors;
    #   uncertain (`:maybe`) drop to `:warning`. Useful for
    #   incremental adoption on legacy code.
    # - `balanced` (**default**): Current Rigor stance — most
    #   rules `:error`; `dump.type` `:info`; uncertain rules
    #   `:warning`.
    # - `strict`: Every rule is `:error`. CI-friendly.
    #
    # The profile resolution order:
    #
    # 1. Profile-specific entry for the canonical rule id.
    # 2. The diagnostic's own authored severity (the rule's
    #    default).
    # 3. `:error` (catch-all so an unrecognised rule still emits
    #    visibly — the public-API drift spec catches the
    #    bookkeeping gap separately).
    module SeverityProfile
      VALID_PROFILES = %i[lenient balanced strict].freeze
      VALID_SEVERITIES = %i[error warning info off].freeze

      DEFAULT_PROFILE = :balanced

      # Per-profile severity tables. Missing keys fall back to
      # the diagnostic's authored severity (typically `:error`).
      PROFILES = {
        lenient: {
          "call.undefined-method" => :error,
          "call.wrong-arity" => :error,
          "call.argument-type-mismatch" => :warning,
          "call.possible-nil-receiver" => :warning,
          "flow.always-raises" => :warning,
          "flow.unreachable-branch" => :info,
          "flow.dead-assignment" => :info,
          "flow.always-truthy-condition" => :info,
          "assert.type-mismatch" => :error,
          "dump.type" => :info,
          "def.return-type-mismatch" => :warning,
          "def.method-visibility-mismatch" => :warning,
          "def.ivar-write-mismatch" => :warning
        }.freeze,
        balanced: {
          "call.undefined-method" => :error,
          "call.wrong-arity" => :error,
          "call.argument-type-mismatch" => :error,
          "call.possible-nil-receiver" => :error,
          "flow.always-raises" => :error,
          "flow.unreachable-branch" => :warning,
          "flow.dead-assignment" => :warning,
          "flow.always-truthy-condition" => :warning,
          "assert.type-mismatch" => :error,
          "dump.type" => :info,
          "def.return-type-mismatch" => :warning,
          "def.method-visibility-mismatch" => :error,
          "def.ivar-write-mismatch" => :warning
        }.freeze,
        strict: {
          "call.undefined-method" => :error,
          "call.wrong-arity" => :error,
          "call.argument-type-mismatch" => :error,
          "call.possible-nil-receiver" => :error,
          "flow.always-raises" => :error,
          "flow.unreachable-branch" => :error,
          "flow.dead-assignment" => :error,
          "flow.always-truthy-condition" => :error,
          "assert.type-mismatch" => :error,
          "dump.type" => :error,
          "def.return-type-mismatch" => :error,
          "def.method-visibility-mismatch" => :error,
          "def.ivar-write-mismatch" => :error
        }.freeze
      }.freeze

      module_function

      # Resolves the configured severity for a diagnostic given
      # the active profile and any per-rule overrides.
      #
      # @param rule [String, nil] canonical rule id (`call.undefined-method`).
      # @param authored_severity [Symbol] severity the rule emitted
      #   the diagnostic with (`:error`, `:warning`, `:info`).
      # @param profile [Symbol] one of {VALID_PROFILES}; falls back
      #   to {DEFAULT_PROFILE} for unknown values.
      # @param overrides [Hash{String => Symbol}] per-rule severity
      #   overrides from `.rigor.yml`'s `severity_overrides:` map.
      #   Keys are canonical rule ids; values are
      #   {VALID_SEVERITIES} symbols. Family-wildcard keys
      #   (`call`) match every rule under that prefix.
      # @return [Symbol] the resolved severity. Returns `:off` to
      #   mean "drop the diagnostic entirely".
      def resolve(rule:, authored_severity:, profile: DEFAULT_PROFILE, overrides: {})
        return authored_severity if rule.nil?

        override = overrides[rule] || family_override(rule, overrides)
        return override.to_sym if override

        profile_table = PROFILES[profile] || PROFILES.fetch(DEFAULT_PROFILE)
        profile_table.fetch(rule, authored_severity)
      end

      def family_override(rule, overrides)
        family = rule.split(".").first
        return nil if family.nil?

        overrides[family]
      end

      private_class_method :family_override
    end
  end
end
