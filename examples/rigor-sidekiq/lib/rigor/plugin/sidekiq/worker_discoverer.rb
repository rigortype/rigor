# frozen_string_literal: true

require "prism"

require_relative "worker_index"

module Rigor
  module Plugin
    class Sidekiq < Rigor::Plugin::Base
      # Walks the configured worker-search paths via the
      # plugin's `IoBoundary`, parses each `.rb` file with
      # Prism, and collects classes that `include
      # Sidekiq::Job` (or one of the configured marker
      # modules). For each discovered class, the discoverer
      # also reads the `#perform` method's parameter list
      # and computes the arity envelope.
      #
      # Limitations (intentional for v0.1.0):
      #
      # - Only direct `include` matches against the
      #   configured marker modules. `class MyWorker;
      #   include Concerns::Sidekiqable; end` where
      #   `Concerns::Sidekiqable` re-includes `Sidekiq::Job`
      #   is NOT discovered. Add the intermediate module to
      #   `worker_marker_modules` if needed.
      # - The qualified class name is the lexical path
      #   (`Admin::WelcomeWorker` for a class declared
      #   inside `module Admin`).
      # - `#perform` arity is read from the syntactic
      #   parameter list. Methods built via
      #   `define_method` are out of scope.
      class WorkerDiscoverer
        def initialize(io_boundary:, search_paths:, marker_modules:)
          @io_boundary = io_boundary
          @search_paths = search_paths
          @marker_modules = marker_modules.to_set
        end

        # @return [WorkerIndex]
        def discover
          entries = []
          ruby_files_under(@search_paths).each do |path|
            contents = read_safely(path)
            next if contents.nil?

            tree = Prism.parse(contents).value
            walk_for_workers(tree, []) do |class_name, perform_def|
              entries << build_entry(class_name, perform_def)
            end
          end
          WorkerIndex.new(entries)
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

        def walk_for_workers(node, lexical_path, &)
          return if node.nil?

          case node
          when Prism::ClassNode then visit_class(node, lexical_path, &)
          when Prism::ModuleNode then visit_module(node, lexical_path, &)
          else
            node.compact_child_nodes.each { |child| walk_for_workers(child, lexical_path, &) }
          end
        end

        def visit_class(node, lexical_path, &)
          class_local_name = constant_path_name(node.constant_path)
          return if class_local_name.nil?

          full_name = (lexical_path + [class_local_name]).join("::")
          if includes_marker_module?(node.body)
            perform_def = lookup_perform_def(node.body)
            yield full_name, perform_def
          end

          inner_path = lexical_path + [class_local_name]
          walk_for_workers(node.body, inner_path, &) if node.body
        end

        def visit_module(node, lexical_path, &)
          module_local_name = constant_path_name(node.constant_path)
          return if module_local_name.nil?

          inner_path = lexical_path + [module_local_name]
          walk_for_workers(node.body, inner_path, &) if node.body
        end

        # Returns true if the class body contains a top-level
        # `include <Module>` call where `<Module>` matches
        # one of the configured marker modules.
        def includes_marker_module?(body)
          return false if body.nil?

          body.compact_child_nodes.any? do |node|
            next false unless node.is_a?(Prism::CallNode)
            next false unless node.name == :include
            next false unless node.receiver.nil?

            arg = node.arguments&.arguments&.first
            module_name = constant_path_name(arg)
            module_name && @marker_modules.include?(module_name)
          end
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

        # Returns the instance-side `def perform(...)` node
        # from a class body, or `nil` when the class doesn't
        # override `#perform`.
        def lookup_perform_def(body)
          return nil if body.nil?

          body.compact_child_nodes.each do |node|
            next unless node.is_a?(Prism::DefNode) && node.name == :perform
            next if node.receiver.is_a?(Prism::SelfNode)

            return node
          end
          nil
        end

        # Builds a `WorkerIndex::Entry` from the discovered
        # class's `#perform` def. When the class doesn't
        # override `#perform`, we record an "any-arity"
        # entry — Sidekiq itself doesn't supply a default
        # `#perform`, so calling `perform_async` on a
        # worker without one is the user's bug, not the
        # plugin's call to flag without runtime context.
        def build_entry(class_name, perform_def)
          if perform_def.nil?
            return WorkerIndex::Entry.new(
              class_name: class_name, min_arity: 0,
              max_arity: Float::INFINITY
            )
          end

          parameters = perform_def.parameters
          if parameters.nil?
            return WorkerIndex::Entry.new(
              class_name: class_name, min_arity: 0, max_arity: 0
            )
          end

          required_count = (parameters.requireds || []).size
          optional_count = (parameters.optionals || []).size
          rest_present = !parameters.rest.nil?

          WorkerIndex::Entry.new(
            class_name: class_name,
            min_arity: required_count,
            max_arity: rest_present ? Float::INFINITY : required_count + optional_count
          )
        end
      end
    end
  end
end
