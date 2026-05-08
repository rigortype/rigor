# frozen_string_literal: true

require "prism"

require_relative "mailer_index"

module Rigor
  module Plugin
    class Actionmailer < Rigor::Plugin::Base
      # Walks the configured mailer-search paths via the
      # plugin's `IoBoundary`, parses each `.rb` file with
      # Prism, and collects classes whose immediate superclass
      # is one of the configured base classes.
      #
      # For each discovered class, the discoverer:
      #
      # - Reads the instance-side `def` nodes and records each
      #   one as an action method, capturing the arity envelope.
      # - For each (class, action) pair, attempts to read every
      #   candidate view template under
      #   `app/views/<mailer_underscore>/<action>.{html,text}.erb`.
      #   Existing templates feed the IoBoundary's cache
      #   descriptor (so the cache invalidates when the
      #   template changes); missing templates are recorded so
      #   the plugin can surface a diagnostic on the mailer
      #   class definition.
      #
      # Limitations (intentional for v0.1.0):
      #
      # - Direct-superclass match only. `class CustomerMailer
      #   < BaseMailer` where `BaseMailer < ApplicationMailer`
      #   is NOT discovered. Add `BaseMailer` to
      #   `mailer_base_classes` if needed.
      # - Action methods are read from the syntactic instance-
      #   side `def` list. Methods built via `define_method`,
      #   `private`, or non-action helpers (e.g. methods
      #   starting with `_`) are out of scope. The discoverer
      #   filters obvious non-actions (`initialize`, names
      #   prefixed with `_`).
      # - Adding a brand-new view file under
      #   `app/views/<mailer>/` will NOT invalidate the
      #   cached index until something the mailer file
      #   touches changes. This is the standard read-tracking
      #   trade-off — only files we successfully read get
      #   digested into the descriptor.
      class MailerDiscoverer
        DEFAULT_VIEWS_ROOT = "app/views"
        VIEW_FORMATS = %w[html text].freeze
        VIEW_EXTENSIONS = %w[erb haml slim].freeze

        # @param io_boundary [Rigor::Plugin::IoBoundary]
        # @param search_paths [Array<String>] absolute or
        #   project-relative paths to scan for mailers.
        # @param base_classes [Array<String>] direct
        #   superclasses that mark a class as a mailer.
        # @param views_root [String] absolute or project-
        #   relative path to the views directory (typically
        #   `app/views`).
        def initialize(io_boundary:, search_paths:, base_classes:, views_root: DEFAULT_VIEWS_ROOT)
          @io_boundary = io_boundary
          @search_paths = search_paths
          @base_classes = base_classes.to_set
          @views_root = views_root
        end

        # @return [MailerIndex]
        def discover
          entries = []
          ruby_files_under(@search_paths).each do |path|
            contents = read_safely(path)
            next if contents.nil?

            tree = Prism.parse(contents).value
            walk_for_mailers(tree, []) do |class_name, def_nodes|
              entries << build_class_entry(class_name, path, def_nodes)
            end
          end
          MailerIndex.new(entries)
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

        def walk_for_mailers(node, lexical_path, &)
          return if node.nil?

          case node
          when Prism::ClassNode then visit_class(node, lexical_path, &)
          when Prism::ModuleNode then visit_module(node, lexical_path, &)
          else
            node.compact_child_nodes.each { |child| walk_for_mailers(child, lexical_path, &) }
          end
        end

        def visit_class(node, lexical_path, &)
          class_local_name = constant_path_name(node.constant_path)
          return if class_local_name.nil?

          full_name = (lexical_path + [class_local_name]).join("::")
          superclass = constant_path_name(node.superclass) if node.superclass
          if superclass && @base_classes.include?(superclass)
            def_nodes = collect_action_defs(node.body)
            yield full_name, def_nodes
          end

          inner_path = lexical_path + [class_local_name]
          walk_for_mailers(node.body, inner_path, &) if node.body
        end

        def visit_module(node, lexical_path, &)
          module_local_name = constant_path_name(node.constant_path)
          return if module_local_name.nil?

          inner_path = lexical_path + [module_local_name]
          walk_for_mailers(node.body, inner_path, &) if node.body
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

        # Returns the instance-side `def` nodes that look like
        # mailer actions. Filters obvious non-actions:
        # `initialize`, methods starting with `_`, and any
        # `def self.<name>` (singleton-side).
        def collect_action_defs(body)
          return [] if body.nil?

          body.compact_child_nodes.flat_map do |node|
            next [] unless node.is_a?(Prism::DefNode)
            next [] if node.receiver.is_a?(Prism::SelfNode)
            next [] if node.name == :initialize
            next [] if node.name.to_s.start_with?("_")

            [node]
          end
        end

        def build_class_entry(class_name, file_path, def_nodes)
          actions = def_nodes.to_h do |def_node|
            entry = build_action_entry(def_node)
            [entry.method_name, entry]
          end

          missing_views = actions.keys.reject { |action| view_exists?(class_name, action) }

          MailerIndex::ClassEntry.new(
            class_name: class_name,
            file_path: file_path,
            actions: actions,
            missing_views: missing_views
          )
        end

        def build_action_entry(def_node)
          parameters = def_node.parameters
          location = def_node.name_loc

          if parameters.nil?
            return MailerIndex::ActionEntry.new(
              method_name: def_node.name,
              min_arity: 0, max_arity: 0,
              def_line: location.start_line,
              def_column: location.start_column + 1
            )
          end

          required_count = (parameters.requireds || []).size
          optional_count = (parameters.optionals || []).size
          rest_present = !parameters.rest.nil?

          MailerIndex::ActionEntry.new(
            method_name: def_node.name,
            min_arity: required_count,
            max_arity: rest_present ? Float::INFINITY : required_count + optional_count,
            def_line: location.start_line,
            def_column: location.start_column + 1
          )
        end

        # Checks whether *any* template under
        # `app/views/<underscore>/<action>.{html,text}.{erb,haml,slim}`
        # exists, by attempting to read each candidate via the
        # IoBoundary. Successful reads are recorded by the
        # boundary; failed reads (missing file or access
        # denied) are swallowed.
        def view_exists?(class_name, action_name)
          views_root_absolute = File.expand_path(@views_root)
          underscore_path = underscore(class_name.delete_prefix("::"))
          mailer_dir = File.join(views_root_absolute, underscore_path)

          VIEW_FORMATS.any? do |format|
            VIEW_EXTENSIONS.any? do |ext|
              candidate = File.join(mailer_dir, "#{action_name}.#{format}.#{ext}")
              read_safely(candidate)
            end
          end
        end

        # Convert `Foo::BarMailer` → `foo/bar_mailer`. Mirrors
        # ActiveSupport's String#underscore for ASCII-only
        # constant names; we don't try to be inflector-perfect
        # here.
        def underscore(name)
          name.gsub("::", "/")
              .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
              .gsub(/([a-z\d])([A-Z])/, '\1_\2')
              .downcase
        end
      end
    end
  end
end
