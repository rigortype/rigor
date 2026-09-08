# frozen_string_literal: true

require "rigor/source/node_children"

require "prism"

require_relative "worker_index"

module Rigor
  module Plugin
    class Sidekiq < Rigor::Plugin::Base
      # Walks the configured worker-search paths via the plugin's `IoBoundary`, parses each `.rb` file with
      # Prism, and collects classes that `include Sidekiq::Job` (or one of the configured marker modules).
      # For each discovered class, the discoverer also reads the `#perform` method's parameter list and
      # computes the arity envelope.
      #
      # Limitations (intentional for v0.1.0):
      #
      # - Only direct `include` matches against the configured marker modules. `class MyWorker; include
      #   Concerns::Sidekiqable; end` where `Concerns::Sidekiqable` re-includes `Sidekiq::Job` is NOT
      #   discovered. Add the intermediate module to `worker_marker_modules` if needed.
      # - The qualified class name is the lexical path (`Admin::WelcomeWorker` for a class declared inside
      #   `module Admin`).
      # - `#perform` arity is read from the syntactic parameter list. Methods built via `define_method`
      #   are out of scope.
      class WorkerDiscoverer
        def initialize(io_boundary:, search_paths:, marker_modules:)
          @io_boundary = io_boundary
          @search_paths = search_paths
          # De-rooted so the marker match is by exact spelling on both sides: a worker written
          # `include ::Sidekiq::Job` — and a configured `worker_marker_modules: ["::Sidekiq::Job"]` —
          # would otherwise never match anything the other side can render.
          @marker_modules = marker_modules.to_set { |name| strip_root(name.to_s) }
        end

        def discover
          candidates = []
          ruby_files_under(@search_paths).each do |path|
            contents = read_safely(path)
            next if contents.nil?

            tree = Prism.parse(contents).value
            walk_for_workers(tree, []) do |class_name, perform_def|
              candidates << [class_name, perform_def]
            end
          end
          WorkerIndex.new(merge_redeclarations(candidates))
        end

        private

        # Collapses the candidates that declare the SAME constant into one entry, so {WorkerIndex} — which
        # keys its rows by `class_name` — receives at most one per worker.
        #
        # A worker is routinely declared more than once: the real class in `app/workers/welcome_worker.rb`
        # and a second file reopening it (`class ::WelcomeWorker`, `class WelcomeWorker`) to add a method.
        # Taking the last candidate dropped the real `#perform` envelope whenever the reopen sorted later in
        # the glob — the reopen carries no `#perform`, so the worker silently became any-arity and every
        # `perform_async` went unchecked. The rows are merged instead:
        #
        # - The declarations that actually spell `def perform` decide the envelope; a reopen that does not
        #   contributes nothing rather than erasing it.
        # - When two declarations BOTH spell it with different shapes, the envelope WIDENS (min of the mins,
        #   max of the maxes). The glob order is not the load order, so pinning either shape would surface
        #   `wrong-arity` on a call the definition Ruby actually loads accepts — ADR-5: a missed narrow case
        #   costs precision, a wrong one costs correct code.
        def merge_redeclarations(candidates)
          candidates.group_by(&:first).map do |class_name, rows|
            declared = rows.filter_map { |(_, perform_def)| perform_def }
            entries = declared.empty? ? [build_entry(class_name, nil)] : declared.map { |d| build_entry(class_name, d) }
            entries.reduce { |base, addition| widen(base, addition) }
          end
        end

        # The arity envelope that accepts every call either declaration accepts. See {#merge_redeclarations}.
        def widen(base, addition)
          base.with(
            min_arity: [base.min_arity, addition.min_arity].min,
            max_arity: [base.max_arity, addition.max_arity].max
          )
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

        def walk_for_workers(node, lexical_path, &)
          return if node.nil?

          case node
          when Prism::ClassNode then visit_class(node, lexical_path, &)
          when Prism::ModuleNode then visit_module(node, lexical_path, &)
          else
            node.rigor_each_child { |child| walk_for_workers(child, lexical_path, &) }
          end
        end

        def visit_class(node, lexical_path, &)
          class_local_name = constant_path_name(node.constant_path)
          return if class_local_name.nil?

          full_name = declared_constant_name(class_local_name, lexical_path)
          if includes_marker_module?(node.body)
            perform_def = lookup_perform_def(node.body)
            yield full_name, perform_def
          end

          walk_for_workers(node.body, [full_name], &) if node.body
        end

        def visit_module(node, lexical_path, &)
          module_local_name = constant_path_name(node.constant_path)
          return if module_local_name.nil?

          inner_path = [declared_constant_name(module_local_name, lexical_path)]
          walk_for_workers(node.body, inner_path, &) if node.body
        end

        # The full constant name a `class` / `module` declaration defines, given the rendered local name
        # and the enclosing lexical path. A ROOTED local name (`class ::WelcomeWorker`) names the top-level
        # constant whatever the nesting, so the lexical path is dropped and the `::` with it; otherwise the
        # name is appended to the path (`class WelcomeWorker` inside `module Admin` →
        # `Admin::WelcomeWorker`).
        def declared_constant_name(local_name, lexical_path)
          return strip_root(local_name) if local_name.start_with?("::")

          (lexical_path + [local_name]).join("::")
        end

        # `::WelcomeWorker` → `WelcomeWorker`; a name without the root marker is returned unchanged (nil
        # stays nil).
        def strip_root(name)
          name&.delete_prefix("::")
        end

        # Returns true if the class body contains a top-level `include <Module>` call where `<Module>`
        # matches one of the configured marker modules.
        def includes_marker_module?(body)
          return false if body.nil?

          body.compact_child_nodes.any? do |node|
            next false unless node.is_a?(Prism::CallNode)
            next false unless node.name == :include
            next false unless node.receiver.nil?

            arg = node.arguments&.arguments&.first
            module_name = strip_root(constant_path_name(arg))
            module_name && @marker_modules.include?(module_name)
          end
        end

        # Renders a constant-path node as a String, KEEPING the leading `::` of a rooted path —
        # {#declared_constant_name} reads it as "reset the lexical path" before the marker is dropped.
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

        # Returns the instance-side `def perform(...)` node from a class body, or `nil` when the class
        # doesn't override `#perform`.
        def lookup_perform_def(body)
          return nil if body.nil?

          body.rigor_each_child do |node|
            next unless node.is_a?(Prism::DefNode) && node.name == :perform
            next if node.receiver.is_a?(Prism::SelfNode)

            return node
          end
          nil
        end

        # Builds a `WorkerIndex::Entry` from the discovered class's `#perform` def. When the class doesn't
        # override `#perform`, we record an "any-arity" entry — Sidekiq itself doesn't supply a default
        # `#perform`, so calling `perform_async` on a worker without one is the user's bug, not the
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
