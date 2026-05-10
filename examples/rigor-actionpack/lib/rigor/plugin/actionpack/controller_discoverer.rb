# frozen_string_literal: true

require "prism"

require_relative "controller_index"

module Rigor
  module Plugin
    class Actionpack < Rigor::Plugin::Base
      # Walks `controller_search_paths` building a
      # {ControllerIndex} of `(class_name, methods,
      # parent_class_name)` triples. Used by Phase 2 (filter
      # chains) to validate that `before_action :name`
      # references a method defined on the controller or its
      # immediate parent.
      #
      # Limitations (per the Phase 2 design):
      #
      # - Single-class-per-file is the assumption — the walker
      #   records the first top-level class node it encounters
      #   per file. Files with multiple classes (rare in
      #   `app/controllers/` outside of nested namespaces) only
      #   contribute their first class.
      # - One level of inheritance only. `class FooController <
      #   ApplicationController` records `FooController`'s
      #   methods + parent_class_name `"ApplicationController"`,
      #   and the index resolves the inherited methods at lookup
      #   time. Two-level chains (`AdminController <
      #   AdminBaseController < ApplicationController`) are not
      #   walked transitively in Phase 2; `AdminController`'s
      #   inherited methods are limited to what
      #   `AdminBaseController` directly defines, not what
      #   `AdminBaseController` inherits.
      # - Modules / `concerning :Auth` blocks are not walked.
      class ControllerDiscoverer
        def initialize(io_boundary:, search_paths:)
          @io_boundary = io_boundary
          @search_paths = search_paths
        end

        # @return [ControllerIndex]
        def discover
          entries = {}
          ruby_files_under(@search_paths).each do |path|
            harvest(path, entries)
          end
          ControllerIndex.new(entries.freeze)
        end

        private

        def ruby_files_under(roots)
          roots.flat_map do |root|
            absolute = File.expand_path(root)
            next [] unless File.directory?(absolute)

            Dir.glob(File.join(absolute, "**", "*.rb"))
          end
        end

        def harvest(path, entries)
          contents = @io_boundary.read_file(path)
          parse_result = Prism.parse(contents)
          return unless parse_result.errors.empty?

          first_class = locate_first_class(parse_result.value)
          return if first_class.nil?

          entry = build_entry(first_class)
          entries[entry.class_name] = entry
        rescue Plugin::AccessDeniedError, Errno::ENOENT
          nil
        end

        # Recursive top-level descent — accepts files that wrap
        # the class in a `module` block (`module Admin; class
        # WidgetsController < ApplicationController; end; end`).
        def locate_first_class(node)
          return nil unless node.is_a?(Prism::Node)
          return node if node.is_a?(Prism::ClassNode)

          node.compact_child_nodes.each do |child|
            found = locate_first_class(child)
            return found if found
          end
          nil
        end

        def build_entry(class_node)
          class_name = qualified_name_for(class_node.constant_path)
          parent_name = class_node.superclass.nil? ? nil : qualified_name_for(class_node.superclass)
          methods = collect_def_names(class_node.body)
          ControllerIndex::Entry.new(
            class_name: class_name, defined_methods: methods.freeze,
            parent_class_name: parent_name
          )
        end

        def collect_def_names(node, accumulator = [])
          return accumulator unless node.is_a?(Prism::Node)

          accumulator << node.name if node.is_a?(Prism::DefNode) && node.receiver.nil?
          node.compact_child_nodes.each { |child| collect_def_names(child, accumulator) }
          accumulator
        end

        def qualified_name_for(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode
            parent = node.parent.nil? ? nil : qualified_name_for(node.parent)
            return nil if !node.parent.nil? && parent.nil?

            parent.nil? ? node.name.to_s : "#{parent}::#{node.name}"
          end
        end
      end
    end
  end
end
