# frozen_string_literal: true

module Rigor
  class Configuration
    # ADR-8 § "Severity profile" — three named profiles tune the severity of every built-in
    # `Analysis::CheckRules` rule for the run. Profiles are applied as a **final filter** on
    # `Diagnostic#severity`: rules emit with their authored severity, then `Analysis::Runner` re-stamps the
    # severity from the active profile before adding the diagnostic to the result.
    #
    # Three profiles:
    #
    # - `lenient`: Only proven (`:no`) diagnostics are errors; uncertain (`:maybe`) drop to `:warning`.
    #   Useful for incremental adoption on legacy code.
    # - `balanced` (**default**): Current Rigor stance — most rules `:error`; `dump.type` `:info`; uncertain
    #   rules `:warning`.
    # - `strict`: Every rule is `:error`. CI-friendly.
    #
    # The profile resolution order:
    #
    # 1. Profile-specific entry for the canonical rule id.
    # 2. The diagnostic's own authored severity (the rule's default).
    # 3. `:error` (catch-all so an unrecognised rule still emits visibly — the public-API drift spec catches
    #    the bookkeeping gap separately).
    module SeverityProfile
      VALID_PROFILES = %i[lenient balanced strict].freeze
      VALID_SEVERITIES = %i[error warning info off].freeze

      DEFAULT_PROFILE = :balanced

      # Per-profile severity tables. Missing keys fall back to the diagnostic's authored severity (typically
      # `:error`).
      PROFILES = {
        lenient: {
          "call.undefined-method" => :error,
          "call.self-undefined-method" => :off,
          "call.unresolved-toplevel" => :off,
          "call.wrong-arity" => :error,
          "call.argument-type-mismatch" => :warning,
          "call.possible-nil-receiver" => :warning,
          "call.raise-non-exception" => :warning,
          "flow.always-raises" => :warning,
          "flow.unreachable-branch" => :info,
          "flow.dead-assignment" => :info,
          "flow.always-truthy-condition" => :info,
          "flow.unreachable-clause" => :info,
          "flow.duplicate-hash-key" => :info,
          "flow.return-in-ensure" => :info,
          "flow.shadowed-rescue-clause" => :info,
          "assert.type-mismatch" => :error,
          "dump.type" => :info,
          "def.return-type-mismatch" => :warning,
          "def.method-visibility-mismatch" => :warning,
          "def.override-visibility-reduced" => :off,
          "def.override-return-widened" => :off,
          "def.override-param-narrowed" => :off,
          "def.ivar-write-mismatch" => :warning,
          # ADR-8 companion (PHPStan IgnoreParseErrorRule-modelled): a broken suppression comment is
          # equally bad in every profile — it silently fails to do what the author believes it does — so
          # both rules stay :warning across all three profiles (including strict).
          "suppression.unknown-rule" => :warning,
          "suppression.empty" => :warning,
          "suppression.unknown-marker" => :warning,
          # ADR-100 — a new required diagnostic (ADR-50 WD1), so it is `:off` in every shipped profile and
          # reaches a user only through the `use-of-void-value` bleeding-edge feature, which overrides this
          # to `:warning`.
          # ADR-103 WD8 / #383 — opt-in twice over (the `effects:` block, then the author's own
          # envelope directive), so it is never unsolicited noise and needs no bleeding-edge gate:
          # `:warning` even under lenient, `:error` under strict.
          "effect.envelope-exceeded" => :warning,
          # ADR-103 WD14 / #386 — the inherited-bound reading rides its sibling's severities exactly:
          # both-sides-authored (someone wrote the ancestor's envelope), and as strict as proven.
          "effect.liskov-widened" => :warning,
          # ADR-103 WD14 — `unknown-label` info / info / warning. It reports that a bound stopped
          # bounding, never that code is wrong, so even `strict` stops at `:warning`.
          "effect.unknown-label" => :info,
          # The residual is advisory in every profile: it says a declaration is inert, and the fix is
          # a config edit the author may deliberately not want.
          "effect.annotations-unchecked" => :info,
          "static.value-use.void" => :off,
          # Opt-in author assertion: you only see it if you wrote a
          # `conforms-to` directive, so it stays a :warning even in
          # lenient — it is never unsolicited noise.
          "rbs_extended.unsatisfied-conformance" => :warning
        }.freeze,
        balanced: {
          "call.undefined-method" => :error,
          "call.self-undefined-method" => :off,
          "call.unresolved-toplevel" => :warning,
          "call.wrong-arity" => :error,
          "call.argument-type-mismatch" => :error,
          "call.possible-nil-receiver" => :error,
          "call.raise-non-exception" => :error,
          "flow.always-raises" => :error,
          "flow.unreachable-branch" => :warning,
          "flow.dead-assignment" => :warning,
          "flow.always-truthy-condition" => :warning,
          # ADR-47 WD4: stays :info (not :warning like its siblings) in the
          # default balanced profile until the regression-corpus FP gate is
          # green; promote to :warning once Mastodon/GitLab/Redmine triage
          # to zero net false positives.
          "flow.unreachable-clause" => :info,
          "flow.duplicate-hash-key" => :warning,
          "flow.return-in-ensure" => :warning,
          "flow.shadowed-rescue-clause" => :warning,
          "assert.type-mismatch" => :error,
          "dump.type" => :info,
          "def.return-type-mismatch" => :warning,
          "def.method-visibility-mismatch" => :error,
          "def.override-visibility-reduced" => :warning,
          "def.override-return-widened" => :warning,
          "def.override-param-narrowed" => :warning,
          "def.ivar-write-mismatch" => :warning,
          "suppression.unknown-rule" => :warning,
          "suppression.empty" => :warning,
          "suppression.unknown-marker" => :warning,
          "static.value-use.void" => :off,
          "effect.envelope-exceeded" => :warning,
          "effect.liskov-widened" => :warning,
          "effect.unknown-label" => :info,
          "effect.annotations-unchecked" => :info,
          "rbs_extended.unsatisfied-conformance" => :warning
        }.freeze,
        strict: {
          "call.undefined-method" => :error,
          "call.self-undefined-method" => :off,
          "call.unresolved-toplevel" => :error,
          "call.wrong-arity" => :error,
          "call.argument-type-mismatch" => :error,
          "call.possible-nil-receiver" => :error,
          "call.raise-non-exception" => :error,
          "flow.always-raises" => :error,
          "flow.unreachable-branch" => :error,
          "flow.dead-assignment" => :error,
          "flow.always-truthy-condition" => :error,
          # ADR-47: strict opts into the new rule at :warning (one notch
          # below its :error siblings) while it proves out — see the
          # balanced-profile note above.
          "flow.unreachable-clause" => :warning,
          "flow.duplicate-hash-key" => :error,
          "flow.return-in-ensure" => :error,
          "flow.shadowed-rescue-clause" => :error,
          "assert.type-mismatch" => :error,
          "dump.type" => :error,
          "def.return-type-mismatch" => :error,
          "def.method-visibility-mismatch" => :error,
          "def.override-visibility-reduced" => :error,
          "def.override-return-widened" => :error,
          "def.override-param-narrowed" => :error,
          "def.ivar-write-mismatch" => :error,
          "suppression.unknown-rule" => :warning,
          "suppression.empty" => :warning,
          "suppression.unknown-marker" => :warning,
          # `:off` even under strict: the gate is `bleeding_edge:`, not the profile (ADR-50 WD1 / ADR-100).
          "static.value-use.void" => :off,
          "effect.envelope-exceeded" => :error,
          "effect.liskov-widened" => :error,
          "effect.unknown-label" => :warning,
          # `:info` even under strict: a residual that failed a build would punish the project for
          # carrying an annotation it has not opted into checking, which is the opposite of the point.
          "effect.annotations-unchecked" => :info,
          "rbs_extended.unsatisfied-conformance" => :error
        }.freeze
      }.freeze

      module_function

      # Resolves the configured severity for a diagnostic given the active profile and any per-rule
      # overrides.
      #
      # @param rule [String, nil] canonical rule id (`call.undefined-method`).
      # @param authored_severity [Symbol] severity the rule emitted the diagnostic with (`:error`, `:warning`,
      #   `:info`).
      # @param profile [Symbol] one of {VALID_PROFILES}; falls back to {DEFAULT_PROFILE} for unknown values.
      # @param overrides [Hash{String => Symbol}] per-rule severity overrides from `.rigor.yml`'s
      #   `severity_overrides:` map. Keys are canonical rule ids; values are {VALID_SEVERITIES} symbols.
      #   Family-wildcard keys (`call`) match every rule under that prefix.
      # @param bleeding_edge_overrides [Hash{String => Symbol}] the severity map imposed by the active ADR-50
      #   § WD2 bleeding-edge features ({Rigor::BleedingEdge.severity_overrides_for}). Consulted *below* the
      #   user's own `overrides` (so an explicit `severity_overrides:` entry, exact or family wildcard,
      #   always wins) and *above* the profile table. Exact rule ids only — the overlay never carries family
      #   wildcards. Empty while the overlay is unpopulated, so the default leaves resolution bit-for-bit
      #   unchanged.
      # @return [Symbol] the resolved severity. Returns `:off` to mean "drop the diagnostic entirely".
      def resolve(rule:, authored_severity:, profile: DEFAULT_PROFILE, overrides: {}, bleeding_edge_overrides: {})
        return authored_severity if rule.nil?

        override = overrides[rule] || family_override(rule, overrides)
        return override.to_sym if override

        bleeding = bleeding_edge_overrides[rule]
        return bleeding.to_sym if bleeding

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
