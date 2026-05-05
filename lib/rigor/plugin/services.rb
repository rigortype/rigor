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
    class Services
      attr_reader :reflection, :type, :configuration, :cache_store

      def initialize(reflection:, type:, configuration:, cache_store: nil)
        @reflection = reflection
        @type = type
        @configuration = configuration
        @cache_store = cache_store
        freeze
      end
    end
  end
end
