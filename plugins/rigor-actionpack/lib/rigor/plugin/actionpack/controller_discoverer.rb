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

          locate_classes_and_modules(parse_result.value).each do |declaration_node|
            entry = build_entry(declaration_node)
            entries[entry.class_name] = entry if entry.class_name
          end
        rescue Plugin::AccessDeniedError, Errno::ENOENT
          nil
        end

        # Recursive top-level descent. Returns every `ClassNode`
        # and `ModuleNode` reachable through nested `module` /
        # `class` blocks. Pre-fix only the **first** ClassNode
        # was harvested, which meant controller files that
        # define multiple classes lost coverage AND concern
        # modules under `app/controllers/concerns/` were ignored
        # entirely. The latter was the dominant Mastodon /
        # Redmine FP: `before_action :require_account_signature!`
        # references a method defined in a concern module that
        # the harvester never visited.
        def locate_classes_and_modules(node, into = [])
          return into unless node.is_a?(Prism::Node)

          into << node if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
          node.compact_child_nodes.each do |child|
            locate_classes_and_modules(child, into)
          end
          into
        end

        def build_entry(declaration_node)
          name = qualified_name_for(declaration_node.constant_path)
          parent_name = if declaration_node.is_a?(Prism::ClassNode) && declaration_node.superclass
                          qualified_name_for(declaration_node.superclass)
                        end
          methods = collect_def_names(declaration_node.body)
          includes = collect_include_targets(declaration_node.body)
          ControllerIndex::Entry.new(
            class_name: name,
            defined_methods: methods.freeze,
            parent_class_name: parent_name,
            included_module_names: includes.freeze
          )
        end

        def collect_def_names(node, accumulator = [])
          return accumulator unless node.is_a?(Prism::Node)

          accumulator << node.name if node.is_a?(Prism::DefNode) && node.receiver.nil?
          node.compact_child_nodes.each { |child| collect_def_names(child, accumulator) }
          accumulator
        end

        # Collects the qualified-constant targets passed to
        # `include` calls inside the body. Stops at nested
        # `ClassNode` / `ModuleNode` boundaries so a class
        # declared inside a concern doesn't pull the concern's
        # includes into itself.
        def collect_include_targets(node, accumulator = [])
          return accumulator unless node.is_a?(Prism::Node)
          return accumulator if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)

          if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :include
            (node.arguments&.arguments || []).each do |arg|
              name = qualified_name_for(arg)
              accumulator << name if name
            end
          end

          node.compact_child_nodes.each { |child| collect_include_targets(child, accumulator) }
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
