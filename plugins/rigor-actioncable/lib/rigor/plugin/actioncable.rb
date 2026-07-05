# frozen_string_literal: true

require "rigor/plugin"

require_relative "actioncable/channel_index"
require_relative "actioncable/channel_discoverer"
require_relative "actioncable/analyzer"

module Rigor
  module Plugin
    # rigor-actioncable — validates ActionCable `<Channel>.broadcast_to(...)` and
    # `ActionCable.server.broadcast(stream_name, ...)` call sites against the discovered channel index.
    #
    # Tier 3F of the [Rails plugins roadmap](../../../../docs/design/20260508-rails-plugins-roadmap.md).
    # Statically discovers channel classes by walking `channel_search_paths` and parsing each file with
    # Prism — no `actioncable` runtime dependency.
    #
    # ## Configuration
    #
    #     plugins:
    #       - gem: rigor-actioncable
    #         config:
    #           channel_search_paths: ["app/channels"]                                # default; optional
    #           channel_base_classes: ["ApplicationCable::Channel", "ActionCable::Channel::Base"]  # default; optional
    #
    # ## What it checks
    #
    # 1. **Channel class existence** — `<X>.broadcast_to(...)` where `X` ends in `Channel` must resolve
    #    to a discovered channel.
    # 2. **Stream-name registration** — `ActionCable.server.broadcast("stream_name", ...)` with a
    #    literal stream name is checked against every discovered channel's `stream_from "..."`
    #    registrations. The check is suppressed when ANY discovered channel uses a dynamic registration
    #    (`stream_from interpolated_string` or `stream_for record`) — the absence of a literal match
    #    doesn't prove absence.
    #
    # ## Limitations
    #
    # - **Direct-superclass match only.** Indirect inheritance (`AdminChannel < BaseChannel <
    #   ApplicationCable::Channel`) needs `BaseChannel` listed in `channel_base_classes`.
    # - **Action method invocations are not validated.** ActionCable actions are invoked from JS via
    #   `subscription.perform("action_name", data)`; we don't analyse JS so the action-method index is
    #   informational only (deferred: cross-plugin handoff to a JS-side analyzer).
    # - **`broadcast_to` arity isn't checked.** The method takes any record + any data hash; there's no
    #   useful arity envelope.
    class Actioncable < Rigor::Plugin::Base
      manifest(
        id: "actioncable",
        version: "0.1.0",
        description: "Validates ActionCable broadcast call shape against discovered channels.",
        config_schema: {
          "channel_search_paths" => { kind: :array, default: ["app/channels"] },
          "channel_base_classes" => {
            kind: :array,
            default: ["ApplicationCable::Channel", "ActionCable::Channel::Base"]
          }
        }
      )

      # `watch:` covers every `.rb` file under the channel search paths so the cache invalidates when
      # channels are added, removed, or edited (ADR-60 WD3). The dependency descriptor is recorded after
      # the discoverer runs, so the `io_boundary` reads inside it are captured too.
      producer :channel_index, watch: -> { [[@channel_search_paths, "**/*.rb"]] } do |_params|
        ChannelDiscoverer.new(
          io_boundary: io_boundary,
          search_paths: @channel_search_paths,
          base_classes: @channel_base_classes
        ).discover
      end

      def init(_services)
        @channel_search_paths = Array(config.fetch("channel_search_paths")).map(&:to_s)
        @channel_base_classes = Array(config.fetch("channel_base_classes")).map(&:to_s)
      end

      # File-level only: the load-error emission. Per-call broadcast validation runs over the
      # engine-owned walk via the node_rule below (ADR-37). The channel index is lazily loaded +
      # memoised by `producer_value`, shared by both surfaces.
      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        index = producer_value(:channel_index)
        return [load_error_diagnostic(path)] if index.nil? && producer_error(:channel_index)

        []
      end

      node_rule Prism::CallNode do |node, _scope, path|
        index = producer_value(:channel_index)
        next [] if index.nil? || index.empty?

        diagnostics_for(Analyzer.violations_for(call_node: node, channel_index: index), path: path, node: node)
      end

      private

      def load_error_diagnostic(path)
        error = producer_error(:channel_index)
        Rigor::Analysis::Diagnostic.new(
          path: path, line: 1, column: 1,
          message: "rigor-actioncable: failed to discover channels: #{error.class}: #{error.message}",
          severity: :warning,
          rule: "load-error"
        )
      end
    end

    Rigor::Plugin.register(Actioncable)
  end
end
