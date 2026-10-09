# frozen_string_literal: true

require "rigor/plugin"

require_relative "typelizer/serializer_index"
require_relative "typelizer/serializer_collector"
require_relative "typelizer/serializer_discoverer"

module Rigor
  module Plugin
    # rigor-typelizer — roots the serializer classes the typelizer gem
    # (https://github.com/skryukov/typelizer) generates TypeScript interfaces from, so `rigor unused` does not
    # list them as removal candidates.
    #
    # typelizer's `Typelizer.target_serializers` is `base_classes + base_classes.flat_map(&:descendants)`, where
    # `base_classes` holds every named class that ran `include Typelizer::DSL` or `extend Typelizer::DSL`. Such
    # a class may never be referenced from Ruby and still be consumed by the frontend through the generated
    # type, so the plugin publishes it — and every project subclass of it — as a `:reachability_roots` fact.
    #
    # The plugin adds no diagnostic and no return type. It models nothing at runtime: `reject_class` (a lambda
    # in typelizer's configuration that can drop a class from the output) is not evaluated, so a rejected class
    # is still rooted. That costs a hidden candidate, never a false report.
    class Typelizer < Rigor::Plugin::Base
      manifest(
        id: "typelizer",
        target_gems: ["typelizer"],
        version: "0.1.0",
        description: "Roots the serializer classes typelizer generates TypeScript interfaces from, " \
                     "for `rigor unused`.",
        config_schema: {
          # Typelizer::Railtie sets exactly these two when `Typelizer.dirs` is empty.
          "dirs" => { kind: :array, default: %w[app/resources app/serializers] }
        },
        produces: [:reachability_roots]
      )

      producer :serializer_index, watch: -> { watch_globs } do |_params|
        SerializerDiscoverer.new(io_boundary: io_boundary, dirs: @dirs, project_paths: @project_paths).discover
      end

      def init(services)
        @dirs = Array(config.fetch("dirs")).map(&:to_s)
        @project_paths = Array(services.configuration.paths).map(&:to_s)
      end

      def prepare(services)
        index = producer_value(:serializer_index)
        return if index.nil?

        roots = index.roots
        return if roots.empty?

        services.fact_store.publish(plugin_id: manifest.id, name: :reachability_roots, value: roots)
      end

      private

      # Superclass resolution reads every file of the project's `paths:` (a shadowing `Admin::Base` may live
      # outside `dirs`), so all of them are watched, not only `dirs`.
      def watch_globs
        (@dirs + @project_paths).filter_map do |entry|
          if io_boundary.directory?(File.expand_path(entry))
            [entry, "**/*.rb"]
          elsif entry.end_with?(".rb") && io_boundary.file?(File.expand_path(entry))
            [File.dirname(entry), File.basename(entry)]
          end
        end
      end
    end

    Rigor::Plugin.register(Typelizer)
  end
end
