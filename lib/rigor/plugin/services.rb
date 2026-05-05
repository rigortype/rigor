# frozen_string_literal: true

module Rigor
  module Plugin
    # Dependency-injection container handed to every plugin's
    # {Rigor::Plugin::Base#init} method. Plugins read from the
    # container; they MUST NOT mutate it. The container is
    # constructed once per `Analysis::Runner.run` and destroyed
    # at the end of the run.
    #
    # ADR-2 § "Registration, Configuration, and Caching" reserves
    # this surface for "constructor injection for analyzer
    # services such as reflection providers, type factories,
    # loggers, and configuration readers". Slice 1 wires four
    # of those:
    #
    # - `reflection`: the {Rigor::Reflection} read-side facade.
    # - `type`: the {Rigor::Type::Combinator} factory module.
    # - `configuration`: the project's {Rigor::Configuration}.
    # - `cache_store`: the {Rigor::Cache::Store} the run is using
    #   (or `nil` when caching is disabled). Slice 6 wires
    #   plugin-side cache producers through this entry.
    #
    # Loggers are not yet a public surface in the core analyzer;
    # they will be added when the diagnostics formatter grows a
    # progress channel.
    #
    # Slice 2 (Plugin trust / I/O policy) extends the container
    # with `trust_policy` and a per-plugin `io_boundary_for(plugin_id)`
    # factory. Plugins should reach for the boundary rather than
    # raw `File.read` so reads stay within the trusted scope and
    # feed cache invalidation; ADR-2 § "Plugin Trust and I/O
    # Policy" documents the trust model the boundary enforces.
    class Services
      attr_reader :reflection, :type, :configuration, :cache_store, :trust_policy

      def initialize(reflection:, type:, configuration:, cache_store: nil, trust_policy: nil)
        @reflection = reflection
        @type = type
        @configuration = configuration
        @cache_store = cache_store
        @trust_policy = trust_policy || default_trust_policy
        freeze
      end

      # Returns a fresh {IoBoundary} bound to `plugin_id` and the
      # current `trust_policy`. The boundary accumulates per-plugin
      # cache descriptor entries; the loader / contribution merger
      # constructs one boundary per plugin per run.
      def io_boundary_for(plugin_id)
        IoBoundary.new(policy: @trust_policy, plugin_id: plugin_id)
      end

      private

      def default_trust_policy
        TrustPolicy.new(
          trusted_gems: [],
          allowed_read_roots: [Dir.pwd],
          network_policy: :disabled
        )
      end
    end
  end
end
