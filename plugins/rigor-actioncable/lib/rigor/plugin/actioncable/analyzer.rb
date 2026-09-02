# frozen_string_literal: true

require "did_you_mean"
require "prism"

module Rigor
  module Plugin
    class Actioncable < Rigor::Plugin::Base
      # Walks a parsed file's AST looking for ActionCable entry-point calls and validates each against
      # the {ChannelIndex}.
      #
      # Recognised shapes:
      #
      # - `<ChannelClass>.broadcast_to(record, data)` — class-targeted broadcast. The class must exist
      #   in the index.
      # - `ActionCable.server.broadcast(stream_name, data)` — string-targeted broadcast. When
      #   `stream_name` is a literal string and the index has at least one channel with no dynamic
      #   stream registrations, we check that the name appears in `index.all_stream_names`. Otherwise
      #   the `unknown-stream` warning is suppressed (we can't prove absence).
      module Analyzer
        # `ActionCable.server.broadcast(...)` — the receiver path we recognise as a server-targeted
        # broadcast. Single-symbol form (just `broadcast`) is too ambiguous to validate.
        SERVER_BROADCAST_RECEIVER_NAMES = %w[
          ActionCable.server
          ::ActionCable.server
        ].freeze

        # One broadcast observation. Carries no path/location — the caller (the `node_rule` block)
        # positions it via `Plugin::Base#diagnostic`.
        Violation = Struct.new(:rule, :severity, :message, keyword_init: true)

        module_function

        # The broadcast violations for a single call node, or `[]` when the node is not a
        # `broadcast_to` / `ActionCable.server.broadcast` call this plugin recognises. ADR-37: the
        # engine owns the walk.
        #
        # @param call_node [Prism::Node]
        # @param channel_index [ChannelIndex]
        # @return [Array<Violation>]
        def violations_for(call_node:, channel_index:)
          return [] unless call_node.is_a?(Prism::CallNode)

          case call_node.name
          when :broadcast_to then analyse_broadcast_to(call_node, channel_index)
          when :broadcast then analyse_server_broadcast(call_node, channel_index)
          else []
          end
        end

        def analyse_broadcast_to(call_node, channel_index)
          class_name = constant_receiver_name(call_node.receiver)
          return [] if class_name.nil?

          # broadcast_to with a class-name receiver that doesn't end in "Channel" is almost certainly
          # not ActionCable — pass through silently to avoid flagging unrelated `broadcast_to` methods.
          return [] unless class_name.end_with?("Channel")

          # `ChannelIndex#find` de-roots the query itself (#621) — a `::ChatChannel.broadcast_to` receiver
          # and a plain `ChatChannel.broadcast_to` reach the same entry with no retry arm here.
          entry = channel_index.find(class_name)
          return [unknown_channel_violation(class_name, channel_index)] if entry.nil?

          [broadcast_target_info(entry)]
        end

        def analyse_server_broadcast(call_node, channel_index)
          receiver_path = call_chain_string(call_node.receiver)
          return [] unless SERVER_BROADCAST_RECEIVER_NAMES.include?(receiver_path)

          args = call_node.arguments&.arguments || []
          stream_arg = args.first
          return [] if stream_arg.nil?
          return [] unless stream_arg.is_a?(Prism::StringNode)
          return [] if channel_index.any_dynamic_streams?

          stream_name = stream_arg.unescaped
          return [server_broadcast_info(stream_name)] if channel_index.all_stream_names.include?(stream_name)

          [unknown_stream_violation(stream_name, channel_index)]
        end

        def broadcast_target_info(entry)
          Violation.new(
            severity: :info,
            rule: "broadcast-target",
            message: "`#{entry.class_name}.broadcast_to(...)` matches discovered channel"
          )
        end

        def server_broadcast_info(stream_name)
          Violation.new(
            severity: :info,
            rule: "broadcast-stream",
            message: "`broadcast(\"#{stream_name}\", ...)` matches a registered `stream_from`"
          )
        end

        def unknown_channel_violation(class_name, channel_index)
          suggestions = DidYouMean::SpellChecker.new(dictionary: channel_index.names).correct(class_name)
          suggestion_part = suggestions.empty? ? "" : " (did you mean `#{suggestions.first}`?)"
          Violation.new(
            severity: :error,
            rule: "unknown-channel",
            message: "no ActionCable channel `#{class_name}`#{suggestion_part}"
          )
        end

        def unknown_stream_violation(stream_name, channel_index)
          dictionary = channel_index.all_stream_names.to_a
          suggestions = DidYouMean::SpellChecker.new(dictionary: dictionary).correct(stream_name)
          suggestion_part = suggestions.empty? ? "" : " (did you mean `\"#{suggestions.first}\"`?)"
          Violation.new(
            severity: :warning,
            rule: "unknown-stream",
            message: "no `stream_from \"#{stream_name}\"` registration in any discovered " \
                     "channel#{suggestion_part}"
          )
        end

        # Renders an `A.b.c` chain as a string (used to detect `ActionCable.server`). Returns nil for
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
