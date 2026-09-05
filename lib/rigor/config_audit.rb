# frozen_string_literal: true

require "did_you_mean"

require_relative "signature_path_audit"
# ADR-87 WD4 — only the pure rule-id table (`ALL_RULES` / `RULE_FAMILIES`) is needed, so require the light
# `rule_ids.rb` rather than the engine-pulling `check_rules.rb`; keeps `config_audit` (loaded by every check)
# off the inference engine so the boot-slimming hit path stays engine-free.
require_relative "analysis/check_rules/rule_ids"

module Rigor
  # Audits a loaded {Configuration} for the class of mistake where a configured value
  # silently resolves to nothing — a typo'd or moved path, an unknown library name, an inert
  # rule id. The shared failure mode is that the loader filters the bad entry without a word,
  # so the only symptom is downstream and confusing: missing signatures turn every call into
  # the types they were meant to cover into a high-confidence `call.undefined-method`, and an
  # unrecognised suppression token leaves the rule firing as if the `disable:` line were
  # never written. This module surfaces each such entry up front so the cause is visible
  # instead of inferred.
  #
  # Every check is held to the same bar that {SignaturePathAudit} set: it mirrors the
  # loader's own acceptance test, so a warning means the loader really did load nothing, and
  # it never fires on a setup that works. In particular the rule-token check only flags a
  # token under a built-in family (`call`, `flow`, …) — a plugin- or `rbs_extended.*` rule id
  # (whose family Rigor cannot statically enumerate, since a `node_rule` block emits any
  # `rule:` string it likes) is left alone, so disabling a plugin rule is never mistaken for
  # a typo.
  module ConfigAudit
    # One config-level finding. `kind` discriminates the source key (`:signature_path`,
    # `:library`, `:disabled_rule`, `:severity_override`, `:bundler_bundle_path`,
    # `:bundler_lockfile`, `:rbs_collection_lockfile`); `fields` carries the kind-specific
    # structured data merged into {#to_h} for JSON consumers.
    Warning = Data.define(:kind, :message, :fields) do
      def to_h
        { "kind" => kind.to_s, "message" => message }.merge(fields)
      end
    end

    # @param project_root [String] the directory the run's relative bundler / collection
    #   paths resolve against (the CLI's CWD), used only by the explicit-path checks.
    def self.warnings(configuration, project_root: Dir.pwd)
      unknown_key_warnings(configuration) +
        signature_path_warnings(configuration) +
        library_warnings(configuration) +
        rule_token_warnings(configuration) +
        explicit_path_warnings(configuration, project_root)
    end

    # Top-level keys the loader does not own. The archetypal case is a typo — `excludee:` for
    # `exclude:` — which the loader drops in silence, so the exclusion never applies and the run
    # reports errors from the very files the user meant to skip, with nothing anywhere saying the key
    # did nothing. That is exactly this module's class of mistake, and it was the one whole-key
    # instance of it going unwarned.
    #
    # A reserved namespace ({Configuration::RESERVED_NAMESPACES}) is unknown *on purpose* — another
    # implementation reads it from the same file — so it is exempt. {Configuration#unknown_keys}
    # already applies that exemption; warning here would push users to delete the key their other
    # tool needs.
    #
    # **Top level only, and deliberately.** A nested check would have to name each group's known keys,
    # and DEFAULTS cannot supply them: `DEFAULTS["dependencies"]` carries `source_inference` and
    # `budget_per_gem` but not `budget_overrun_strategy`, which is real (`Configuration::Dependencies`
    # reads it), documented, and schema-declared — so a DEFAULTS-keyed nested check would flag a
    # working config. `severity_overrides:` is an open map of rule ids besides. Nested unknown keys are
    # the schema tier's job: every nested object in `schemas/rigor-config.schema.json` is
    # `additionalProperties: false`, and `config_schema_spec` keeps it complete
    # ([ADR-99](../../docs/adr/99-config-schema-authority.md), `docs/internal-spec/config.md`).
    def self.unknown_key_warnings(configuration)
      configuration.unknown_keys.map do |key|
        suggestion = suggest_config_key(key)
        hint = suggestion ? " Did you mean `#{suggestion}`?" : ""
        Warning.new(
          kind: :unknown_key,
          message: "`#{key}` is not a recognized configuration key; it has no effect.#{hint}",
          fields: { "key" => key, "suggestion" => suggestion }
        )
      end
    end

    # Nearest known key, or nil. Uses `DidYouMean::SpellChecker` — the engine behind Ruby's own
    # `NoMethodError` hints, and the one `Plugin::Base.suggest` wraps. Called directly rather than
    # through that helper because `plugin/base.rb` pulls Prism and the diagnostic model in, and
    # ADR-87 WD4 keeps this file (loaded by every check) off that path; `did_you_mean` is stdlib.
    def self.suggest_config_key(key)
      DidYouMean::SpellChecker.new(dictionary: Configuration::KNOWN_KEYS).correct(key.to_s).first
    end
    private_class_method :suggest_config_key

    # `signature_paths:` entries that resolve to nothing — delegated to {SignaturePathAudit},
    # which mirrors the loader's `directory?` + recursive `**/*.rbs` acceptance test.
    def self.signature_path_warnings(configuration)
      SignaturePathAudit.warnings(configuration.signature_paths).map do |entry|
        Warning.new(
          kind: :signature_path,
          message: entry.message,
          fields: { "path" => entry.path, "status" => entry.status.to_s, "rbs_file_count" => entry.rbs_file_count }
        )
      end
    end

    # `libraries:` entries RBS does not recognise. Uses the same
    # `RBS::EnvironmentLoader#has_library?` guard the loader filters through
    # ({Environment::RbsLoader} `build_env_for`), so a flagged name is exactly one the loader
    # skipped. Fails soft: if RBS itself raises, no warning rather than a crash.
    def self.library_warnings(configuration)
      configured = Array(configuration.libraries)
      return [] if configured.empty?

      loader = ::RBS::EnvironmentLoader.new
      configured.reject { |lib| loader.has_library?(library: lib.to_s, version: nil) }.map do |lib|
        Warning.new(
          kind: :library,
          message: "libraries: #{lib.to_s.inspect} is not an available RBS library (no signatures loaded from it)",
          fields: { "name" => lib.to_s }
        )
      end
    rescue StandardError
      []
    end

    # `disable:` tokens and `severity_overrides:` keys that name no rule. Restricted to
    # tokens under a built-in family so a plugin rule id is never mis-flagged (see the module
    # docstring).
    def self.rule_token_warnings(configuration)
      disable = Array(configuration.disabled_rules).filter_map do |token|
        next unless inert_builtin_token?(token.to_s)

        Warning.new(
          kind: :disabled_rule,
          message: "disable: #{token.to_s.inspect} is not a recognized rule id; the suppression has no effect",
          fields: { "token" => token.to_s }
        )
      end
      overrides = configuration.severity_overrides.keys.filter_map do |key|
        next unless inert_builtin_token?(key.to_s)

        Warning.new(
          kind: :severity_override,
          message: "severity_overrides: #{key.to_s.inspect} is not a recognized rule id; the override has no effect",
          fields: { "token" => key.to_s }
        )
      end
      disable + overrides
    end

    # True when `token` looks like a built-in rule id but matches none — its first segment
    # is a built-in family yet it is neither a bare family wildcard nor a known canonical id.
    # A token whose family is not built-in (a plugin / `rbs_extended.*` rule, or a bare
    # legacy alias) is deliberately NOT flagged: it may resolve at run time, so
    # under-warning is the FP-safe choice.
    def self.inert_builtin_token?(token)
      family = token.split(".").first
      return false unless Analysis::CheckRules::RULE_FAMILIES.include?(family)
      return false if token == family
      return false if Analysis::CheckRules::ALL_RULES.include?(token)

      true
    end

    # Explicitly-configured bundler / rbs-collection paths that do not exist. Only the
    # explicit form is audited (a nil value means auto-detection, which finding nothing is
    # normal); messages stay factual about the path rather than guessing the fallback.
    def self.explicit_path_warnings(configuration, project_root)
      warnings = []
      add_missing_dir(warnings, configuration.bundler_bundle_path, project_root,
                      :bundler_bundle_path, "bundler.bundle_path")
      add_missing_file(warnings, configuration.bundler_lockfile, project_root,
                       :bundler_lockfile, "bundler.lockfile")
      add_missing_file(warnings, configuration.rbs_collection_lockfile, project_root,
                       :rbs_collection_lockfile, "rbs_collection.lockfile")
      warnings
    end

    def self.add_missing_dir(warnings, path, project_root, kind, key)
      return if path.nil? || File.directory?(File.expand_path(path, project_root))

      warnings << Warning.new(kind: kind, message: "#{key}: #{path.inspect} is not a directory",
                              fields: { "path" => path })
    end

    def self.add_missing_file(warnings, path, project_root, kind, key)
      return if path.nil? || File.file?(File.expand_path(path, project_root))

      warnings << Warning.new(kind: kind, message: "#{key}: #{path.inspect} does not exist", fields: { "path" => path })
    end
  end
end
