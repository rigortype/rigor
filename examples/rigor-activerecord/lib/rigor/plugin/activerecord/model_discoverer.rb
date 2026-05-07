# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class Activerecord < Rigor::Plugin::Base
      # Walks the configured model search paths via the plugin's
      # `IoBoundary`, parses each `.rb` file with Prism, and
      # collects class declarations whose immediate superclass is
      # one of the configured base classes.
      #
      # Returns rows the {ModelIndex} consumes:
      #
      #   { class_name: "User", table_name_override: nil }
      #   { class_name: "ApplicationRecord", table_name_override: "people" }
      #
      # Limitations (intentional for v0.1.0 of the plugin):
      #
      # - Only direct-superclass matches. `class Admin < User`
      #   where `User < ApplicationRecord` is NOT discovered.
      #   Add `Admin` to the index by listing every concrete model
      #   you want recognised, or add `User` to
      #   `model_base_classes` config.
      # - `self.table_name = "..."` recognised only when the RHS
      #   is a String literal. Computed names
      #   (`self.table_name = "#{tenant}_users"`) are skipped.
      # - Modules (`class Admin::User < ApplicationRecord`) are
      #   recognised; the resulting class name is the lexical
      #   path (`Admin::User`).
      class ModelDiscoverer
        # @param io_boundary [Rigor::Plugin::IoBoundary]
        # @param search_paths [Array<String>] absolute or
        #   project-relative paths.
        # @param base_classes [Array<String>] superclass names that
        #   identify a class as an AR model.
        def initialize(io_boundary:, search_paths:, base_classes:)
          @io_boundary = io_boundary
          @search_paths = search_paths
          @base_classes = base_classes.to_set
        end

        # @return [Array<Hash>] rows of { class_name:, table_name_override: }
        def discover
          rows = []
          ruby_files_under(@search_paths).each do |path|
            contents = read_safely(path)
            next if contents.nil?

            tree = Prism.parse(contents).value
            walk_for_classes(tree, []) do |class_name, table_override|
              rows << { class_name: class_name, table_name_override: table_override }
            end
          end
          rows
        end

        private

        def read_safely(path)
          @io_boundary.read_file(path)
        rescue Plugin::AccessDeniedError, Errno::ENOENT
          nil
        end

        def ruby_files_under(roots)
          roots.flat_map do |root|
            absolute = File.expand_path(root)
            next [] unless File.directory?(absolute)

            Dir.glob(File.join(absolute, "**", "*.rb"))
          end
        end

        def walk_for_classes(node, lexical_path, &)
          return if node.nil?

          case node
          when Prism::ClassNode
            visit_class(node, lexical_path, &)
          when Prism::ModuleNode
            visit_module(node, lexical_path, &)
          else
            node.compact_child_nodes.each { |child| walk_for_classes(child, lexical_path, &) }
          end
        end

        def visit_class(node, lexical_path, &)
          class_local_name = constant_path_name(node.constant_path)
          return if class_local_name.nil?

          full_name = (lexical_path + [class_local_name]).join("::")
          superclass = constant_path_name(node.superclass) if node.superclass

          if superclass && @base_classes.include?(superclass)
            table_override = lookup_table_name_override(node.body)
            yield full_name, table_override
          end

          # Recurse into the body in case nested classes exist.
          inner_path = lexical_path + [class_local_name]
          walk_for_classes(node.body, inner_path, &) if node.body
        end

        def visit_module(node, lexical_path, &)
          module_local_name = constant_path_name(node.constant_path)
          return if module_local_name.nil?

          inner_path = lexical_path + [module_local_name]
          walk_for_classes(node.body, inner_path, &) if node.body
        end

        # Renders a constant-path node (`Admin::User`,
        # `::ApplicationRecord`) as a String. Returns nil for
        # shapes the discoverer chooses not to handle.
        def constant_path_name(node)
          return nil if node.nil?

          case node
          when Prism::ConstantReadNode
            node.name.to_s
          when Prism::ConstantPathNode
            parts = []
            current = node
            while current.is_a?(Prism::ConstantPathNode)
              parts.unshift(current.name.to_s)
              current = current.parent
            end
            case current
            when nil
              "::#{parts.join('::')}"
            when Prism::ConstantReadNode
              "#{current.name}::#{parts.join('::')}"
            end
          end
        end

        # Looks for `self.table_name = "..."` at the top level of
        # the class body. Returns the literal String when found,
        # nil otherwise.
        def lookup_table_name_override(body)
          return nil if body.nil?

          body.compact_child_nodes.each do |node|
            next unless node.is_a?(Prism::CallNode) && node.name == :table_name=
            next unless node.receiver.is_a?(Prism::SelfNode)

            arg = node.arguments&.arguments&.first
            return arg.unescaped if arg.is_a?(Prism::StringNode)
          end
          nil
        end
      end
    end
  end
end
