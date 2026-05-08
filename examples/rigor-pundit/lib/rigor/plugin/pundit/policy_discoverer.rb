# frozen_string_literal: true

require "prism"

require_relative "policy_index"

module Rigor
  module Plugin
    class Pundit < Rigor::Plugin::Base
      # Walks the configured policy-search paths via the
      # plugin's `IoBoundary`, parses each `.rb` file with
      # Prism, and collects classes whose immediate
      # superclass is one of the configured base classes.
      #
      # For each discovered policy class, the discoverer
      # collects every instance-side `def name?` predicate
      # method. Non-predicate methods (`initialize`,
      # `resolve`, helper methods) are ignored — Pundit's
      # `authorize` only ever calls predicate methods.
      #
      # Limitations (intentional for v0.1.0):
      #
      # - Direct-superclass match only.
      # - Predicate methods are read from the syntactic
      #   `def` list. Methods built via `define_method` /
      #   inherited from a sibling concern are out of scope.
      class PolicyDiscoverer
        def initialize(io_boundary:, search_paths:, base_classes:)
          @io_boundary = io_boundary
          @search_paths = search_paths
          @base_classes = base_classes.to_set
        end

        # @return [PolicyIndex]
        def discover
          entries = []
          ruby_files_under(@search_paths).each do |path|
            contents = read_safely(path)
            next if contents.nil?

            tree = Prism.parse(contents).value
            walk_for_policies(tree, []) do |class_name, predicates|
              entries << PolicyIndex::Entry.new(
                policy_class_name: class_name,
                file_path: path,
                predicate_methods: predicates.to_set.freeze
              )
            end
          end
          PolicyIndex.new(entries)
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

        def walk_for_policies(node, lexical_path, &)
          return if node.nil?

          case node
          when Prism::ClassNode then visit_class(node, lexical_path, &)
          when Prism::ModuleNode then visit_module(node, lexical_path, &)
          else
            node.compact_child_nodes.each { |child| walk_for_policies(child, lexical_path, &) }
          end
        end

        def visit_class(node, lexical_path, &)
          class_local_name = constant_path_name(node.constant_path)
          return if class_local_name.nil?

          full_name = (lexical_path + [class_local_name]).join("::")
          superclass = constant_path_name(node.superclass) if node.superclass
          if superclass && @base_classes.include?(superclass) && full_name.end_with?("Policy")
            predicates = collect_predicate_methods(node.body)
            yield full_name, predicates
          end

          inner_path = lexical_path + [class_local_name]
          walk_for_policies(node.body, inner_path, &) if node.body
        end

        def visit_module(node, lexical_path, &)
          module_local_name = constant_path_name(node.constant_path)
          return if module_local_name.nil?

          inner_path = lexical_path + [module_local_name]
          walk_for_policies(node.body, inner_path, &) if node.body
        end

        def constant_path_name(node)
          return nil if node.nil?

          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode
            parts = []
            current = node
            while current.is_a?(Prism::ConstantPathNode)
              parts.unshift(current.name.to_s)
              current = current.parent
            end
            case current
            when nil then "::#{parts.join('::')}"
            when Prism::ConstantReadNode then "#{current.name}::#{parts.join('::')}"
            end
          end
        end

        # Returns symbolic predicate names (`:update?`,
        # `:show?`, …) defined on the policy. Only
        # instance-side names that end in `?` are recorded.
        def collect_predicate_methods(body)
          return [] if body.nil?

          body.compact_child_nodes.flat_map do |node|
            next [] unless node.is_a?(Prism::DefNode)
            next [] if node.receiver.is_a?(Prism::SelfNode)
            next [] unless node.name.to_s.end_with?("?")

            [node.name]
          end
        end
      end
    end
  end
end
