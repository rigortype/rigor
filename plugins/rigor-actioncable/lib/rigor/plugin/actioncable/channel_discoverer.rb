# frozen_string_literal: true

require "rigor/source/node_children"

require "prism"

require_relative "channel_index"

module Rigor
  module Plugin
    class Actioncable < Rigor::Plugin::Base
      # Walks the configured channel-search paths via the plugin's `IoBoundary`, parses each `.rb` file
      # with Prism, and collects classes whose immediate superclass is one of the configured base
      # classes.
      #
      # For each discovered channel, the discoverer:
      #
      # - Records every public instance-side `def` whose name isn't an ActionCable framework hook
      #   (`subscribed`, `unsubscribed`, `_`-prefixed). These are the action methods clients can invoke
      #   via `subscription.perform("action_name", data)`.
      # - Records every literal-string `stream_from "name"` call as a registered stream name.
      # - Sets `dynamic_streams: true` when the channel has ANY non-literal `stream_from` argument (or a
      #   `stream_for` call) so the analyzer knows it can't be sure of every stream name.
      #
      # Intentional limitations:
      #
      # - Direct-superclass match only.
      # - Public-vs-private is not tracked; the framework hooks (`subscribed`/`unsubscribed`) are
      #   excluded by name. Methods marked `private` after a `private` keyword would still appear in the
      #   `action_methods` set.
      # - `stream_for(record)` (model-scoped streams) is recognised as setting `dynamic_streams: true`
      #   but not introspected further.
      class ChannelDiscoverer
        FRAMEWORK_HOOKS = %i[subscribed unsubscribed].to_set.freeze

        def initialize(io_boundary:, search_paths:, base_classes:)
          @io_boundary = io_boundary
          @search_paths = search_paths
          # De-rooted for the same reason superclass names are ({#visit_class}): the match is by exact
          # spelling, so a channel written `< ::ApplicationCable::Channel` — or a configured
          # `channel_base_classes: ["::ApplicationCable::Channel"]` — would otherwise never match, and the
          # channel would go undiscovered and its `broadcast_to` call sites report `unknown-channel`.
          @base_classes = base_classes.to_set { |name| strip_root(name.to_s) }
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
          ChannelIndex.new(merge_redeclarations(entries))
        end

        private

        # Collapses the entries that declare the SAME constant into one, so {ChannelIndex} — which keys its
        # by-name view by `class_name` — receives at most one row per channel.
        #
        # A channel is routinely declared more than once: the real class in `app/channels/chat_channel.rb`
        # and a second file reopening it (`class ::ChatChannel`, `class ChatChannel`) to add an action.
        # Ruby's own semantics are ADDITIVE, so the rows are UNIONed: action methods and literal stream
        # names union, and `dynamic_streams` ORs — any dynamic registration anywhere in the class means no
        # literal name can be proven missing, which is the false-positive-safe reading. Taking the last row
        # instead dropped the earlier declaration's actions and streams whenever it sorted later in the glob.
        # `file_path` stays the earlier declaration's; nothing reads it by name.
        def merge_redeclarations(entries)
          return entries if entries.length < 2

          entries.each_with_object({}) do |entry, acc|
            name = entry.class_name
            acc[name] = acc.key?(name) ? merged_entry(acc[name], entry) : entry
          end.values
        end

        # `base` is the earlier declaration, `addition` the later one. See {#merge_redeclarations}.
        def merged_entry(base, addition)
          base.with(
            action_methods: (base.action_methods | addition.action_methods).freeze,
            stream_names: (base.stream_names | addition.stream_names).freeze,
            dynamic_streams: base.dynamic_streams || addition.dynamic_streams
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

        def walk_for_channels(node, lexical_path, &)
          return if node.nil?

          case node
          when Prism::ClassNode then visit_class(node, lexical_path, &)
          when Prism::ModuleNode then visit_module(node, lexical_path, &)
          else
            node.rigor_each_child { |child| walk_for_channels(child, lexical_path, &) }
          end
        end

        def visit_class(node, lexical_path, &)
          class_local_name = constant_path_name(node.constant_path)
          return if class_local_name.nil?

          full_name = declared_constant_name(class_local_name, lexical_path)
          superclass = strip_root(constant_path_name(node.superclass)) if node.superclass
          yield full_name, node.body if superclass && @base_classes.include?(superclass)

          walk_for_channels(node.body, [full_name], &) if node.body
        end

        def visit_module(node, lexical_path, &)
          module_local_name = constant_path_name(node.constant_path)
          return if module_local_name.nil?

          inner_path = [declared_constant_name(module_local_name, lexical_path)]
          walk_for_channels(node.body, inner_path, &) if node.body
        end

        # The full constant name a `class` / `module` declaration defines, given the rendered local name
        # and the enclosing lexical path. A ROOTED local name (`class ::ChatChannel`) names the top-level
        # constant whatever the nesting, so the lexical path is dropped and the `::` with it; otherwise the
        # name is appended to the path (`class ChatChannel` inside `module Admin` → `Admin::ChatChannel`).
        def declared_constant_name(local_name, lexical_path)
          return strip_root(local_name) if local_name.start_with?("::")

          (lexical_path + [local_name]).join("::")
        end

        # `::ChatChannel` → `ChatChannel`; a name without the root marker is returned unchanged (nil stays
        # nil).
        def strip_root(name)
          name&.delete_prefix("::")
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

        # Walks the channel body recursively (so `stream_from` / `stream_for` calls inside `subscribed`
        # / helper methods are picked up). Returns `[Array<String>, bool]` — the literal stream names +
        # whether any dynamic registration was seen.
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
              # Model-scoped stream — name is computed from the record at runtime; treat as dynamic.
              dynamic = true
            end
          end

          node.rigor_each_child do |child|
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
      end
    end
  end
end
