# frozen_string_literal: true

require "yaml"

require_relative "configuration/dependencies"
require_relative "configuration/severity_profile"

module Rigor
  class Configuration # rubocop:disable Metrics/ClassLength
    # File-discovery order for `Configuration.load(nil)`.
    #
    # The first file present is loaded; the others are NOT
    # implicitly merged. To extend a base config explicitly the
    # winning file MUST list the base via `includes:`.
    #
    # `.rigor.yml` is a developer-local override (typically
    # gitignored); `.rigor.dist.yml` is the project default
    # (committed to the repo). When both are present the
    # developer's local override wins outright — there is no
    # implicit auto-merge.
    DISCOVERY_ORDER = %w[.rigor.yml .rigor.dist.yml].freeze
    # Back-compat alias. Keep here so external callers that read
    # `Configuration::DEFAULT_PATH` for help text / fixture paths
    # still work; the discovery list is the canonical source.
    DEFAULT_PATH = DISCOVERY_ORDER.first

    # Built-in exclusion patterns appended to `exclude:` so vendored
    # dependencies, Bundler artefacts, and JavaScript node_modules are
    # never analysed by accident when a directory glob expands. Users
    # cannot disable these defaults; the trade-off is that analysing
    # any of these paths is essentially never what the user wants
    # (they're build outputs / external dependencies, not source).
    #
    # We deliberately keep this list narrow. `tmp/` and similar
    # directories vary across project layouts (Rails has `tmp/`,
    # libraries usually don't); user-supplied `exclude:` entries
    # in `.rigor.yml` cover the project-specific cases.
    BUILTIN_EXCLUDES = %w[
      **/vendor/bundle/**
      **/.bundle/**
      **/node_modules/**
    ].freeze

    DEFAULTS = {
      "target_ruby" => "4.0",
      "paths" => ["lib"],
      "exclude" => [],
      "plugins" => [],
      "disable" => [],
      "libraries" => [],
      "signature_paths" => nil,
      "fold_platform_specific_paths" => false,
      "cache" => {
        "path" => ".rigor/cache"
      },
      "plugins_io" => {
        "network" => "disabled",
        "allowed_paths" => [],
        "allowed_url_hosts" => []
      },
      "severity_profile" => "balanced",
      "severity_overrides" => {},
      "dependencies" => {
        "source_inference" => [],
        "budget_per_gem" => Configuration::Dependencies::DEFAULT_BUDGET_PER_GEM
      },
      "parallel" => {
        # ADR-15 Phase 4c — when greater than zero, `rigor check`
        # dispatches per-file analysis across N Ractor workers
        # built around {Rigor::Analysis::WorkerSession}.
        # `0` (default) keeps the sequential coordinator path
        # bit-for-bit unchanged. The CLI's `--workers=N` flag
        # and the `RIGOR_RACTOR_WORKERS` env var both override
        # this setting; precedence is CLI > env > config > 0.
        "workers" => 0
      }
    }.freeze

    # Top-level keys whose values are file/directory paths that
    # MUST be resolved relative to the config file's directory.
    # `exclude:` is intentionally NOT in this list — its entries
    # are glob patterns (`**/vendor/**`), not paths.
    PATH_KEYS = %w[paths signature_paths].freeze
    private_constant :PATH_KEYS

    attr_reader :target_ruby, :paths, :exclude_patterns, :plugins, :cache_path, :disabled_rules,
                :libraries, :signature_paths, :fold_platform_specific_paths,
                :plugins_io_network, :plugins_io_allowed_paths,
                :plugins_io_allowed_url_hosts,
                :severity_profile, :severity_overrides,
                :dependencies, :parallel_workers

    # Loads a configuration file.
    #
    # `path == nil` triggers auto-discovery against
    # {DISCOVERY_ORDER}. The first present file in that list is
    # loaded; if none exist the built-in {DEFAULTS} are used.
    #
    # When a path is supplied (whether by auto-discovery or by
    # the caller) the YAML body is processed for `includes:`
    # recursively, and every relative path inside path-bearing
    # keys (`paths:`, `signature_paths:`, `plugins_io.allowed_paths:`,
    # `includes:`) is resolved against THAT file's directory.
    # The resolution is per-file: an included file's relative
    # paths resolve against the included file's directory, not
    # the top-level file. Path resolution mirrors
    # [PHPStan](https://phpstan.org/config-reference#paths).
    def self.load(path = nil)
      resolved = path || discover
      return new(DEFAULTS) if resolved.nil? || !File.exist?(resolved)

      data = load_with_includes(resolved)
      new(DEFAULTS.merge(data))
    end

    # Returns the path to the config file Rigor would load
    # under auto-discovery, or `nil` when neither candidate
    # exists. Public so the CLI / spec drift checks can
    # introspect the resolved file.
    def self.discover
      DISCOVERY_ORDER.find { |candidate| File.exist?(candidate) }
    end

    # Reads `path` (which MUST exist) plus every file listed in
    # its `includes:` chain, merging them under the order:
    # included files first (in declaration order), then the
    # current file's own keys override. Relative paths inside
    # each file are resolved against that file's directory.
    def self.load_with_includes(path, visited: Set.new)
      absolute = File.expand_path(path)
      raise ArgumentError, "circular include: #{absolute}" if visited.include?(absolute)

      raw = YAML.safe_load_file(absolute, aliases: false) || {}
      raise ArgumentError, "config file must be a YAML mapping: #{absolute}" unless raw.is_a?(Hash)

      base_dir = File.dirname(absolute)
      includes = Array(raw.delete("includes") || [])
      data = resolve_paths_in(raw, base_dir)
      next_visited = visited + [absolute]
      merge_includes(data, includes, base_dir, next_visited)
    end

    def self.merge_includes(data, includes, base_dir, visited)
      return data if includes.empty?

      accumulated = {}
      includes.each do |inc|
        inc_path = File.expand_path(inc.to_s, base_dir)
        unless File.exist?(inc_path)
          raise ArgumentError, "include not found: #{inc.inspect} (referenced from #{base_dir})"
        end

        accumulated = deep_merge(accumulated, load_with_includes(inc_path, visited: visited))
      end
      deep_merge(accumulated, data)
    end

    # Per-file path resolution. Each path-bearing key listed in
    # {PATH_KEYS} plus the nested `plugins_io.allowed_paths:`
    # entries get their relative paths expanded against the
    # config file's directory. `cache.path:` is intentionally
    # left as-is so end-user messages (e.g. `--cache-stats`
    # output) keep the project-relative form the user wrote.
    def self.resolve_paths_in(data, base_dir)
      return data unless data.is_a?(Hash)

      out = data.dup
      PATH_KEYS.each { |key| resolve_path_key!(out, key, base_dir) }
      resolve_plugins_io_paths!(out, base_dir)
      out
    end

    def self.resolve_path_key!(out, key, base_dir)
      return unless out.key?(key) && !out[key].nil?

      out[key] = Array(out[key]).map { |p| File.expand_path(p.to_s, base_dir) }
    end

    def self.resolve_plugins_io_paths!(out, base_dir)
      plugins_io = out["plugins_io"]
      return unless plugins_io.is_a?(Hash) && plugins_io["allowed_paths"]

      duped = plugins_io.dup
      duped["allowed_paths"] = Array(plugins_io["allowed_paths"]).map { |p| File.expand_path(p.to_s, base_dir) }
      out["plugins_io"] = duped
    end

    def self.deep_merge(left, right)
      return right unless left.is_a?(Hash) && right.is_a?(Hash)

      merged = left.dup
      right.each do |key, value|
        merged[key] = merge_value(key, merged, value)
      end
      merged
    end

    # Most keys are right-wins (override) or recursively
    # merged hashes. ADR-10 § "config-conflict diagnostic"
    # carves out `dependencies.source_inference[]`: the
    # per-gem merge across `includes:` chains needs union
    # behaviour with mode-conflict detection. The Hash itself
    # still merges deeply; only the inner array gets
    # concatenated so {Dependencies.from_h} sees every
    # contributor's entries and can dedupe them.
    def self.merge_value(key, merged, value)
      if key == "dependencies" && merged[key].is_a?(Hash) && value.is_a?(Hash)
        merge_dependencies_hash(merged[key], value)
      elsif merged.key?(key) && merged[key].is_a?(Hash) && value.is_a?(Hash)
        deep_merge(merged[key], value)
      else
        value
      end
    end

    def self.merge_dependencies_hash(left, right)
      out = deep_merge(left, right)
      left_si = Array(left["source_inference"])
      right_si = Array(right["source_inference"])
      both_empty = left_si.empty? && right_si.empty?
      out["source_inference"] = left_si + right_si unless both_empty # rigor:disable flow.always-truthy-condition
      out
    end
    private_class_method :load_with_includes, :merge_includes, :resolve_paths_in, :deep_merge,
                         :merge_value, :merge_dependencies_hash

    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
    def initialize(data = DEFAULTS)
      cache = DEFAULTS.fetch("cache").merge(data.fetch("cache", {}))
      plugins_io = DEFAULTS.fetch("plugins_io").merge(data.fetch("plugins_io", {}))

      @target_ruby = coerce_target_ruby(data.fetch("target_ruby", DEFAULTS.fetch("target_ruby")))
      @paths = Array(data.fetch("paths", DEFAULTS.fetch("paths"))).map(&:to_s).freeze
      user_excludes = Array(data.fetch("exclude", DEFAULTS.fetch("exclude"))).map(&:to_s)
      @exclude_patterns = (BUILTIN_EXCLUDES + user_excludes).uniq.freeze
      @plugins = Array(data.fetch("plugins", DEFAULTS.fetch("plugins"))).map do |entry|
        coerce_plugin_entry(entry)
      end.freeze
      @disabled_rules = Array(data.fetch("disable", DEFAULTS.fetch("disable"))).map(&:to_s).freeze
      @libraries = Array(data.fetch("libraries", DEFAULTS.fetch("libraries"))).map(&:to_s).freeze
      sig_paths = data.fetch("signature_paths", DEFAULTS.fetch("signature_paths"))
      @signature_paths = sig_paths.nil? ? nil : Array(sig_paths).map(&:to_s).freeze
      @fold_platform_specific_paths = data.fetch(
        "fold_platform_specific_paths", DEFAULTS.fetch("fold_platform_specific_paths")
      ) == true
      @cache_path = cache.fetch("path").to_s
      @plugins_io_network = coerce_network_policy(plugins_io.fetch("network"))
      @plugins_io_allowed_paths = Array(plugins_io.fetch("allowed_paths")).map(&:to_s).freeze
      @plugins_io_allowed_url_hosts = Array(plugins_io.fetch("allowed_url_hosts")).map(&:to_s).freeze
      @severity_profile = coerce_severity_profile(
        data.fetch("severity_profile", DEFAULTS.fetch("severity_profile"))
      )
      @severity_overrides = coerce_severity_overrides(
        data.fetch("severity_overrides", DEFAULTS.fetch("severity_overrides"))
      )
      @dependencies = Dependencies.from_h(
        data.fetch("dependencies", DEFAULTS.fetch("dependencies"))
      )
      parallel = DEFAULTS.fetch("parallel").merge(data.fetch("parallel", {}))
      @parallel_workers = coerce_parallel_workers(parallel.fetch("workers"))
      # Ractor migration Phase 2a: deep-freeze the
      # Configuration so it is `Ractor.shareable?`. Every
      # ivar above is now either a frozen value (Symbol /
      # nil / Boolean) or an explicitly frozen
      # collection / value object; freezing `self` makes the
      # whole carrier safe to send across Ractor boundaries
      # (and catches accidental post-init mutation in any
      # caller). See
      # `docs/design/20260514-ractor-migration.md`.
      freeze
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    def to_h
      {
        "target_ruby" => target_ruby,
        "paths" => paths,
        "exclude" => exclude_patterns - BUILTIN_EXCLUDES,
        "plugins" => plugins,
        "disable" => disabled_rules,
        "libraries" => libraries,
        "signature_paths" => signature_paths,
        "fold_platform_specific_paths" => fold_platform_specific_paths,
        "cache" => {
          "path" => cache_path
        },
        "plugins_io" => {
          "network" => plugins_io_network.to_s,
          "allowed_paths" => plugins_io_allowed_paths,
          "allowed_url_hosts" => plugins_io_allowed_url_hosts
        },
        "severity_profile" => severity_profile.to_s,
        "severity_overrides" => severity_overrides.to_h { |k, v| [k, v.to_s] },
        "dependencies" => dependencies.to_h,
        "parallel" => {
          "workers" => parallel_workers
        }
      }
    end

    private

    # Accepts either `"rigor-foo"` (gem-name shorthand) or
    # `{ "gem" => "rigor-foo", "id" => "foo", "config" => {...} }`
    # (full form). Returns the canonical hash form so the loader
    # works against a single shape.
    def coerce_plugin_entry(entry)
      case entry
      when String
        entry.dup.freeze
      when Hash
        entry.to_h { |k, v| [k.to_s, v] }.freeze
      else
        raise ArgumentError,
              "plugin configuration entry must be a String or Hash, got #{entry.inspect}"
      end
    end

    # `target_ruby` is passed to `Prism.parse_file(path, version:)` at
    # the analyser's three parse sites (`Analysis::Runner`,
    # `CLI::TypeOfCommand`, `CLI::TypeScanCommand`) so projects that
    # target an older Ruby get parse errors for syntax their target
    # doesn't support. Format validation here is loose — accepts
    # any `<major>.<minor>` or `<major>.<minor>.<patch>` form, plus
    # the literal `"latest"`. Prism itself enforces the supported
    # set and raises `ArgumentError` for versions it does not
    # recognise (e.g. `"1.0"`); the parse-time error message names
    # the version, so the user can correct the setting.
    TARGET_RUBY_FORMAT = /\A(?:\d+\.\d+(?:\.\d+)?|latest)\z/
    private_constant :TARGET_RUBY_FORMAT

    def coerce_target_ruby(value)
      s = value.to_s
      unless s.match?(TARGET_RUBY_FORMAT)
        raise ArgumentError,
              "target_ruby must be a version (e.g. \"3.4\", \"4.0\", \"3.4.0\") or \"latest\", got #{value.inspect}"
      end

      s.dup.freeze
    end

    # Slice 2 only accepts `:disabled` for the network policy. The
    # YAML scalar may arrive as a String (`"disabled"`) or already
    # as the Symbol; coerce to the canonical Symbol shape so the
    # downstream `TrustPolicy` constructor stays strict.
    #
    # The accepted set is duplicated from
    # {Rigor::Plugin::TrustPolicy::VALID_NETWORK_POLICIES} so
    # `Configuration` does not require the plugin namespace at
    # load time (Configuration is loaded before Plugin in
    # `lib/rigor.rb`); the two stay in lockstep via spec.
    VALID_NETWORK_POLICIES = %i[disabled allowlist].freeze
    private_constant :VALID_NETWORK_POLICIES

    # ADR-15 Phase 4c — accepts a non-negative Integer (or a
    # string-shaped one from YAML files that miss type
    # annotations). Negative / non-integer values raise so
    # typos / bad YAML fail loudly rather than silently
    # disabling parallelism.
    def coerce_parallel_workers(value)
      integer = Integer(value)
      raise ArgumentError, "parallel.workers must be >= 0, got #{value.inspect}" if integer.negative?

      integer
    rescue TypeError, ArgumentError => e
      raise ArgumentError, "parallel.workers must be a non-negative Integer, got #{value.inspect} (#{e.message})"
    end

    def coerce_network_policy(value)
      sym = value.to_sym
      unless VALID_NETWORK_POLICIES.include?(sym)
        raise ArgumentError,
              "plugins_io.network must be one of #{VALID_NETWORK_POLICIES.inspect}, got #{value.inspect}"
      end

      sym
    end

    # ADR-8 § "Severity profile" — accepts the canonical Symbol
    # form or its String spelling; rejects unknown profile names
    # so typos fail loudly.
    def coerce_severity_profile(value)
      sym = value.to_sym
      unless SeverityProfile::VALID_PROFILES.include?(sym)
        raise ArgumentError,
              "severity_profile must be one of " \
              "#{SeverityProfile::VALID_PROFILES.inspect}, got #{value.inspect}"
      end

      sym
    end

    # ADR-8 § "Severity profile" — `severity_overrides:` is a
    # `{ rule => severity }` map. Keys are canonical rule ids
    # (`call.undefined-method`) or family wildcards (`call`).
    # Values are {SeverityProfile::VALID_SEVERITIES} symbols
    # (`:error` / `:warning` / `:info` / `:off`). Unknown
    # severities raise; unknown rule ids are silently kept (the
    # override is inert until the rule lands).
    def coerce_severity_overrides(value)
      raise ArgumentError, "severity_overrides must be a Hash, got #{value.inspect}" unless value.is_a?(Hash)

      value.to_h do |k, v|
        sym = v.to_sym
        unless SeverityProfile::VALID_SEVERITIES.include?(sym)
          raise ArgumentError,
                "severity_overrides[#{k.inspect}] must be one of " \
                "#{SeverityProfile::VALID_SEVERITIES.inspect}, got #{v.inspect}"
        end

        [k.to_s, sym]
      end.freeze
    end
  end
end
