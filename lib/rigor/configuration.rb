# frozen_string_literal: true

require "yaml"

require_relative "configuration/severity_profile"

module Rigor
  class Configuration # rubocop:disable Metrics/ClassLength
    DEFAULT_PATH = ".rigor.yml"
    DEFAULTS = {
      "target_ruby" => "4.0",
      "paths" => ["lib"],
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
        "allowed_paths" => []
      },
      "severity_profile" => "balanced",
      "severity_overrides" => {}
    }.freeze

    attr_reader :target_ruby, :paths, :plugins, :cache_path, :disabled_rules,
                :libraries, :signature_paths, :fold_platform_specific_paths,
                :plugins_io_network, :plugins_io_allowed_paths,
                :severity_profile, :severity_overrides

    def self.load(path = DEFAULT_PATH)
      data = if File.exist?(path)
               YAML.safe_load_file(path, aliases: false) || {}
             else
               {}
             end

      new(DEFAULTS.merge(data))
    end

    def initialize(data = DEFAULTS) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity
      cache = DEFAULTS.fetch("cache").merge(data.fetch("cache", {}))
      plugins_io = DEFAULTS.fetch("plugins_io").merge(data.fetch("plugins_io", {}))

      @target_ruby = coerce_target_ruby(data.fetch("target_ruby", DEFAULTS.fetch("target_ruby")))
      @paths = Array(data.fetch("paths", DEFAULTS.fetch("paths"))).map(&:to_s)
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
      @severity_profile = coerce_severity_profile(
        data.fetch("severity_profile", DEFAULTS.fetch("severity_profile"))
      )
      @severity_overrides = coerce_severity_overrides(
        data.fetch("severity_overrides", DEFAULTS.fetch("severity_overrides"))
      )
    end

    def to_h
      {
        "target_ruby" => target_ruby,
        "paths" => paths,
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
          "allowed_paths" => plugins_io_allowed_paths
        },
        "severity_profile" => severity_profile.to_s,
        "severity_overrides" => severity_overrides.to_h { |k, v| [k, v.to_s] }
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
    VALID_NETWORK_POLICIES = %i[disabled].freeze
    private_constant :VALID_NETWORK_POLICIES

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
