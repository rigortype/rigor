# frozen_string_literal: true

require "prism"

require "rigor/inference/declaration_walk"

require_relative "serializer_collector"
require_relative "serializer_index"

module Rigor
  module Plugin
    class Typelizer < Rigor::Plugin::Base
      # Reads every `.rb` file under the configured typelizer dirs and the project's `paths:` through the plugin's `IoBoundary`, runs a
      # {SerializerCollector} over each and merges the results into one {SerializerIndex}.
      class SerializerDiscoverer
        def initialize(io_boundary:, dirs:, project_paths: [])
          @io_boundary = io_boundary
          @dirs = dirs
          @project_paths = project_paths
        end

        def discover
          entries = []
          dir_files = ruby_files_under(@dirs)
          (dir_files | project_files).each do |path|
            contents = read_safely(path)
            next if contents.nil?

            parsed = Prism.parse(contents)
            next unless parsed.success?

            collector = SerializerCollector.new
            Rigor::Inference::DeclarationWalk.run(
              parsed.value, [collector], Rigor::Inference::DeclarationWalk::Context.root(nesting: [])
            )
            in_dirs = dir_files.include?(path)
            entries.concat(collector.class_entries.map { |entry| entry.with(in_dirs: in_dirs) })
          end
          SerializerIndex.new(classes: merge(entries))
        end

        private

        # A class reopened across files: it registers with typelizer if any opening says so.
        def merge(entries)
          entries.group_by(&:name).map do |name, openings|
            headed = openings.find(&:superclass) || openings.first
            SerializerIndex::ClassEntry.new(
              name: name, superclass: headed.superclass, nesting: headed.nesting,
              dsl: openings.any?(&:dsl), in_dirs: openings.any?(&:in_dirs)
            )
          end
        end

        def read_safely(path)
          @io_boundary.read_file(path)
        rescue Plugin::AccessDeniedError, Errno::ENOENT
          nil
        end

        # The project's `paths:` entries: a directory contributes its `.rb` tree, a `.rb` file itself.
        def project_files
          @project_paths.flat_map do |entry|
            absolute = File.expand_path(entry)
            if @io_boundary.directory?(absolute)
              Dir.glob(File.join(absolute, "**", "*.rb"))
            elsif absolute.end_with?(".rb") && @io_boundary.file?(absolute)
              [absolute]
            else
              []
            end
          end
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
