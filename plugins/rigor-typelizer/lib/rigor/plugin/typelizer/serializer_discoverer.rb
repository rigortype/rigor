# frozen_string_literal: true

require "prism"

require "rigor/inference/declaration_walk"

require_relative "serializer_collector"
require_relative "serializer_index"

module Rigor
  module Plugin
    class Typelizer < Rigor::Plugin::Base
      # Reads every `.rb` file under the configured typelizer dirs through the plugin's `IoBoundary`, runs a
      # {SerializerCollector} over each and merges the results into one {SerializerIndex}.
      class SerializerDiscoverer
        def initialize(io_boundary:, dirs:)
          @io_boundary = io_boundary
          @dirs = dirs
        end

        def discover
          entries = []
          ruby_files_under(@dirs).each do |path|
            contents = read_safely(path)
            next if contents.nil?

            parsed = Prism.parse(contents)
            next unless parsed.success?

            collector = SerializerCollector.new
            Rigor::Inference::DeclarationWalk.run(
              parsed.value, [collector], Rigor::Inference::DeclarationWalk::Context.root(nesting: [])
            )
            entries.concat(collector.class_entries)
          end
          SerializerIndex.new(classes: merge(entries))
        end

        private

        # A class reopened across files: it registers with typelizer if any opening says so.
        def merge(entries)
          entries.group_by(&:name).map do |name, openings|
            headed = openings.find(&:superclass) || openings.first
            SerializerIndex::ClassEntry.new(
              name: name, superclass: headed.superclass, nesting: headed.nesting, dsl: openings.any?(&:dsl)
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
