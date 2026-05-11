# frozen_string_literal: true

module Rigor
  module Plugin
    # Read-side query API over the plugins loaded for a single
    # `Analysis::Runner.run`. Constructed by
    # {Rigor::Plugin::Loader.load} and exposed downstream so the
    # contribution merger (slice 3) and diagnostic provenance
    # (slice 5) can iterate over loaded plugin instances in
    # deterministic order.
    #
    # The registry is read-only after construction; ordering is
    # the order in which {Rigor::Plugin::Loader} resolved
    # configuration entries, which is project-config order with
    # plugin-id alphabetical as the tie-breaker.
    class Registry
      attr_reader :plugins, :load_errors

      # @param plugins [Array<Rigor::Plugin::Base>] instantiated
      #   plugin instances in deterministic order.
      # @param load_errors [Array<Rigor::Plugin::LoadError>] failures
      #   surfaced during loading. Each error is also turned into a
      #   diagnostic by the runner.
      def initialize(plugins: [], load_errors: [])
        @plugins = plugins.dup.freeze
        @load_errors = load_errors.dup.freeze
        freeze
      end

      def find(id)
        id_s = id.to_s
        plugins.find { |plugin| plugin.manifest.id == id_s }
      end

      def ids
        plugins.map { |plugin| plugin.manifest.id }
      end

      def empty?
        plugins.empty?
      end

      def any_load_errors?
        !load_errors.empty?
      end

      # ADR-13 slice 2 — flat ordered list of every loaded
      # plugin's manifest-declared {TypeNodeResolver} instances,
      # in plugin registration order. Slice 3 wires this into
      # the parser's resolver chain; until then the method is a
      # read-side aggregator only. The first non-nil
      # `#resolve(node, scope)` return wins per ADR-13 WD3 / WD5
      # — registration order is the user's lever.
      def type_node_resolvers
        plugins.flat_map { |plugin| plugin.manifest.type_node_resolvers }
      end

      EMPTY = new.freeze
    end
  end
end
