# frozen_string_literal: true

require "rigor/plugin"

require_relative "actioncable/channel_index"
require_relative "actioncable/channel_discoverer"
require_relative "actioncable/analyzer"

module Rigor
  module Plugin
    # rigor-actioncable — validates ActionCable
    # `<Channel>.broadcast_to(...)` and
    # `ActionCable.server.broadcast(stream_name, ...)`
    # call sites against the discovered channel index.
    #
    # Tier 3F of the [Rails plugins roadmap](../../../../docs/design/20260508-rails-plugins-roadmap.md).
    # Statically discovers channel classes by walking
    # `channel_search_paths` and parsing each file with
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
    # 1. **Channel class existence** — `<X>.broadcast_to(...)`
    #    where `X` ends in `Channel` must resolve to a
    #    discovered channel.
    # 2. **Stream-name registration** —
    #    `ActionCable.server.broadcast("stream_name", ...)`
    #    with a literal stream name is checked against
    #    every discovered channel's `stream_from "..."`
    #    registrations. The check is suppressed when ANY
    #    discovered channel uses a dynamic registration
    #    (`stream_from interpolated_string` or
    #    `stream_for record`) — the absence of a literal
    #    match doesn't prove absence.
    #
    # ## Limitations (v0.1.0)
    #
    # - **Direct-superclass match only.** Indirect
    #   inheritance (`AdminChannel < BaseChannel <
    #   ApplicationCable::Channel`) needs `BaseChannel`
    #   listed in `channel_base_classes`.
    # - **Action method invocations are not validated.**
    #   ActionCable actions are invoked from JS via
    #   `subscription.perform("action_name", data)`; we
    #   don't analyse JS so the action-method index is
    #   currently informational only (future cross-plugin
    #   handoff to a hypothetical JS-side analyzer).
    # - **`broadcast_to` arity isn't checked.** The method
    #   takes any record + any data hash; there's no
    #   useful arity envelope.
    class Actioncable < Rigor::Plugin::Base
      manifest(
        id: "actioncable",
        version: "0.1.0",
        description: "Validates ActionCable broadcast call shape against discovered channels.",
        config_schema: {
          "channel_search_paths" => :array,
          "channel_base_classes" => :array
        }
      )

      DEFAULT_CHANNEL_SEARCH_PATHS = ["app/channels"].freeze
      DEFAULT_CHANNEL_BASE_CLASSES = [
        "ApplicationCable::Channel",
        "ActionCable::Channel::Base"
      ].freeze

      producer :channel_index do |_params|
        ChannelDiscoverer.new(
          io_boundary: io_boundary,
          search_paths: @channel_search_paths,
          base_classes: @channel_base_classes
        ).discover
      end

      def init(_services)
        @channel_search_paths = Array(
          config.fetch("channel_search_paths", DEFAULT_CHANNEL_SEARCH_PATHS)
        ).map(&:to_s)
        @channel_base_classes = Array(
          config.fetch("channel_base_classes", DEFAULT_CHANNEL_BASE_CLASSES)
        ).map(&:to_s)
        @channel_index = nil
        @load_error = nil
      end

      def diagnostics_for_file(path:, scope:, root:) # rubocop:disable Lint/UnusedMethodArgument
        index = channel_index_or_nil
        return [load_error_diagnostic(path)] if index.nil? && @load_error
        return [] if index.nil? || index.empty?

        Analyzer.diagnose(path: path, root: root, channel_index: index).map { |diag| build_diagnostic(diag) }
      end

      private

      def channel_index_or_nil
        return @channel_index if @channel_index

        # Pass an explicit descriptor covering every `.rb` file
        # under the configured channel search paths so the cache
        # invalidates when channels are added, removed, or edited.
        # Without it the auto-built descriptor depends on the
        # `IoBoundary`'s in-process read history — empty on the
        # first call of a fresh process, so warm cache hits would
        # serve stale `ChannelIndex` data when project files have
        # changed between sessions.
        descriptor = glob_descriptor(@channel_search_paths, "**/*.rb")
        @channel_index = cache_for(:channel_index, params: {}, descriptor: descriptor).call
      rescue StandardError => e
        @load_error = "rigor-actioncable: failed to discover channels: #{e.class}: #{e.message}"
        nil
      end

      def load_error_diagnostic(path)
        Rigor::Analysis::Diagnostic.new(
          path: path, line: 1, column: 1,
          message: @load_error,
          severity: :warning,
          rule: "load-error"
        )
      end

      def build_diagnostic(diag)
        Rigor::Analysis::Diagnostic.new(
          path: diag.path, line: diag.line, column: diag.column,
          message: diag.message, severity: diag.severity, rule: diag.rule
        )
      end
    end

    Rigor::Plugin.register(Actioncable)
  end
end
