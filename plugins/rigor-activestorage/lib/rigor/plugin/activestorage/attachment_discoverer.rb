# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class Activestorage < Rigor::Plugin::Base
      # Walks the configured model search paths via the plugin's
      # `IoBoundary`, parses each `.rb` file with Prism, and
      # collects `has_one_attached` / `has_many_attached`
      # declarations.
      #
      # Returns rows the {AttachmentIndex} consumes:
      #
      #   { class_name: "User",
      #     attachments: [{ name: "avatar", kind: :singular },
      #                   { name: "photos", kind: :collection }] }
      #
      # Limitations (intentional for v0.1.0 of the plugin):
      #
      # - The walker matches any class declaration that
      #   contains a `has_*_attached` call. Whether the class
      #   IS an ActiveRecord model is not verified here —
      #   `rigor-activerecord` provides that check via its
      #   own model index. The analyser is intentionally
      #   lenient so the plugin runs standalone in projects
      #   that haven't loaded `rigor-activerecord` yet.
      # - Only Symbol-literal attachment names are recognised.
      #   `has_one_attached(args)` or computed names decline.
      # - Modules (`class Admin::User`) are recognised; the
      #   resulting class name is the lexical path
      #   (`Admin::User`).
      class AttachmentDiscoverer
        ATTACHMENT_METHODS = {
          has_one_attached: :singular,
          has_many_attached: :collection
        }.freeze
        private_constant :ATTACHMENT_METHODS

        def initialize(io_boundary:, search_paths:)
          @io_boundary = io_boundary
          @search_paths = search_paths
        end

        def discover
          rows = []
          ruby_files_under(@search_paths).each do |path|
            contents = read_safely(path)
            next if contents.nil?

            tree = Prism.parse(contents).value
            walk(tree, []) do |class_name, attachments|
              rows << { class_name: class_name, attachments: attachments } unless attachments.empty?
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

        def walk(node, lexical_path, &)
          return if node.nil?

          case node
          when Prism::ClassNode
            visit_class(node, lexical_path, &)
          when Prism::ModuleNode
            visit_module(node, lexical_path, &)
          else
            node.compact_child_nodes.each { |child| walk(child, lexical_path, &) }
          end
        end

        def visit_class(node, lexical_path, &)
          class_local_name = constant_path_name(node.constant_path)
          return if class_local_name.nil?

          full_name = (lexical_path + [class_local_name]).join("::")
          attachments = collect_attachments(node.body)
          yield full_name, attachments

          inner_path = lexical_path + [class_local_name]
          walk(node.body, inner_path, &) if node.body
        end

        def visit_module(node, lexical_path, &)
          module_local_name = constant_path_name(node.constant_path)
          return if module_local_name.nil?

          inner_path = lexical_path + [module_local_name]
          walk(node.body, inner_path, &) if node.body
        end

        def collect_attachments(body)
          return [] if body.nil?

          rows = []
          body.compact_child_nodes.each do |node|
            next unless node.is_a?(Prism::CallNode)

            kind = ATTACHMENT_METHODS[node.name]
            next if kind.nil?
            next if node.receiver # skip self.has_one_attached and similar

            name = symbol_literal_arg(node)
            next if name.nil?

            rows << { name: name, kind: kind }
          end
          rows
        end

        def symbol_literal_arg(node)
          args = node.arguments&.arguments
          return nil if args.nil? || args.empty?

          first = args.first
          return nil unless first.is_a?(Prism::SymbolNode)

          first.unescaped
        end

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
      end
    end
  end
end
