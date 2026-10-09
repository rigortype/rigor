# frozen_string_literal: true

require "prism"

require "rigor/inference/declaration_walk"

require_relative "resource_collector"
require_relative "resource_index"

module Rigor
  module Plugin
    class Alba < Rigor::Plugin::Base
      # Reads every `.rb` file under the configured search paths through the plugin's `IoBoundary`, runs a
      # {ResourceCollector} over each and merges the results into one {ResourceIndex}.
      class ResourceDiscoverer
        def initialize(io_boundary:, search_paths:)
          @io_boundary = io_boundary
          @search_paths = search_paths
        end

        def discover
          entries = []
          associations = []
          ruby_files_under(@search_paths).each do |path|
            contents = read_safely(path)
            next if contents.nil?

            parsed = Prism.parse(contents)
            next unless parsed.success?

            collector = ResourceCollector.new
            Rigor::Inference::DeclarationWalk.run(
              parsed.value, [collector], Rigor::Inference::DeclarationWalk::Context.root(nesting: [])
            )
            entries.concat(collector.class_entries)
            associations.concat(collector.associations)
          end
          ResourceIndex.new(classes: merge(entries), associations: associations)
        end

        private

        # A class reopened across files: it is a resource if any opening says so.
        def merge(entries)
          entries.group_by(&:name).map do |name, openings|
            headed = openings.find(&:superclass) || openings.first
            ResourceIndex::ClassEntry.new(
              name: name,
              superclass: headed.superclass,
              nesting: headed.nesting,
              includes_resource: openings.any?(&:includes_resource)
            )
          end
        end

        def read_safely(path)
          @io_boundary.read_file(path)
        rescue Plugin::AccessDeniedError, Errno::ENOENT
          nil
        end

        def ruby_files_under(roots)
          roots.flat_map do |root|
            absolute = File.expand_path(root)
            # ADR-45 WD1b (#613) — boundary-probed: a root that appears later invalidates the warm run.
            next [] unless @io_boundary.directory?(absolute)

            Dir.glob(File.join(absolute, "**", "*.rb"))
          end
        end
      end
    end
  end
end
