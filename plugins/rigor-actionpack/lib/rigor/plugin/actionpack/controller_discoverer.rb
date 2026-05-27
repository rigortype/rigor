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
      # ancestor chain.
      #
      # Two declaration shapes are recognised and qualified
      # the same way:
      #
      #   class Admin::AccountsController < BaseController
      #     # → registered as "Admin::AccountsController"
      #
      #   module Admin
      #     class AccountsController < BaseController
      #       # → ALSO registered as "Admin::AccountsController"
      #     end
      #   end
      #
      # Pre-fix the nested form ignored the enclosing `module
      # Admin` and registered the inner class as bare
      # `"AccountsController"`, overwriting the top-level
      # `app/controllers/accounts_controller.rb` entry. Mastodon
      # has both shapes for the same logical name (top-level
      # `AccountsController` + `Admin::AccountsController` +
      # `Api::V1::AccountsController`) and the overwrite caused
      # the wrong inheritance / method set to flow downstream,
      # producing dozens of false `unknown-filter-method`
      # diagnostics.
      #
      # Multi-level inheritance is also walked: `Admin::AccountsController
      # < BaseController < ApplicationController` resolves
      # methods from all three. Cycle-safe via a visited set.
      # The parent-name lookup is **lexically scoped** — a bare
      # `BaseController` reference inside `module Admin` first
      # tries `Admin::BaseController`, then falls through to
      # top-level `BaseController`, matching Ruby's constant-
      # resolution semantics.
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

          walk_declarations(parse_result.value, namespace: []) do |declaration_node, enclosing|
            entry = build_entry(declaration_node, enclosing)
            entries[entry.class_name] = entry if entry.class_name
          end
        rescue Plugin::AccessDeniedError, Errno::ENOENT
          nil
        end

        # Walks every `ClassNode` / `ModuleNode` in the AST,
        # yielding `[declaration_node, enclosing_namespace_array]`
        # for each. `enclosing` is the chain of module / class
        # qualifiers OUTSIDE the yielded declaration (e.g. for
        # `module Admin; class AccountsController; end; end`
        # the inner class yields with enclosing
        # `["Admin"]`). The yielded declaration's own segment
        # is added to the chain for its body's recursion so
        # constants nested two levels deep qualify correctly.
        def walk_declarations(node, namespace:, &)
          return unless node.is_a?(Prism::Node)

          if node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)
            yield node, namespace
            inner_namespace = namespace + namespace_segments_for(node)
            return if node.body.nil?

            walk_declarations(node.body, namespace: inner_namespace, &)
          else
            node.compact_child_nodes.each do |child|
              walk_declarations(child, namespace: namespace, &)
            end
          end
        end

        # The segments contributed by a declaration to the
        # qualifier chain of its body. For `class A::B` this is
        # `["A", "B"]`; for `module Outer` it is `["Outer"]`.
        # Returns `[]` for an anonymous declaration the walker
        # cannot qualify.
        def namespace_segments_for(declaration_node)
          path = qualified_name_for(declaration_node.constant_path)
          path ? path.split("::") : []
        end

        def build_entry(declaration_node, enclosing)
          name = qualified_name_with_enclosing(declaration_node.constant_path, enclosing)
          parent_name = parent_name_for(declaration_node)
          methods = collect_def_names(declaration_node.body)
          includes = collect_include_targets(declaration_node.body)
          ControllerIndex::Entry.new(
            class_name: name,
            defined_methods: methods.freeze,
            parent_class_name: parent_name,
            included_module_names: includes.freeze,
            enclosing_namespace: enclosing.dup.freeze
          )
        end

        # Resolves the declared name against the enclosing
        # namespace chain. A `ConstantPathNode` (e.g.
        # `Admin::Foo` in `class Admin::Foo`) is already
        # absolute and ignores the enclosing chain. A
        # `ConstantReadNode` (bare `Foo` in `module Admin;
        # class Foo`) is qualified against the chain so the
        # name becomes `Admin::Foo`.
        def qualified_name_with_enclosing(node, enclosing)
          return nil unless node.is_a?(Prism::Node)

          local = qualified_name_for(node)
          return nil if local.nil?
          return local if node.is_a?(Prism::ConstantPathNode) && !node.parent.nil?
          return local if enclosing.empty?

          "#{enclosing.join('::')}::#{local}"
        end

        def parent_name_for(declaration_node)
          return nil unless declaration_node.is_a?(Prism::ClassNode) && declaration_node.superclass

          qualified_name_for(declaration_node.superclass)
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
