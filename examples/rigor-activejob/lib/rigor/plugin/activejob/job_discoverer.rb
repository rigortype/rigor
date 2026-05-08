# frozen_string_literal: true

require "prism"

require_relative "job_index"

module Rigor
  module Plugin
    class Activejob < Rigor::Plugin::Base
      # Walks the configured job-search paths via the plugin's
      # `IoBoundary`, parses each `.rb` file with Prism, and
      # collects classes whose immediate superclass is one of
      # the configured base classes. For each discovered class,
      # the discoverer also reads the `#perform` method's
      # parameter list and computes the arity envelope.
      #
      # Limitations (intentional for v0.1.0):
      #
      # - Only direct-superclass matches. `class WelcomeJob <
      #   BaseJob` where `BaseJob < ApplicationJob` is NOT
      #   discovered. List `BaseJob` in `job_base_classes`
      #   if needed.
      # - The qualified class name is the lexical path
      #   (`Admin::WelcomeJob` for a class declared inside
      #   `module Admin`).
      # - The `#perform` arity is read from the syntactic
      #   parameter list. Methods built via `define_method`
      #   are out of scope.
      class JobDiscoverer
        def initialize(io_boundary:, search_paths:, base_classes:)
          @io_boundary = io_boundary
          @search_paths = search_paths
          @base_classes = base_classes.to_set
        end

        # @return [JobIndex]
        def discover
          entries = []
          ruby_files_under(@search_paths).each do |path|
            contents = read_safely(path)
            next if contents.nil?

            tree = Prism.parse(contents).value
            walk_for_jobs(tree, []) do |class_name, perform_def|
              entries << build_entry(class_name, perform_def)
            end
          end
          JobIndex.new(entries)
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

        def walk_for_jobs(node, lexical_path, &)
          return if node.nil?

          case node
          when Prism::ClassNode then visit_class(node, lexical_path, &)
          when Prism::ModuleNode then visit_module(node, lexical_path, &)
          else
            node.compact_child_nodes.each { |child| walk_for_jobs(child, lexical_path, &) }
          end
        end

        def visit_class(node, lexical_path, &)
          class_local_name = constant_path_name(node.constant_path)
          return if class_local_name.nil?

          full_name = (lexical_path + [class_local_name]).join("::")
          superclass = constant_path_name(node.superclass) if node.superclass
          if superclass && @base_classes.include?(superclass)
            perform_def = lookup_perform_def(node.body)
            yield full_name, perform_def
          end

          inner_path = lexical_path + [class_local_name]
          walk_for_jobs(node.body, inner_path, &) if node.body
        end

        def visit_module(node, lexical_path, &)
          module_local_name = constant_path_name(node.constant_path)
          return if module_local_name.nil?

          inner_path = lexical_path + [module_local_name]
          walk_for_jobs(node.body, inner_path, &) if node.body
        end

        # Renders `Foo::Bar` / `::Foo::Bar` as a String.
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

        # Returns the `def perform(...)` node from a class
        # body, or `nil` when the class doesn't override
        # `#perform`. Only matches instance-side `def perform`.
        def lookup_perform_def(body)
          return nil if body.nil?

          body.compact_child_nodes.each do |node|
            next unless node.is_a?(Prism::DefNode) && node.name == :perform
            next if node.receiver.is_a?(Prism::SelfNode)

            return node
          end
          nil
        end

        # Builds a JobIndex::Entry from the discovered class's
        # `#perform` def. When the class doesn't override
        # `#perform`, we record an "any-arity" entry — Active
        # Job's default `#perform` is abstract; calling
        # `perform_later` on a job that didn't override it is
        # itself a bug, but it's the user's bug, not the
        # plugin's call to flag without runtime context.
        def build_entry(class_name, perform_def)
          if perform_def.nil?
            return JobIndex::Entry.new(
              class_name: class_name, min_arity: 0,
              max_arity: Float::INFINITY, keyword_required: []
            )
          end

          parameters = perform_def.parameters
          if parameters.nil?
            return JobIndex::Entry.new(
              class_name: class_name, min_arity: 0,
              max_arity: 0, keyword_required: []
            )
          end

          required_count = (parameters.requireds || []).size
          optional_count = (parameters.optionals || []).size
          rest_present = !parameters.rest.nil?
          keyword_required = (parameters.keywords || []).filter_map do |kw|
            kw.name if kw.is_a?(Prism::RequiredKeywordParameterNode)
          end

          JobIndex::Entry.new(
            class_name: class_name,
            min_arity: required_count,
            max_arity: rest_present ? Float::INFINITY : required_count + optional_count,
            keyword_required: keyword_required.map(&:to_sym)
          )
        end
      end
    end
  end
end
