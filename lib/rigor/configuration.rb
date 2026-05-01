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
      "cache" => {
        "path" => ".rigor/cache"
      }
    }.freeze

    attr_reader :target_ruby, :paths, :plugins, :cache_path, :disabled_rules

    def self.load(path = DEFAULT_PATH)
      data = if File.exist?(path)
               YAML.safe_load_file(path, aliases: false) || {}
             else
               {}
             end

      new(DEFAULTS.merge(data))
    end

    def initialize(data = DEFAULTS)
      cache = DEFAULTS.fetch("cache").merge(data.fetch("cache", {}))

      @target_ruby = data.fetch("target_ruby", DEFAULTS.fetch("target_ruby")).to_s
      @paths = Array(data.fetch("paths", DEFAULTS.fetch("paths"))).map(&:to_s)
      @plugins = Array(data.fetch("plugins", DEFAULTS.fetch("plugins"))).map(&:to_s)
      @disabled_rules = Array(data.fetch("disable", DEFAULTS.fetch("disable"))).map(&:to_s).freeze
      @cache_path = cache.fetch("path").to_s
    end

    def to_h
      {
        "target_ruby" => target_ruby,
        "paths" => paths,
        "plugins" => plugins,
        "disable" => disabled_rules,
        "cache" => {
          "path" => cache_path
        }
      }
    end
  end
end
