# frozen_string_literal: true

require "did_you_mean"
require "prism"

module Rigor
  module Plugin
    class Actioncable < Rigor::Plugin::Base
      # Walks a parsed file's AST looking for ActionCable
      # entry-point calls and validates each against the
      # {ChannelIndex}.
      #
      # Recognised shapes:
      #
      # - `<ChannelClass>.broadcast_to(record, data)` —
      #   class-targeted broadcast. The class must exist in
      #   the index.
      # - `ActionCable.server.broadcast(stream_name, data)`
      #   — string-targeted broadcast. When `stream_name`
      #   is a literal string and the index has at least
      #   one channel with no dynamic stream registrations,
      #   we check that the name appears in
      #   `index.all_stream_names`. Otherwise the
      #   `unknown-stream` warning is suppressed (we can't
      #   prove absence).
      module Analyzer
        # `ActionCable.server.broadcast(...)` — the receiver
        # path we recognise as a server-targeted broadcast.
        # Single-symbol form (just `broadcast`) is too
        # ambiguous to validate.
        SERVER_BROADCAST_RECEIVER_NAMES = %w[
          ActionCable.server
          ::ActionCable.server
        ].freeze

        Diagnostic = Struct.new(:path, :line, :column, :severity, :rule, :message, keyword_init: true)

        module_function

        # @param path [String]
        # @param root [Prism::Node]
        # @param channel_index [ChannelIndex]
        # @return [Array<Diagnostic>]
        def diagnose(path:, root:, channel_index:)
          diagnostics = []
          walk(root) do |call_node|
            case call_node.name
            when :broadcast_to
              diagnostics.concat(analyse_broadcast_to(path, call_node, channel_index))
            when :broadcast
              diagnostics.concat(analyse_server_broadcast(path, call_node, channel_index))
            end
          end
          diagnostics
        end

        def walk(node, &)
          return unless node.is_a?(Prism::Node)

          yield node if node.is_a?(Prism::CallNode)
          node.compact_child_nodes.each { |child| walk(child, &) }
        end

        def analyse_broadcast_to(path, call_node, channel_index)
          class_name = constant_receiver_name(call_node.receiver)
          return [] if class_name.nil?

          # broadcast_to with a class-name receiver that
          # doesn't end in "Channel" is almost certainly
          # not ActionCable — pass through silently to
          # avoid flagging unrelated `broadcast_to` methods.
          return [] unless class_name.end_with?("Channel")

          entry = channel_index.find(class_name) || channel_index.find("::#{class_name}")
          return [unknown_channel_diagnostic(path, call_node, class_name, channel_index)] if entry.nil?

          [broadcast_target_info(path, call_node, entry)]
        end

        def analyse_server_broadcast(path, call_node, channel_index)
          receiver_path = call_chain_string(call_node.receiver)
          return [] unless SERVER_BROADCAST_RECEIVER_NAMES.include?(receiver_path)

          args = call_node.arguments&.arguments || []
          stream_arg = args.first
          return [] if stream_arg.nil?
          return [] unless stream_arg.is_a?(Prism::StringNode)
          return [] if channel_index.any_dynamic_streams?

          stream_name = stream_arg.unescaped
          if channel_index.all_stream_names.include?(stream_name)
            return [server_broadcast_info(path, call_node, stream_name)]
          end

          [unknown_stream_diagnostic(path, call_node, stream_name, channel_index)]
        end

        def broadcast_target_info(path, call_node, entry)
          location = call_node.location
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            severity: :info,
            rule: "broadcast-target",
            message: "`#{entry.class_name}.broadcast_to(...)` matches discovered channel"
          )
        end

        def server_broadcast_info(path, call_node, stream_name)
          location = call_node.location
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            severity: :info,
            rule: "broadcast-stream",
            message: "`broadcast(\"#{stream_name}\", ...)` matches a registered `stream_from`"
          )
        end

        def unknown_channel_diagnostic(path, call_node, class_name, channel_index)
          location = call_node.location
          suggestions = DidYouMean::SpellChecker.new(dictionary: channel_index.names).correct(class_name)
          suggestion_part = suggestions.empty? ? "" : " (did you mean `#{suggestions.first}`?)"
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            severity: :error,
            rule: "unknown-channel",
            message: "no ActionCable channel `#{class_name}`#{suggestion_part}"
          )
        end

        def unknown_stream_diagnostic(path, call_node, stream_name, channel_index)
          location = call_node.location
          dictionary = channel_index.all_stream_names.to_a
          suggestions = DidYouMean::SpellChecker.new(dictionary: dictionary).correct(stream_name)
          suggestion_part = suggestions.empty? ? "" : " (did you mean `\"#{suggestions.first}\"`?)"
          Diagnostic.new(
            path: path,
            line: location.start_line,
            column: location.start_column + 1,
            severity: :warning,
            rule: "unknown-stream",
            message: "no `stream_from \"#{stream_name}\"` registration in any discovered " \
                     "channel#{suggestion_part}"
          )
        end

        # Renders an `A.b.c` chain as a string (used to
        # detect `ActionCable.server`). Returns nil for
        # non-chained nodes.
        def call_chain_string(node)
          parts = []
          current = node
          while current.is_a?(Prism::CallNode) && current.arguments.nil?
            parts.unshift(current.name.to_s)
            current = current.receiver
          end
          base = constant_receiver_name(current)
          return nil if base.nil? || parts.empty?

          [base, *parts].join(".")
        end

        def constant_receiver_name(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode then constant_path_name(node)
          end
        end

        def constant_path_name(node)
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
