# frozen_string_literal: true

require "did_you_mean"

require_relative "config_path"
require_relative "flow_contribution/conflict"
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
  # {.bundled_plugin_signature_path_warnings} widens that by one step, to a value that
  # resolves to *part* of what it looks like. It belongs here because the symptom is the
  # same one — a cluster of `call.undefined-method` on working code, traceable to a config
  # line nothing in the output names.
  #
  # Every check is held to the same bar that {SignaturePathAudit} set: it mirrors the
  # loader's own acceptance test, so a warning means the loader really did load nothing, and
  # it never fires on a setup that works. The rule-token checks lean on the reach of `disable:`
  # and `severity_overrides:` being enumerable (issues #1953, #1985): a plugin's row answers only
  # to its qualified `plugin.<id>.<rule>` id (or `plugin.<id>`), so a bare plugin rule there is
  # inert (see {.disable_token_warning}, {.override_key_warning}). A `plugin.`-qualified token is
  # checked only against `plugins:`, and a token under a non-check engine family
  # (`rbs_extended.*`, `rbs.*`, `dynamic.*`) is left alone, since the engine emits those ids
  # outside the catalogue.
  module ConfigAudit
    # One config-level finding. `kind` discriminates the source key (`:signature_path`,
    # `:bundled_plugin_signature_path`, `:library`, `:disabled_rule`, `:severity_override`,
    # `:bundler_bundle_path`, `:bundler_lockfile`, `:rbs_collection_lockfile`); `fields` carries the kind-specific
    # structured data merged into {#to_h} for JSON consumers.
    Warning = Data.define(:kind, :message, :fields) do
      def to_h
        { "kind" => kind.to_s, "message" => message }.merge(fields)
      end
    end

    # @param project_root — the directory the run's relative bundler / collection
    #   paths resolve against (the CLI's CWD), used only by the explicit-path checks.
    def self.warnings(configuration, project_root: Dir.pwd)
      unknown_key_warnings(configuration) +
        signature_path_warnings(configuration) +
        bundled_plugin_signature_path_warnings(configuration) +
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

    # The one member of this module whose subject is a configured value that resolves to
    # *something*: a `signature_paths:` entry loading a bundled plugin's own `sig/` while
    # `plugins:` never names that plugin (issue #697). The RBS arrives, its manifest does not,
    # and the declarations that manifest marks deliberately partial (ADR-26 `open_receivers:`)
    # are then read as complete — so the symptom is this module's usual one, a cluster of
    # high-confidence `call.undefined-method` firings on code that runs, with nothing pointing
    # at the config line that caused them.
    #
    # It is a warning and not a fix on purpose. Teaching the check rules to recognise this
    # route would be a fourth way for a class to be open-receiver protected, and settling
    # where that membership belongs is [#660](https://github.com/rigortype/rigor/issues/660)'s
    # question; until it is answered, the honest move is to make the misconfiguration loud
    # rather than to grow the mechanism. The false positive itself still fires.
    def self.bundled_plugin_signature_path_warnings(configuration)
      routes = SignaturePathAudit.bundled_plugin_routes(configuration.signature_paths, configuration.plugins)
      routes.map do |route|
        Warning.new(kind: :bundled_plugin_signature_path, message: route.message,
                    fields: { "path" => route.path, "gem" => route.gem })
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

    # `disable:` tokens that reach no row ({.disable_token_warning}) and `severity_overrides:` keys
    # that reach none ({.override_key_warning}).
    def self.rule_token_warnings(configuration)
      plugin_ids = configured_plugin_ids(configuration.plugins)
      disable = Array(configuration.disabled_rules).filter_map do |token|
        disable_token_warning(token.to_s, plugin_ids)
      end
      overrides = configuration.severity_overrides.keys.filter_map do |key|
        override_key_warning(key.to_s, plugin_ids)
      end
      disable + overrides
    end

    # Issue #1985 — the plugin loader's own rows, which a `severity_overrides:` key names by their qualified
    # id; they also answer to the bare `load-error` / `runtime-error`.
    PLUGIN_LOADER_ROWS = %w[plugin_loader.load-error plugin_loader.runtime-error].freeze
    private_constant :PLUGIN_LOADER_ROWS

    # A warning for a `severity_overrides:` key that can reach no row, or nil. Mirrors {.disable_token_warning}
    # (issue #1985): a plugin's row answers only to its qualified `plugin.<id>.<rule>` or `plugin.<id>`, so a
    # `plugin.`-qualified key naming an unconfigured plugin, and any key outside the built-in vocabulary that is
    # not a qualified plugin id (a plugin's bare rule included), is inert. A reserved run-level row is the home of
    # this map, so naming one is never flagged; `all` is not a family wildcard here, so it is.
    def self.override_key_warning(key, plugin_ids)
      reason = override_key_problem(key, plugin_ids)
      return nil if reason.nil?

      Warning.new(kind: :severity_override, message: "severity_overrides: #{key.inspect} #{reason}",
                  fields: { "token" => key })
    end

    def self.override_key_problem(key, plugin_ids)
      return "is not a recognized rule id; the override has no effect" if key == "all"
      return nil unless Array(Analysis::CheckRules.resolve_rule_token(key)).empty?

      if key.start_with?(Analysis::CheckRules::PLUGIN_FAMILY_PREFIX)
        return nil if plugin_ids.nil? || plausible_plugin_token?(key, plugin_ids)

        "names no plugin `plugins:` configures; the override has no effect"
      elsif key.start_with?("plugin_loader.")
        "is not a recognized rule id; the override has no effect" unless PLUGIN_LOADER_ROWS.include?(key)
      elsif inert_builtin_token?(key)
        "is not a recognized rule id; the override has no effect"
      elsif !non_check_engine_token?(key) && !severity_only_id?(key)
        "is not a recognized rule id; the override has no effect " \
          "(if this is a plugin's rule, write it as `plugin.<id>.<rule>`)"
      end
    end
    private_class_method :override_key_problem

    # Issue #1953 — the run-level rows the diagnostic policy keeps on `severity_overrides:` and the
    # baseline. `disable:` does not reach them by any spelling, so naming one there is inert.
    RESERVED_RUN_LEVEL_FAMILIES = %w[plugin_loader plugin_trust rbs.coverage dynamic.dependency-source].freeze
    RESERVED_RUN_LEVEL_IDS = %w[load-error runtime-error pool-degraded].freeze
    private_constant :RESERVED_RUN_LEVEL_FAMILIES, :RESERVED_RUN_LEVEL_IDS

    # A warning for a `disable:` token that can reach no row, or nil. Since issue #1953 the list's
    # reach is exactly enumerable for three shapes, and those are what this flags:
    #
    # - a token naming a reserved run-level row ({RESERVED_RUN_LEVEL_FAMILIES} /
    #   {RESERVED_RUN_LEVEL_IDS}), which the list never reaches;
    # - a `plugin.`-qualified token naming no plugin `plugins:` configures — checked only when
    #   every entry's manifest id is known without loading it ({.configured_plugin_ids});
    # - any other token that is not `all`, a family, a legacy alias or a catalogue / `pre-eval.*`
    #   id. A bare id never reaches a plugin's row, so a plugin's bare rule is inert here too.
    #
    # A token under a non-check engine family (`rbs_extended.*`, `rbs.*`, `dynamic.*`) or a known
    # non-catalogue engine id stays unflagged: under-warning is this module's FP-safe direction.
    def self.disable_token_warning(token, plugin_ids)
      return nil if effective_disable_token?(token)

      reason = disable_token_problem(token, plugin_ids)
      return nil if reason.nil?

      Warning.new(kind: :disabled_rule, message: "disable: #{token.inspect} #{reason}",
                  fields: { "token" => token })
    end

    def self.disable_token_problem(token, plugin_ids)
      if reserved_run_level_token?(token)
        "names a run-level row, which `disable:` does not reach; use `severity_overrides:` or a baseline"
      elsif token.start_with?(Analysis::CheckRules::PLUGIN_FAMILY_PREFIX)
        unless plugin_ids.nil? || plausible_plugin_token?(token, plugin_ids)
          "names no plugin `plugins:` configures; the suppression has no effect"
        end
      elsif inert_builtin_token?(token)
        "is not a recognized rule id; the suppression has no effect"
      elsif !non_check_engine_token?(token)
        "is not a recognized rule id; the suppression has no effect " \
          "(if this is a plugin's rule, write it as `plugin.<id>.<rule>`)"
      end
    end
    private_class_method :disable_token_problem

    def self.effective_disable_token?(token)
      return true if token == "all"

      !Array(Analysis::CheckRules.resolve_rule_token(token)).empty?
    end
    private_class_method :effective_disable_token?

    def self.reserved_run_level_token?(token)
      RESERVED_RUN_LEVEL_IDS.include?(token) ||
        RESERVED_RUN_LEVEL_FAMILIES.any? { |family| token == family || token.start_with?("#{family}.") }
    end
    private_class_method :reserved_run_level_token?

    # Bare ids that a `severity_overrides:` key re-stamps but a marker or `disable:` cannot suppress: the `--explain`
    # `fallback` row and the `contribution_merge` conflict reasons (`FlowContribution::CONFLICT_VALID_REASONS`,
    # kebab-cased). They are not in `CheckRules::NON_CHECK_DIAGNOSTIC_IDS`, which would silence the warnings for a
    # `disable:` token or marker naming them. `spec/rigor/config_audit_spec.rb` pins this list's completeness.
    SEVERITY_ONLY_IDS = (%w[fallback] + FlowContribution::CONFLICT_VALID_REASONS.map { it.to_s.tr("_", "-") }).freeze
    private_constant :SEVERITY_ONLY_IDS

    def self.severity_only_id?(key)
      SEVERITY_ONLY_IDS.include?(key)
    end
    private_class_method :severity_only_id?

    def self.non_check_engine_token?(token)
      Analysis::CheckRules::NON_CHECK_DIAGNOSTIC_IDS.include?(token) ||
        Analysis::CheckRules::NON_CHECK_DIAGNOSTIC_FAMILIES.include?(token.split(".").first)
    end
    private_class_method :non_check_engine_token?

    # `plugin.<id>` or `plugin.<id>.<rule>` for a configured id. A manifest id may itself hold a
    # dot, so the token is matched against each id rather than split.
    def self.plausible_plugin_token?(token, plugin_ids)
      rest = token.delete_prefix(Analysis::CheckRules::PLUGIN_FAMILY_PREFIX)
      plugin_ids.any? { |id| rest == id || rest.start_with?("#{id}.") }
    end
    private_class_method :plausible_plugin_token?

    # The manifest id of every `plugins:` entry, or nil when one cannot be known without loading
    # the plugin. An explicit `id:` is the id; a bundled plugin's id is its gem name minus the
    # `rigor-` prefix ({Plugin::FirstParty}); a third-party gem named without `id:` may register
    # any id, so its presence turns the plugin-token check off. An `enabled: false` entry counts:
    # the user has found the plugin, and under-warning is the FP-safe direction.
    def self.configured_plugin_ids(plugins)
      Array(plugins).each_with_object(Set.new) do |raw, ids|
        entry = raw.is_a?(Hash) ? raw.to_h { |key, value| [key.to_s, value] } : { "gem" => raw.to_s }
        if entry["id"]
          ids << entry["id"].to_s
        elsif bundled_plugin_gem?(entry["gem"].to_s)
          ids << entry["gem"].to_s.delete_prefix(BUNDLED_GEM_PREFIX)
        else
          return nil
        end
      end
    end
    private_class_method :configured_plugin_ids

    BUNDLED_GEM_PREFIX = "rigor-"
    private_constant :BUNDLED_GEM_PREFIX

    def self.bundled_plugin_gem?(gem)
      return false unless gem.start_with?(BUNDLED_GEM_PREFIX)

      File.file?(File.join(SignaturePathAudit::BUNDLED_PLUGINS_ROOT, gem, "lib", "#{gem}.rb"))
    end
    private_class_method :bundled_plugin_gem?

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
      return if path.nil? || File.directory?(ConfigPath.absolute(path, project_root))

      warnings << Warning.new(kind: kind, message: "#{key}: #{path.inspect} is not a directory",
                              fields: { "path" => path })
    end

    def self.add_missing_file(warnings, path, project_root, kind, key)
      return if path.nil? || File.file?(ConfigPath.absolute(path, project_root))

      warnings << Warning.new(kind: kind, message: "#{key}: #{path.inspect} does not exist", fields: { "path" => path })
    end
  end
end
