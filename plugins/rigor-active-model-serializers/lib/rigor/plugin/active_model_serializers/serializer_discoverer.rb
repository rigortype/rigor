# frozen_string_literal: true

require "rigor/source/node_children"

require "prism"

require_relative "serializer_index"

module Rigor
  module Plugin
    class ActiveModelSerializers < Rigor::Plugin::Base
      # Walks the configured serializer-search paths through the plugin's `IoBoundary`, parses each `.rb`
      # file with Prism, and records every `class X < Y` it finds along with the superclass the source
      # names. The recorded set is then closed transitively from the configured roots, so a project base
      # serializer counts its own subclasses in:
      #
      #     class ApplicationSerializer < ActiveModel::Serializer   # root child
      #     class REST::AccountSerializer < ApplicationSerializer   # reached through it
      #
      # The closure is what a direct-superclass match (the shape `rigor-pundit`'s policy discoverer uses)
      # would miss, and a project base serializer is the common case rather than the exotic one — on
      # Mastodon 60 of the 153 serializers descend through `ActivityPub::Serializer` rather than naming
      # `ActiveModel::Serializer` themselves.
      #
      # Every class in the scanned tree is recorded, not only the ones already known to descend from a
      # root: the file that defines a base serializer may be parsed after the files that inherit from it,
      # so membership cannot be decided during the walk.
      class SerializerDiscoverer
        def initialize(io_boundary:, search_paths:, base_classes:)
          @io_boundary = io_boundary
          @search_paths = search_paths
          @base_classes = base_classes.map { |name| name.to_s.delete_prefix("::") }
        end

        def discover
          candidates = []
          ruby_files_under(@search_paths).each do |path|
            contents = read_safely(path)
            next if contents.nil?

            tree = Prism.parse(contents).value
            walk(tree, []) do |class_name, superclass_name|
              candidates << SerializerIndex::Entry.new(
                class_name: class_name, superclass_name: superclass_name, file_path: path
              )
            end
          end
          SerializerIndex.new(close_over_roots(candidates))
        end

        private

        # Keeps only the classes whose declared-superclass chain reaches one of the roots. Iterating to a
        # fixed point rather than recursing keeps a cyclic `class A < B; class B < A` source — which Ruby
        # rejects but a static parse can still be handed — from recursing forever.
        def close_over_roots(candidates)
          by_name = candidates.to_h { |entry| [entry.class_name, entry] }
          reached = @base_classes.to_set
          loop do
            grown = candidates.select do |entry|
              !reached.include?(entry.class_name) && reached.include?(entry.superclass_name)
            end
            break if grown.empty?

            grown.each { |entry| reached << entry.class_name }
          end
          reached.filter_map { |name| by_name[name] }
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

        def walk(node, lexical_path, &)
          return if node.nil?

          case node
          when Prism::ClassNode then visit_class(node, lexical_path, &)
          when Prism::ModuleNode then visit_module(node, lexical_path, &)
          else
            node.rigor_each_child { |child| walk(child, lexical_path, &) }
          end
        end

        def visit_class(node, lexical_path, &)
          local_name = constant_path_name(node.constant_path)
          return if local_name.nil?

          full_name = qualify(lexical_path, local_name)
          superclass = node.superclass ? constant_path_name(node.superclass) : nil
          yield full_name, superclass.to_s.delete_prefix("::") unless superclass.nil?

          walk(node.body, lexical_path + [local_name], &) if node.body
        end

        def visit_module(node, lexical_path, &)
          local_name = constant_path_name(node.constant_path)
          return if local_name.nil?

          walk(node.body, lexical_path + [local_name], &) if node.body
        end

        # `class REST::AccountSerializer` inside no module is already fully qualified; a class written as
        # `class AccountSerializer` inside `module REST` is not. A name the source rooted explicitly
        # (`class ::AccountSerializer`) keeps neither the root marker nor the lexical prefix.
        def qualify(lexical_path, local_name)
          return local_name.delete_prefix("::") if local_name.start_with?("::")

          (lexical_path + [local_name]).join("::")
        end

        def constant_path_name(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode then constant_path_parts(node)
          end
        end

        def constant_path_parts(node)
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
    end
  end
end
