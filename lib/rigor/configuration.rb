# frozen_string_literal: true

require "yaml"

module Rigor
  class Configuration
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
      }
    }.freeze

    attr_reader :target_ruby, :paths, :plugins, :cache_path, :disabled_rules,
                :libraries, :signature_paths, :fold_platform_specific_paths

    def self.load(path = DEFAULT_PATH)
      data = if File.exist?(path)
               YAML.safe_load_file(path, aliases: false) || {}
             else
               {}
             end

      new(DEFAULTS.merge(data))
    end

    def initialize(data = DEFAULTS) # rubocop:disable Metrics/AbcSize
      cache = DEFAULTS.fetch("cache").merge(data.fetch("cache", {}))

      @target_ruby = data.fetch("target_ruby", DEFAULTS.fetch("target_ruby")).to_s
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
  end
end
