# frozen_string_literal: true

require "rigor/source/node_children"

require "prism"

require_relative "serializer_index"

module Rigor
  module Plugin
    class ActiveModelSerializers < Rigor::Plugin::Base
      # Walks the configured serializer-search paths through the plugin's `IoBoundary`, parses each `.rb`
      # file with Prism, records every `class X < Y` it finds with the facts the derivation needs, and
      # keeps the classes whose ancestry closes back to a configured root:
      #
      #     class ApplicationSerializer < ActiveModel::Serializer   # root child
      #     class REST::AccountSerializer < ApplicationSerializer   # reached through it
      #
      # The closure is what a direct-superclass match (the shape `rigor-pundit`'s policy discoverer uses)
      # would miss, and a project base serializer is the common case rather than the exotic one. It is
      # also the ONLY gate: a class the closure does not reach is not a serializer here, whatever it is
      # called, because `object` is an ordinary name that any class may define.
      #
      # Every class in the scanned tree is recorded first and filtered afterwards, because the file that
      # defines a base serializer may be parsed after the files that inherit from it.
      class SerializerDiscoverer
        # AMS's resource-backed declaration macros. Each names something the serializer renders by
        # calling it on the resource, unless the serializer defines a method of that name itself.
        DECLARATION_MACROS = %i[attributes attribute has_many has_one belongs_to].freeze

        # `object.tap`, `object.nil?`, `object.is_a?` and their siblings say nothing about which class
        # the resource is, so they are not evidence. Read from Ruby rather than listed, so the set cannot
        # drift from the Object the analysed code actually runs against.
        UNIVERSAL_METHODS = Object.instance_methods.to_set(&:to_s).freeze

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

            walk(Prism.parse(contents).value, []) do |entry_fields|
              candidates << SerializerIndex::Entry.new(file_path: path, **entry_fields)
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

          superclass = node.superclass ? constant_path_name(node.superclass) : nil
          unless superclass.nil?
            yield({ class_name: qualify(lexical_path, local_name),
                    superclass_name: superclass.delete_prefix("::"),
                    **collect_facts(node.body) })
          end

          walk(node.body, lexical_path + [local_name], &) if node.body
        end

        def visit_module(node, lexical_path, &)
          local_name = constant_path_name(node.constant_path)
          return if local_name.nil?

          walk(node.body, lexical_path + [local_name], &) if node.body
        end

        # The three name sets, gathered in ONE pass over the class body. A nested class or module is not
        # descended into — its `def`s and its `object` reads belong to it, not to this class.
        def collect_facts(body)
          facts = { declared_names: Set.new, object_reads: Set.new, own_method_names: Set.new }
          collect_from(body, facts)
          facts.transform_values { |set| set.to_a.sort.freeze }
        end

        def collect_from(node, facts)
          return if node.nil? || node.is_a?(Prism::ClassNode) || node.is_a?(Prism::ModuleNode)

          case node
          when Prism::DefNode
            # A `def self.x` body is class-level: its `object` would be a NoMethodError at run time, so
            # neither its name nor its reads are evidence about the resource.
            return unless node.receiver.nil?

            facts[:own_method_names] << node.name.to_s
          when Prism::CallNode then record_call(node, facts)
          end
          node.rigor_each_child { |child| collect_from(child, facts) }
        end

        def record_call(node, facts)
          if node.receiver.nil? && DECLARATION_MACROS.include?(node.name)
            symbol_arguments(node).each { |name| facts[:declared_names] << name }
          elsif object_reader?(node.receiver) && !UNIVERSAL_METHODS.include?(node.name.to_s)
            facts[:object_reads] << node.name.to_s
          end
        end

        def object_reader?(receiver)
          receiver.is_a?(Prism::CallNode) && receiver.name == :object && receiver.receiver.nil? &&
            receiver.arguments.nil?
        end

        def symbol_arguments(node)
          (node.arguments&.arguments || []).filter_map do |argument|
            argument.unescaped if argument.is_a?(Prism::SymbolNode)
          end
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
