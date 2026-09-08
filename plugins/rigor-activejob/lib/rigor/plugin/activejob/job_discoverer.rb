# frozen_string_literal: true

require "rigor/source/node_children"

require "prism"

require_relative "job_index"

module Rigor
  module Plugin
    class Activejob < Rigor::Plugin::Base
      # Walks the configured job-search paths via the plugin's `IoBoundary`, parses each `.rb` file with
      # Prism, and collects classes whose immediate superclass is one of the configured base classes.
      # For each discovered class, the discoverer also reads the `#perform` method's parameter list and
      # computes the arity envelope.
      #
      # Limitations (intentional for v0.1.0):
      #
      # - Only direct-superclass matches. `class WelcomeJob < BaseJob` where `BaseJob < ApplicationJob`
      #   is NOT discovered. List `BaseJob` in `job_base_classes` if needed.
      # - The qualified class name is the lexical path (`Admin::WelcomeJob` for a class declared inside
      #   `module Admin`).
      # - The `#perform` arity is read from the syntactic parameter list. Methods built via
      #   `define_method` are out of scope.
      class JobDiscoverer
        def initialize(io_boundary:, search_paths:, base_classes:)
          @io_boundary = io_boundary
          @search_paths = search_paths
          # De-rooted for the same reason superclass names are ({#visit_class}): the match is by exact
          # spelling, so a configured `job_base_classes: ["::ApplicationJob"]` would otherwise never match
          # anything a declaration can render.
          @base_classes = base_classes.to_set { |name| strip_root(name.to_s) }
        end

        def discover
          candidates = []
          ruby_files_under(@search_paths).each do |path|
            contents = read_safely(path)
            next if contents.nil?

            tree = Prism.parse(contents).value
            walk_for_jobs(tree, []) do |class_name, perform_def|
              candidates << [class_name, perform_def]
            end
          end
          JobIndex.new(merge_redeclarations(candidates))
        end

        private

        # Collapses the candidates that declare the SAME constant into one entry, so {JobIndex} — which
        # keys its rows by `class_name` — receives at most one per job.
        #
        # A job is routinely declared more than once: `app/jobs/welcome_job.rb` holds the real class and a
        # second file reopens it (`class ::WelcomeJob`, `class WelcomeJob`) to add a method. Taking the last
        # candidate dropped the real `#perform` envelope whenever the reopen sorted later in the glob — the
        # reopen carries no `#perform`, so the job silently became any-arity and every `perform_later` went
        # unchecked. The rows are merged instead:
        #
        # - The declarations that actually spell `def perform` decide the envelope; a reopen that does not
        #   contributes nothing rather than erasing it.
        # - When two declarations BOTH spell it with different shapes, the envelope WIDENS (min of the mins,
        #   max of the maxes) and the required keywords intersect. The glob order is not the load order, so
        #   pinning either shape would surface `wrong-arity` on a call the definition Ruby actually loads
        #   accepts — ADR-5: a missed narrow case costs precision, a wrong one costs correct code.
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
            max_arity: [base.max_arity, addition.max_arity].max,
            keyword_required: base.keyword_required & addition.keyword_required
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

        def walk_for_jobs(node, lexical_path, &)
          return if node.nil?

          case node
          when Prism::ClassNode then visit_class(node, lexical_path, &)
          when Prism::ModuleNode then visit_module(node, lexical_path, &)
          else
            node.rigor_each_child { |child| walk_for_jobs(child, lexical_path, &) }
          end
        end

        def visit_class(node, lexical_path, &)
          class_local_name = constant_path_name(node.constant_path)
          return if class_local_name.nil?

          full_name = declared_constant_name(class_local_name, lexical_path)
          superclass = strip_root(constant_path_name(node.superclass)) if node.superclass
          if superclass && @base_classes.include?(superclass)
            perform_def = lookup_perform_def(node.body)
            yield full_name, perform_def
          end

          walk_for_jobs(node.body, [full_name], &) if node.body
        end

        def visit_module(node, lexical_path, &)
          module_local_name = constant_path_name(node.constant_path)
          return if module_local_name.nil?

          inner_path = [declared_constant_name(module_local_name, lexical_path)]
          walk_for_jobs(node.body, inner_path, &) if node.body
        end

        # The full constant name a `class` / `module` declaration defines, given the rendered local name
        # and the enclosing lexical path. A ROOTED local name (`class ::WelcomeJob`) names the top-level
        # constant whatever the nesting, so the lexical path is dropped and the `::` with it; otherwise the
        # name is appended to the path (`class WelcomeJob` inside `module Admin` → `Admin::WelcomeJob`).
        def declared_constant_name(local_name, lexical_path)
          return strip_root(local_name) if local_name.start_with?("::")

          (lexical_path + [local_name]).join("::")
        end

        # `::WelcomeJob` → `WelcomeJob`; a name without the root marker is returned unchanged (nil stays nil).
        def strip_root(name)
          name&.delete_prefix("::")
        end

        # Renders `Foo::Bar` / `::Foo::Bar` as a String, KEEPING the leading `::` of a rooted path —
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

        # Returns the `def perform(...)` node from a class body, or `nil` when the class doesn't
        # override `#perform`. Only matches instance-side `def perform`.
        def lookup_perform_def(body)
          return nil if body.nil?

          body.rigor_each_child do |node|
            next unless node.is_a?(Prism::DefNode) && node.name == :perform
            next if node.receiver.is_a?(Prism::SelfNode)

            return node
          end
          nil
        end

        # Builds a JobIndex::Entry from the discovered class's `#perform` def. When the class doesn't
        # override `#perform`, we record an "any-arity" entry — Active Job's default `#perform` is
        # abstract; calling `perform_later` on a job that didn't override it is itself a bug, but it's
        # the user's bug, not the plugin's call to flag without runtime context.
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
