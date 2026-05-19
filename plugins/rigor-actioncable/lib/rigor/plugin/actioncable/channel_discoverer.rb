# frozen_string_literal: true

require "prism"

require_relative "channel_index"

module Rigor
  module Plugin
    class Actioncable < Rigor::Plugin::Base
      # Walks the configured channel-search paths via the
      # plugin's `IoBoundary`, parses each `.rb` file with
      # Prism, and collects classes whose immediate
      # superclass is one of the configured base classes.
      #
      # For each discovered channel, the discoverer:
      #
      # - Records every public instance-side `def` whose
      #   name isn't an ActionCable framework hook
      #   (`subscribed`, `unsubscribed`, `_`-prefixed).
      #   These are the action methods clients can invoke
      #   via `subscription.perform("action_name", data)`.
      # - Records every literal-string `stream_from "name"`
      #   call as a registered stream name.
      # - Sets `dynamic_streams: true` when the channel has
      #   ANY non-literal `stream_from` argument (or a
      #   `stream_for` call) so the analyzer knows it can't
      #   be sure of every stream name.
      #
      # Limitations (intentional for v0.1.0):
      #
      # - Direct-superclass match only.
      # - Public-vs-private is not tracked; the framework
      #   hooks (`subscribed`/`unsubscribed`) are excluded
      #   by name. Methods marked `private` after a
      #   `private` keyword would still appear in the
      #   `action_methods` set.
      # - `stream_for(record)` (model-scoped streams) is
      #   recognised as setting `dynamic_streams: true` but
      #   not introspected further.
      class ChannelDiscoverer
        FRAMEWORK_HOOKS = %i[subscribed unsubscribed].to_set.freeze

        def initialize(io_boundary:, search_paths:, base_classes:)
          @io_boundary = io_boundary
          @search_paths = search_paths
          @base_classes = base_classes.to_set
        end

        # @return [ChannelIndex]
        def discover
          entries = []
          ruby_files_under(@search_paths).each do |path|
            contents = read_safely(path)
            next if contents.nil?

            tree = Prism.parse(contents).value
            walk_for_channels(tree, []) do |class_name, body|
              entries << build_entry(class_name, path, body)
            end
          end
          ChannelIndex.new(entries)
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

        def walk_for_channels(node, lexical_path, &)
          return if node.nil?

          case node
          when Prism::ClassNode then visit_class(node, lexical_path, &)
          when Prism::ModuleNode then visit_module(node, lexical_path, &)
          else
            node.compact_child_nodes.each { |child| walk_for_channels(child, lexical_path, &) }
          end
        end

        def visit_class(node, lexical_path, &)
          class_local_name = constant_path_name(node.constant_path)
          return if class_local_name.nil?

          full_name = (lexical_path + [class_local_name]).join("::")
          superclass = constant_path_name(node.superclass) if node.superclass
          yield full_name, node.body if superclass && @base_classes.include?(superclass)

          inner_path = lexical_path + [class_local_name]
          walk_for_channels(node.body, inner_path, &) if node.body
        end

        def visit_module(node, lexical_path, &)
          module_local_name = constant_path_name(node.constant_path)
          return if module_local_name.nil?

          inner_path = lexical_path + [module_local_name]
          walk_for_channels(node.body, inner_path, &) if node.body
        end

        def build_entry(class_name, path, body)
          actions = []
          (body&.compact_child_nodes || []).each do |node|
            actions << node.name if node.is_a?(Prism::DefNode) && action_def?(node)
          end

          stream_names, dynamic_streams = collect_stream_registrations(body)

          ChannelIndex::Entry.new(
            class_name: class_name,
            file_path: path,
            action_methods: actions.to_set.freeze,
            stream_names: stream_names.to_set.freeze,
            dynamic_streams: dynamic_streams
          )
        end

        # Walks the channel body recursively (so
        # `stream_from` / `stream_for` calls inside
        # `subscribed` / helper methods are picked up).
        # Returns `[Array<String>, bool]` — the literal
        # stream names + whether any dynamic registration
        # was seen.
        def collect_stream_registrations(node, names: [], dynamic: false)
          return [names, dynamic] if node.nil?

          if node.is_a?(Prism::CallNode) && node.receiver.nil?
            case node.name
            when :stream_from
              arg = node.arguments&.arguments&.first
              if arg.is_a?(Prism::StringNode)
                names << arg.unescaped
              else
                dynamic = true
              end
            when :stream_for
              # Model-scoped stream — name is computed from
              # the record at runtime; treat as dynamic.
              dynamic = true
            end
          end

          node.compact_child_nodes.each do |child|
            names, dynamic = collect_stream_registrations(child, names: names, dynamic: dynamic)
          end
          [names, dynamic]
        end

        def action_def?(node)
          return false if node.receiver.is_a?(Prism::SelfNode)
          return false if FRAMEWORK_HOOKS.include?(node.name)
          return false if node.name.to_s.start_with?("_")

          true
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
      end
    end
  end
end
