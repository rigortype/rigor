# frozen_string_literal: true

require "yaml"

module Rigor
  module Plugin
    class Routes < Rigor::Plugin::Base
      # Frozen value object — the parsed route table the plugin
      # caches. Each entry is keyed by the helper base name
      # (`"users"`, `"edit_user"`, …) and carries the HTTP method,
      # path template, and the ordered list of placeholders.
      #
      # Marshal-clean by construction so it round-trips through
      # `Cache::Store#fetch_or_compute` without needing a custom
      # serialize / deserialize pair.
      class RouteTable
        Entry = Struct.new(:name, :method, :path, :params, keyword_init: true) do
          def arity = params.size
        end

        attr_reader :entries

        def initialize(entries)
          @entries = entries.freeze
          freeze
        end

        def empty? = entries.empty?
        def names = entries.keys
        def find(name) = entries[name]

        def self.parse(yaml_text)
          rows = YAML.safe_load(yaml_text, permitted_classes: [], aliases: false) || []
          unless rows.is_a?(Array)
            raise ArgumentError,
                  "routes file must be a YAML array of `{name, method, path}` rows, got #{rows.class}"
          end

          entries = rows.each_with_object({}) do |row, table|
            unless row.is_a?(Hash) && row["name"].is_a?(String) && row["path"].is_a?(String)
              raise ArgumentError, "invalid route entry: #{row.inspect}"
            end

            name = row["name"]
            path = row["path"]
            params = path.scan(/:([a-z_][a-z0-9_]*)/).flatten.freeze
            table[name] = Entry.new(
              name: name,
              method: (row["method"] || "GET").to_s.upcase.freeze,
              path: path.freeze,
              params: params
            ).freeze
          end

          new(entries.freeze)
        end
      end
    end
  end
end
